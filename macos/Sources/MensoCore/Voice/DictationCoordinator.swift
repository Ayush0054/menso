import AppKit
import ApplicationServices
import Foundation

public struct AuthenticatedDictationContext: Sendable, Hashable {
    public let userID: UserID
    public let sessionID: ProductSessionID

    public init(userID: UserID, sessionID: ProductSessionID) throws {
        guard !userID.rawValue.isEmpty, !sessionID.rawValue.isEmpty else {
            throw DictationCoordinatorError.invalidAuthenticatedContext
        }
        self.userID = userID
        self.sessionID = sessionID
    }
}

/// Implementations must source this identity from the client's verified Menso
/// authentication state. Dictation entry points intentionally accept no user ID.
public protocol AuthenticatedDictationContextProviding: Sendable {
    func authenticatedContext() async throws -> AuthenticatedDictationContext
}

public struct VerifiedAgentOSDictationContextProvider: AuthenticatedDictationContextProviding {
    private let provider: any AuthenticatedProductContextProviding

    public init(provider: any AuthenticatedProductContextProviding) {
        self.provider = provider
    }

    public func authenticatedContext() async throws -> AuthenticatedDictationContext {
        let context = try await provider.authenticatedProductContext()
        return try AuthenticatedDictationContext(
            userID: context.userID,
            sessionID: context.sessionID
        )
    }
}

public protocol FocusedApplicationTargetProviding: Sendable {
    func focusedApplicationTarget() async throws -> FocusedApplicationTarget
}

@MainActor
public final class MacOSFocusedApplicationTargetProvider: FocusedApplicationTargetProviding {
    private let excludedBundleIdentifiers: Set<String>

    nonisolated public init(excludedBundleIdentifiers: Set<String> = []) {
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    public func focusedApplicationTarget() async throws -> FocusedApplicationTarget {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              !excludedBundleIdentifiers.contains(bundleIdentifier)
        else {
            throw DictationCoordinatorError.focusedApplicationUnavailable
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let windowElement = Self.elementAttribute(
                  appElement,
                  attribute: kAXFocusedWindowAttribute as CFString
              ),
              let windowTitle = Self.stringAttribute(
                  windowElement,
                  attribute: kAXTitleAttribute as CFString
              ),
              !windowTitle.isEmpty,
              let focusedElement = Self.elementAttribute(
                  appElement,
                  attribute: kAXFocusedUIElementAttribute as CFString
              ),
              let role = Self.stringAttribute(
                  focusedElement,
                  attribute: kAXRoleAttribute as CFString
              ),
              ["AXTextField", "AXTextArea", "AXSearchField"].contains(role),
              let label = Self.firstStringAttribute(
                  focusedElement,
                  attributes: [
                      kAXTitleAttribute as CFString,
                      kAXDescriptionAttribute as CFString,
                      kAXPlaceholderValueAttribute as CFString,
                      kAXIdentifierAttribute as CFString,
                  ]
              )
        else { throw DictationCoordinatorError.focusedApplicationUnavailable }
        return FocusedApplicationTarget(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: application.processIdentifier,
            windowTitle: windowTitle,
            elementRole: role,
            elementLabel: label
        )
    }

    private static func elementAttribute(
        _ element: AXUIElement,
        attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return string
    }

    private static func firstStringAttribute(
        _ element: AXUIElement,
        attributes: [CFString]
    ) -> String? {
        attributes.lazy.compactMap { stringAttribute(element, attribute: $0) }.first
    }
}

public enum DictationFailureCode: String, Codable, Hashable, Sendable {
    case authenticationUnavailable = "authentication_unavailable"
    case microphonePermissionRequired = "microphone_permission_required"
    case audioUnavailable = "audio_unavailable"
    case transcriptionUnavailable = "transcription_unavailable"
    case emptyTranscription = "empty_transcription"
    case focusedApplicationChanged = "focused_application_changed"
    case secureInputActive = "secure_input_active"
    case approvalRequired = "approval_required"
    case insertionRejected = "insertion_rejected"
    case commandUnavailable = "command_unavailable"
    case commandRejected = "command_rejected"
    case cancelled
}

public struct DictationFailure: Codable, Hashable, Sendable {
    public let code: DictationFailureCode
    public let userMessage: String

    public init(code: DictationFailureCode, userMessage: String) {
        self.code = code
        self.userMessage = userMessage
    }
}

public enum DictationRuntimeState: Sendable, Hashable {
    case idle
    case preparing
    case recording(partialText: String)
    case finalizing(partialText: String)
    case executing(text: String)
    case awaitingHumanReview(HumanReviewRequirement)
    case delegating(text: String)
    case completed(summary: String)
    case failed(DictationFailure)

    public var isActivelyCapturing: Bool {
        switch self {
        case .preparing, .recording, .finalizing:
            true
        default:
            false
        }
    }
}

/// Single integration seam for AppDelegate, the global hotkey, and the HUD.
public protocol DictationRuntimeControlling: AnyObject, Sendable {
    func stateUpdates() async -> AsyncStream<DictationRuntimeState>
    func currentState() async -> DictationRuntimeState
    func toggle(intent: DictationIntent) async
    func start(intent: DictationIntent) async
    func finishRecording() async
    func cancel() async
    /// The exact client-owned review must be approved before resubmission.
    func resumeAfterHumanReview(id: HumanReviewID) async
}

/// Orchestrates a local dictation turn without placing audio or partial
/// transcripts on AgentOS. Only command-mode final text crosses that boundary.
public actor DictationCoordinator: DictationRuntimeControlling {
    private let audioCapture: any DictationAudioCapturing
    private let transcriber: any DictationTranscribing
    private let contextProvider: any AuthenticatedDictationContextProviding
    private let targetProvider: any FocusedApplicationTargetProviding
    private let policyEngine: PolicyEngine
    private let actionExecutor: ActionExecutor
    private let commandDelegate: (any DictationCommandDelegating)?
    private let requestFactory: DictationActionRequestFactory
    private let transcriptionConfiguration: DictationTranscriptionConfiguration
    private let actionLifetime: TimeInterval
    private let now: @Sendable () -> Date

    private var state: DictationRuntimeState = .idle
    private var continuations: [UUID: AsyncStream<DictationRuntimeState>.Continuation] = [:]
    private var runTask: Task<Void, Never>?
    private var activeCaptureID: UUID?
    private var isTranscriberPrepared = false
    private var latestPartial = ""
    private var pendingInsertionRequest: ActionRequest?
    private var pendingReviewID: HumanReviewID?

    public init(
        audioCapture: any DictationAudioCapturing,
        transcriber: any DictationTranscribing,
        contextProvider: any AuthenticatedDictationContextProviding,
        targetProvider: any FocusedApplicationTargetProviding,
        policyEngine: PolicyEngine,
        actionExecutor: ActionExecutor,
        commandDelegate: (any DictationCommandDelegating)? = nil,
        requestFactory: DictationActionRequestFactory = DictationActionRequestFactory(),
        transcriptionConfiguration: DictationTranscriptionConfiguration,
        actionLifetime: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.audioCapture = audioCapture
        self.transcriber = transcriber
        self.contextProvider = contextProvider
        self.targetProvider = targetProvider
        self.policyEngine = policyEngine
        self.actionExecutor = actionExecutor
        self.commandDelegate = commandDelegate
        self.requestFactory = requestFactory
        self.transcriptionConfiguration = transcriptionConfiguration
        self.actionLifetime = min(max(actionLifetime, 15), 300)
        self.now = now
    }

    public func stateUpdates() async -> AsyncStream<DictationRuntimeState> {
        let identifier = UUID()
        let pair = AsyncStream<DictationRuntimeState>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        continuations[identifier] = pair.continuation
        pair.continuation.yield(state)
        pair.continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeContinuation(identifier)
            }
        }
        return pair.stream
    }

    public func currentState() async -> DictationRuntimeState {
        state
    }

    public func toggle(intent: DictationIntent = .insertText) async {
        switch state {
        case .recording:
            await finishRecording()
        case .preparing:
            await cancel()
        case .finalizing, .executing, .delegating, .awaitingHumanReview:
            return
        case .idle, .completed, .failed:
            await start(intent: intent)
        }
    }

    public func start(intent: DictationIntent) async {
        guard runTask == nil, pendingInsertionRequest == nil else { return }
        latestPartial = ""
        let captureID = UUID()
        activeCaptureID = captureID
        pendingReviewID = nil
        publish(.preparing)
        runTask = Task { [weak self] in
            await self?.runCapture(id: captureID, intent: intent)
        }
    }

    public func finishRecording() async {
        guard case .recording = state else { return }
        publish(.finalizing(partialText: latestPartial))
        await audioCapture.stopCapture()
    }

    public func cancel() async {
        switch state {
        case .preparing, .recording, .finalizing:
            break
        case .completed, .failed:
            publish(.idle)
            return
        case .idle, .executing, .delegating:
            return
        case .awaitingHumanReview:
            pendingInsertionRequest = nil
            pendingReviewID = nil
            latestPartial = ""
            publish(.idle)
            return
        }
        activeCaptureID = nil
        pendingInsertionRequest = nil
        pendingReviewID = nil
        runTask?.cancel()
        runTask = nil
        await audioCapture.stopCapture()
        await transcriber.cancel()
        latestPartial = ""
        publish(.idle)
    }

    public func resumeAfterHumanReview(id: HumanReviewID) async {
        guard runTask == nil,
              pendingReviewID == id,
              let request = pendingInsertionRequest
        else { return }
        pendingReviewID = nil
        let submissionID = UUID()
        activeCaptureID = submissionID
        publish(.executing(text: requestText(request)))
        runTask = Task { [weak self] in
            await self?.submitInsertion(request, captureID: submissionID)
        }
    }

    private func runCapture(id captureID: UUID, intent: DictationIntent) async {
        do {
            let context: AuthenticatedDictationContext
            do {
                context = try await contextProvider.authenticatedContext()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DictationCoordinatorError.authenticationUnavailable
            }
            try ensureActive(captureID)

            let target: FocusedApplicationTarget?
            switch intent {
            case .insertText:
                do {
                    target = try await targetProvider.focusedApplicationTarget()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw DictationCoordinatorError.focusedApplicationUnavailable
                }
            case .command:
                target = nil
            }
            try ensureActive(captureID)

            if !isTranscriberPrepared {
                try await transcriber.prepare(configuration: transcriptionConfiguration)
                try ensureActive(captureID)
                isTranscriberPrepared = true
            }

            let audio = try await audioCapture.startCapture()
            try ensureActive(captureID)
            publish(.recording(partialText: ""))
            let events = try await transcriber.transcribe(audio: audio)

            var finalText = ""
            for try await event in events {
                try Task.checkCancellation()
                try ensureActive(captureID)
                switch event {
                case let .partial(text, _):
                    latestPartial = text
                    if case .finalizing = state {
                        publish(.finalizing(partialText: text))
                    } else {
                        publish(.recording(partialText: text))
                    }
                case let .final(text):
                    finalText = text
                    latestPartial = text
                    publish(.finalizing(partialText: text))
                case .endOfUtterance:
                    await audioCapture.stopCapture()
                    publish(.finalizing(partialText: latestPartial))
                }
            }
            await audioCapture.stopCapture()
            try ensureActive(captureID)

            let chosenText = finalText.isEmpty ? latestPartial : finalText
            let completed = try CompletedDictation(text: chosenText, intent: intent)
            switch intent {
            case .insertText:
                guard let target else {
                    throw DictationCoordinatorError.focusedApplicationUnavailable
                }
                let currentDate = now()
                let request = try requestFactory.insertionRequest(
                    text: completed.text,
                    target: target,
                    userID: context.userID,
                    sessionID: context.sessionID,
                    expiresAt: currentDate.addingTimeInterval(actionLifetime),
                    now: currentDate
                )
                pendingInsertionRequest = request
                publish(.executing(text: completed.text))
                await submitInsertion(request, captureID: captureID)
            case .command:
                guard let commandDelegate else {
                    throw DictationCoordinatorError.commandDelegateUnavailable
                }
                publish(.delegating(text: completed.text))
                let result = try await commandDelegate.delegateCommand(
                    completed,
                    userID: context.userID,
                    sessionID: context.sessionID
                )
                try ensureActive(captureID)
                guard result.status != .rejected else {
                    throw DictationCoordinatorError.commandRejected
                }
                finishRun(captureID, state: .completed(summary: result.spokenSummary))
            }
        } catch is CancellationError {
            await audioCapture.stopCapture()
            await transcriber.cancel()
            finishCancelledRun(captureID)
        } catch {
            await audioCapture.stopCapture()
            await transcriber.cancel()
            finishRun(captureID, state: .failed(Self.failure(for: error)))
        }
    }

    private func submitInsertion(_ request: ActionRequest, captureID: UUID) async {
        await policyEngine.requireReviewForBoundRequest(request)
        let submission = await actionExecutor.submit(request)
        guard activeCaptureID == captureID else { return }
        switch submission {
        case let .requiresHumanReview(requirement):
            pendingInsertionRequest = request
            pendingReviewID = requirement.id
            activeCaptureID = nil
            runTask = nil
            publish(.awaitingHumanReview(requirement))
        case let .completed(result):
            pendingInsertionRequest = nil
            pendingReviewID = nil
            guard result.status == .inserted, result.verified else {
                finishRun(
                    captureID,
                    state: .failed(Self.failure(for: result.errorCode))
                )
                return
            }
            finishRun(captureID, state: .completed(summary: "Inserted dictation"))
        }
    }

    private func finishCancelledRun(_ captureID: UUID) {
        guard activeCaptureID == captureID else { return }
        activeCaptureID = nil
        runTask = nil
        pendingInsertionRequest = nil
        pendingReviewID = nil
        latestPartial = ""
        publish(.idle)
    }

    private func finishRun(_ captureID: UUID, state: DictationRuntimeState) {
        guard activeCaptureID == captureID else { return }
        activeCaptureID = nil
        runTask = nil
        pendingInsertionRequest = nil
        pendingReviewID = nil
        publish(state)
    }

    private func ensureActive(_ captureID: UUID) throws {
        guard activeCaptureID == captureID, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }

    private func publish(_ newState: DictationRuntimeState) {
        state = newState
        for continuation in continuations.values {
            continuation.yield(newState)
        }
    }

    private func requestText(_ request: ActionRequest) -> String {
        guard case let .insertDictationText(operation) = request.operation else { return "" }
        return operation.text
    }

    private static func failure(for errorCode: ActionErrorCode?) -> DictationFailure {
        switch errorCode {
        case .secureInputActive:
            DictationFailure(
                code: .secureInputActive,
                userMessage: "Can't dictate into a secure input field."
            )
        case .targetMismatch:
            DictationFailure(
                code: .focusedApplicationChanged,
                userMessage: "The focused app changed before text could be inserted."
            )
        case .policyDenied, .humanReviewDenied:
            DictationFailure(code: .insertionRejected, userMessage: "Text insertion was not allowed.")
        default:
            DictationFailure(code: .insertionRejected, userMessage: "Dictation could not be inserted safely.")
        }
    }

    private static func failure(for error: Error) -> DictationFailure {
        switch error {
        case AVAudioDictationCaptureError.microphonePermissionRequired:
            DictationFailure(
                code: .microphonePermissionRequired,
                userMessage: "Microphone access is required for dictation."
            )
        case is AVAudioDictationCaptureError:
            DictationFailure(code: .audioUnavailable, userMessage: "The microphone is unavailable.")
        case DictationError.emptyTranscription:
            DictationFailure(code: .emptyTranscription, userMessage: "No speech was detected.")
        case DictationCoordinatorError.invalidAuthenticatedContext,
             DictationCoordinatorError.authenticationUnavailable:
            DictationFailure(
                code: .authenticationUnavailable,
                userMessage: "Sign in to Menso before using dictation."
            )
        case DictationCoordinatorError.focusedApplicationUnavailable:
            DictationFailure(
                code: .focusedApplicationChanged,
                userMessage: "Choose a text field and try dictation again."
            )
        case DictationCoordinatorError.commandDelegateUnavailable:
            DictationFailure(code: .commandUnavailable, userMessage: "Command mode is not configured.")
        case DictationCoordinatorError.commandRejected:
            DictationFailure(code: .commandRejected, userMessage: "The command was rejected safely.")
        case UnavailableDictationTranscriberError.modelNotConfigured:
            DictationFailure(
                code: .transcriptionUnavailable,
                userMessage: "Install the local dictation model before using dictation."
            )
        default:
            DictationFailure(
                code: .transcriptionUnavailable,
                userMessage: "Dictation is temporarily unavailable."
            )
        }
    }
}

public enum DictationCoordinatorError: Error, Sendable, Equatable {
    case invalidAuthenticatedContext
    case authenticationUnavailable
    case focusedApplicationUnavailable
    case commandDelegateUnavailable
    case commandRejected
}
