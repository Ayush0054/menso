import Foundation

public enum LiveVoiceAudioEncoding: String, Codable, Hashable, Sendable {
    case linearPCM16 = "linear_pcm_16"
    case linearPCMFloat32 = "linear_pcm_float_32"
    case opus
}

public struct LiveVoiceAudioFormat: Codable, Hashable, Sendable {
    public let sampleRate: Int
    public let channelCount: Int
    public let encoding: LiveVoiceAudioEncoding

    public init(sampleRate: Int, channelCount: Int, encoding: LiveVoiceAudioEncoding) throws {
        guard sampleRate > 0, (1...2).contains(channelCount) else {
            throw LiveVoiceError.invalidAudioFormat
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.encoding = encoding
    }

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channelCount = "channel_count"
        case encoding
    }
}

public struct LiveVoiceAudioFrame: Sendable, Hashable {
    public let data: Data
    public let format: LiveVoiceAudioFormat
    public let presentationTimeNanoseconds: UInt64

    public init(data: Data, format: LiveVoiceAudioFormat, presentationTimeNanoseconds: UInt64) throws {
        guard !data.isEmpty else { throw LiveVoiceError.emptyAudioFrame }
        self.data = data
        self.format = format
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
    }
}

public struct LiveVoiceClientAccess: Sendable, Hashable {
    public let endpoint: URL
    public let accessToken: String
    public let expiresAt: Date

    public init(endpoint: URL, accessToken: String, expiresAt: Date) throws {
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(endpoint.host?.lowercased() ?? "")
        guard (endpoint.scheme?.lowercased() == "https" || (endpoint.scheme == "http" && loopback)),
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              !accessToken.isEmpty
        else {
            throw LiveVoiceError.invalidClientAccess
        }
        self.endpoint = endpoint
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

public protocol LiveVoiceClientAccessProviding: Sendable {
    func clientAccess(for userID: UserID, sessionID: ProductSessionID) async throws -> LiveVoiceClientAccess
}

public struct LiveVoiceSessionConfiguration: Sendable, Hashable {
    public let userID: UserID
    public let productSessionID: ProductSessionID
    public let preferredInputFormat: LiveVoiceAudioFormat
    public let voiceProcessingEnabled: Bool

    public init(
        userID: UserID,
        productSessionID: ProductSessionID,
        preferredInputFormat: LiveVoiceAudioFormat,
        voiceProcessingEnabled: Bool
    ) {
        self.userID = userID
        self.productSessionID = productSessionID
        self.preferredInputFormat = preferredInputFormat
        self.voiceProcessingEnabled = voiceProcessingEnabled
    }
}

public enum LiveVoiceSessionState: String, Codable, Hashable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting
    case disconnecting
    case disconnected
    case failed
}

public enum VoiceOperationHint: String, Codable, Hashable, Sendable {
    case openEnded = "open_ended"
    case desktopAction = "desktop_action"
}

public struct VoiceDelegationRequest: Codable, Hashable, Sendable {
    public let callID: String
    public let task: String
    public let contextReferences: [String]
    public let operationHint: VoiceOperationHint?

    public init(
        callID: String,
        task: String,
        contextReferences: [String] = [],
        operationHint: VoiceOperationHint? = nil
    ) throws {
        guard !callID.isEmpty, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveVoiceError.invalidDelegation
        }
        self.callID = callID
        self.task = task
        self.contextReferences = contextReferences
        self.operationHint = operationHint
    }

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case task
        case contextReferences = "context_refs"
        case operationHint = "operation_hint"
    }
}

public enum VoiceDelegationStatus: String, Codable, Hashable, Sendable {
    case completed
    case requiresExternalAction = "requires_external_action"
    case rejected
}

public struct VoiceDelegationResult: Codable, Hashable, Sendable {
    public let status: VoiceDelegationStatus
    public let spokenSummary: String
    /// Presentation-only structured data. It is never interpreted as action authority.
    public let displayPayload: JSONValue?
    /// Typed evidence for already policy-checked actions; receipts cannot request execution.
    public let actionReceipts: [ExternalExecutionWireResult]
    public let runID: String?
    public let continuationKind: String?
    public let continuationResourceID: String?

    public init(
        status: VoiceDelegationStatus,
        spokenSummary: String,
        displayPayload: JSONValue? = nil,
        actionReceipts: [ExternalExecutionWireResult] = [],
        runID: String? = nil,
        continuationKind: String? = nil,
        continuationResourceID: String? = nil
    ) {
        self.status = status
        self.spokenSummary = spokenSummary
        self.displayPayload = displayPayload
        self.actionReceipts = actionReceipts
        self.runID = runID
        self.continuationKind = continuationKind
        self.continuationResourceID = continuationResourceID
    }

    enum CodingKeys: String, CodingKey {
        case status
        case spokenSummary = "spoken_summary"
        case displayPayload = "display_payload"
        case actionReceipts = "action_receipts"
        case runID = "run_id"
        case continuationKind = "continuation_kind"
        case continuationResourceID = "continuation_resource_id"
    }
}

public struct LiveTranscriptSegment: Codable, Hashable, Sendable {
    public enum Speaker: String, Codable, Hashable, Sendable {
        case user
        case assistant
    }

    public let speaker: Speaker
    public let text: String
    public let isFinal: Bool

    public init(speaker: Speaker, text: String, isFinal: Bool) {
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
    }
}

/// Provider adapters translate their wire events into this closed, product-facing event vocabulary.
public enum LiveVoiceSessionEvent: Sendable, Hashable {
    case stateChanged(LiveVoiceSessionState)
    case userSpeechStarted
    case userSpeechEnded
    case transcript(LiveTranscriptSegment)
    case assistantAudio(LiveVoiceAudioFrame)
    case assistantInterrupted
    case delegationRequested(VoiceDelegationRequest)
    case recoverableError(code: String)
}

public protocol LiveVoiceSessionDelegate: Sendable {
    func liveVoiceSession(didReceive event: LiveVoiceSessionEvent) async
}

/// UI observations carry no action authority.
public enum LiveVoiceUpdate: Sendable {
    case state(LiveVoiceSessionState)
    case transcript(LiveTranscriptSegment)
    case working(Bool)
    case actionPrepared(Bool)
    case result(VoiceDelegationResult)
    case error(String)
}

/// Provider-neutral media and tool boundary. OpenAI GPT-Live event names do not escape an adapter.
public protocol LiveVoiceSession: Sendable {
    /// True when the provider transport owns microphone capture directly (for
    /// example WebRTC's native audio track). Callers must not create a competing
    /// AVAudioEngine capture path in this mode.
    var ownsMicrophoneCapture: Bool { get }
    func connect(
        access: LiveVoiceClientAccess,
        configuration: LiveVoiceSessionConfiguration,
        delegate: any LiveVoiceSessionDelegate
    ) async throws
    func sendMicrophoneAudio(_ frame: LiveVoiceAudioFrame) async throws
    func interruptAssistant() async
    func sendDelegationAcknowledgement(callID: String, spokenText: String) async throws
    func sendDelegationResult(callID: String, result: VoiceDelegationResult) async throws
    /// Inserts bounded, non-executable context into a replacement provider
    /// conversation. Implementations must not translate records from a prior
    /// provider session into fresh executable requests.
    func restoreContinuity(_ context: LiveVoiceContinuationContext) async throws
    func disconnect() async
}

public protocol LiveVoiceSessionFactory: Sendable {
    func makeSession() async throws -> any LiveVoiceSession
}

public enum VoiceDelegationRoute: Sendable, Hashable {
    case agent(agentID: String)
    case nativeAction
}

public struct NativeVoiceDelegationRouter: VoiceDelegationRouting {
    public init() {}
    public func route(_ request: VoiceDelegationRequest) async -> VoiceDelegationRoute { .nativeAction }
}

public protocol VoiceDelegationRouting: Sendable {
    func route(_ request: VoiceDelegationRequest) async -> VoiceDelegationRoute
}

/// Voice delegates only to the reusable Menso Agent. Local target recognition
/// controls whether that Agent run receives one exact CUA authority.
public struct RegisteredVoiceDelegationRouter: VoiceDelegationRouting {
    private let agentID: String

    public init(agentID: String) throws {
        guard !agentID.isEmpty else {
            throw LiveVoiceError.invalidRouteRegistry
        }
        self.agentID = agentID
    }

    public func route(_ request: VoiceDelegationRequest) async -> VoiceDelegationRoute {
        .agent(agentID: agentID)
    }
}

public struct TrustedVoiceActionAuthority: Sendable, Hashable {
    public let target: ActionTarget
    public let operation: ActionOperation

    public init(target: ActionTarget, operation: ActionOperation) throws {
        guard ExternalActionRequestFactory.coreToolNames.contains(operation.semanticToolName),
              target.isStructurallyValid,
              operation.hasValidContentBinding,
              target.matches(operation)
        else { throw LiveVoiceError.invalidDelegation }
        self.target = target
        self.operation = operation
    }
}

public struct AuthenticatedVoiceDelegation: Sendable, Hashable {
    public let request: VoiceDelegationRequest
    public let route: VoiceDelegationRoute
    public let actionAuthority: TrustedVoiceActionAuthority?
    public let userID: UserID
    public let sessionID: ProductSessionID

    public init(
        request: VoiceDelegationRequest,
        route: VoiceDelegationRoute,
        actionAuthority: TrustedVoiceActionAuthority?,
        userID: UserID,
        sessionID: ProductSessionID
    ) {
        self.request = request
        self.route = route
        self.actionAuthority = actionAuthority
        self.userID = userID
        self.sessionID = sessionID
    }
}

public protocol TrustedVoiceOperationRecognizing: Sendable {
    /// Returns local authority only when both the semantic tool and exact
    /// native target are unambiguous.
    func recognizedActionAuthority(
        for request: VoiceDelegationRequest
    ) async -> TrustedVoiceActionAuthority?
}

/// Voice-first requests are resolved from native observations when the Agent
/// proposes an action, rather than requiring a preparation form beforehand.
public struct UnpreparedVoiceOperationRecognizer: TrustedVoiceOperationRecognizing {
    public init() {}
    public func recognizedActionAuthority(for request: VoiceDelegationRequest) async -> TrustedVoiceActionAuthority? {
        nil
    }
}

/// One-shot authority selected by the user for the next client delegation.
/// GPT-Live cannot create or modify the prepared target or operation.
public actor UserStagedVoiceActionAuthorityStore: TrustedVoiceOperationRecognizing {
    private struct StagedAuthority: Sendable {
        let authority: TrustedVoiceActionAuthority
        let expiresAt: Date
    }

    private var staged: StagedAuthority?

    public init() {}

    public func stage(
        target: ActionTarget,
        operation: ActionOperation,
        expiresAt: Date
    ) throws {
        let now = Date()
        guard expiresAt > now, expiresAt <= now.addingTimeInterval(10 * 60) else {
            throw LiveVoiceError.invalidDelegation
        }
        staged = StagedAuthority(
            authority: try TrustedVoiceActionAuthority(
                target: target,
                operation: operation
            ),
            expiresAt: expiresAt
        )
    }

    public func clear() {
        staged = nil
    }

    public func recognizedActionAuthority(
        for request: VoiceDelegationRequest
    ) async -> TrustedVoiceActionAuthority? {
        guard let current = staged,
              current.expiresAt > Date()
        else {
            if (staged?.expiresAt ?? .distantFuture) <= Date() { staged = nil }
            return nil
        }
        staged = nil
        return current.authority
    }
}

public protocol MensoVoiceDelegating: Sendable {
    func delegate(_ delegation: AuthenticatedVoiceDelegation) async throws -> VoiceDelegationResult
}

public struct LiveVoiceReconnectPolicy: Sendable, Hashable {
    public static let standard = LiveVoiceReconnectPolicy(
        validatedMaximumAttempts: 4,
        initialDelayNanoseconds: 500_000_000,
        maximumDelayNanoseconds: 4_000_000_000
    )

    public let maximumAttempts: Int
    public let initialDelayNanoseconds: UInt64
    public let maximumDelayNanoseconds: UInt64
    public let connectionTimeoutNanoseconds: UInt64

    public init(
        maximumAttempts: Int = 4,
        initialDelayNanoseconds: UInt64 = 500_000_000,
        maximumDelayNanoseconds: UInt64 = 4_000_000_000,
        connectionTimeoutNanoseconds: UInt64 = 15_000_000_000
    ) throws {
        guard (1...8).contains(maximumAttempts),
              initialDelayNanoseconds >= 100_000_000,
              maximumDelayNanoseconds >= initialDelayNanoseconds,
              maximumDelayNanoseconds <= 30_000_000_000,
              (5_000_000_000...60_000_000_000).contains(connectionTimeoutNanoseconds)
        else {
            throw LiveVoiceError.invalidReconnectPolicy
        }
        self.maximumAttempts = maximumAttempts
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.maximumDelayNanoseconds = maximumDelayNanoseconds
        self.connectionTimeoutNanoseconds = connectionTimeoutNanoseconds
    }

    private init(
        validatedMaximumAttempts maximumAttempts: Int,
        initialDelayNanoseconds: UInt64,
        maximumDelayNanoseconds: UInt64,
        connectionTimeoutNanoseconds: UInt64 = 15_000_000_000
    ) {
        self.maximumAttempts = maximumAttempts
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.maximumDelayNanoseconds = maximumDelayNanoseconds
        self.connectionTimeoutNanoseconds = connectionTimeoutNanoseconds
    }

    func delay(forAttempt attempt: Int) -> UInt64 {
        guard attempt > 1 else { return initialDelayNanoseconds }
        var delay = initialDelayNanoseconds
        for _ in 1..<attempt {
            if delay >= maximumDelayNanoseconds / 2 { return maximumDelayNanoseconds }
            delay *= 2
        }
        return min(delay, maximumDelayNanoseconds)
    }
}

private final class GenerationScopedLiveVoiceDelegate: LiveVoiceSessionDelegate, @unchecked Sendable {
    weak var coordinator: LiveVoiceCoordinator?
    let generation: UInt64

    init(coordinator: LiveVoiceCoordinator, generation: UInt64) {
        self.coordinator = coordinator
        self.generation = generation
    }

    func liveVoiceSession(didReceive event: LiveVoiceSessionEvent) async {
        await coordinator?.receive(event, fromGeneration: generation)
    }
}

/// Keeps the live media loop responsive while delegated AgentOS work completes
/// separately. The product session ID remains stable while each replacement
/// GPT-Live transport receives a new credential and a new provider-session ID.
public actor LiveVoiceCoordinator {
    private let identity: (userID: UserID, sessionID: ProductSessionID)
    private let accessProvider: any LiveVoiceClientAccessProviding
    private let sessionFactory: any LiveVoiceSessionFactory
    private let router: any VoiceDelegationRouting
    private let operationRecognizer: any TrustedVoiceOperationRecognizing
    private let delegationBridge: any MensoVoiceDelegating
    private let checkpointStore: any LiveVoiceCheckpointPersisting
    private let routeMonitor: AVAudioEngineLiveVoiceRouteMonitor
    private let reconnectPolicy: LiveVoiceReconnectPolicy
    private let now: @Sendable () -> Date
    private var session: (any LiveVoiceSession)?
    private var configuration: LiveVoiceSessionConfiguration?
    private var providerSessionID: String?
    private var generation: UInt64 = 0
    private var activeCallRecordIDs: [String: String] = [:]
    private var checkpoint: LiveVoiceContinuityCheckpoint?
    private var checkpointPersistenceHealthy = true
    private var observers: [UUID: AsyncStream<LiveVoiceUpdate>.Continuation] = [:]
    private var state: LiveVoiceSessionState = .idle {
        didSet { publish(.state(state)) }
    }
    private var activeDelegations = 0
    private var desiredRunning = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var connectionWatchdogTask: Task<Void, Never>?
    private var continuityRetryTask: Task<Void, Never>?
    private var continuityRetryAttempt = 0
    private var routeTask: Task<Void, Never>?
    private var lastRouteSnapshot: LiveVoiceAudioRouteSnapshot?
    private var voiceProcessingFallback = true
    private var restoredTranscriptForProvider = false
    private var restoredDelegationVersions: [String: Date] = [:]

    public init(
        userID: UserID,
        sessionID: ProductSessionID,
        accessProvider: any LiveVoiceClientAccessProviding,
        sessionFactory: any LiveVoiceSessionFactory,
        router: any VoiceDelegationRouting,
        operationRecognizer: any TrustedVoiceOperationRecognizing,
        delegationBridge: any MensoVoiceDelegating,
        checkpointStore: any LiveVoiceCheckpointPersisting,
        routeMonitor: AVAudioEngineLiveVoiceRouteMonitor = AVAudioEngineLiveVoiceRouteMonitor(),
        reconnectPolicy: LiveVoiceReconnectPolicy? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identity = (userID, sessionID)
        self.accessProvider = accessProvider
        self.sessionFactory = sessionFactory
        self.router = router
        self.operationRecognizer = operationRecognizer
        self.delegationBridge = delegationBridge
        self.checkpointStore = checkpointStore
        self.routeMonitor = routeMonitor
        self.reconnectPolicy = reconnectPolicy ?? .standard
        self.now = now
    }

    public func start(
        inputFormat: LiveVoiceAudioFormat,
        voiceProcessingEnabled: Bool
    ) async throws {
        guard !desiredRunning else { return }
        desiredRunning = true
        generation &+= 1
        let startGeneration = generation
        do {
            if checkpoint == nil || !checkpointPersistenceHealthy {
                let loaded = try await checkpointStore.loadCheckpoint(
                    userID: identity.userID,
                    productSessionID: identity.sessionID
                )
                guard desiredRunning, generation == startGeneration else { return }
                if let loaded {
                    checkpoint = loaded
                } else {
                    checkpoint = try LiveVoiceContinuityCheckpoint(
                        userID: identity.userID,
                        productSessionID: identity.sessionID,
                        finalTranscript: [],
                        delegations: [],
                        updatedAt: now()
                    )
                }
                checkpointPersistenceHealthy = true
            }

            reconnectAttempt = 0
            state = .connecting
            let route = await routeMonitor.start()
            guard desiredRunning, generation == startGeneration else { return }
            lastRouteSnapshot = route
            voiceProcessingFallback = voiceProcessingEnabled
            configuration = LiveVoiceSessionConfiguration(
                userID: identity.userID,
                productSessionID: identity.sessionID,
                preferredInputFormat: inputFormat,
                voiceProcessingEnabled: route.voiceProcessingRecommendation.enabled
                    ?? voiceProcessingEnabled
            )
            startRouteObservation()
        } catch {
            if generation == startGeneration {
                desiredRunning = false
                state = .failed
            }
            throw error
        }

        do {
            try await connectReplacement()
        } catch {
            // A failed first handshake is actionable, not an established call
            // to recover silently. Stop media and let the user retry explicitly.
            if desiredRunning {
                await stop()
                state = .failed
                publish(.error(error.localizedDescription))
            }
            throw error
        }
    }

    public func sendMicrophoneAudio(_ frame: LiveVoiceAudioFrame) async throws {
        guard let session else { throw LiveVoiceError.notConnected }
        guard !session.ownsMicrophoneCapture else {
            throw LiveVoiceError.transportOwnsMicrophoneCapture
        }
        try await session.sendMicrophoneAudio(frame)
    }

    public func transportOwnsMicrophoneCapture() throws -> Bool {
        guard let session else { throw LiveVoiceError.notConnected }
        return session.ownsMicrophoneCapture
    }

    public func interruptAssistant() async {
        await session?.interruptAssistant()
    }

    public func stop() async {
        desiredRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
        continuityRetryTask?.cancel()
        continuityRetryTask = nil
        routeTask?.cancel()
        routeTask = nil
        await routeMonitor.stop()
        state = .disconnecting
        let oldSession = session
        session = nil
        providerSessionID = nil
        generation &+= 1
        activeCallRecordIDs.removeAll()
        restoredTranscriptForProvider = false
        restoredDelegationVersions.removeAll()
        await oldSession?.disconnect()
        if !desiredRunning { state = .disconnected }
    }

    public func currentState() -> LiveVoiceSessionState { state }

    public func updates() -> AsyncStream<LiveVoiceUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LiveVoiceUpdate>.makeStream(bufferingPolicy: .bufferingNewest(128))
        observers[id] = continuation
        continuation.yield(.state(state))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func publish(_ update: LiveVoiceUpdate) {
        for observer in observers.values { observer.yield(update) }
    }

    fileprivate func receive(_ event: LiveVoiceSessionEvent, fromGeneration eventGeneration: UInt64) async {
        guard eventGeneration == generation else { return }
        switch event {
        case .stateChanged(.connected):
            state = .connected
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            connectionWatchdogTask?.cancel()
            connectionWatchdogTask = nil
            continuityRetryTask?.cancel()
            continuityRetryTask = nil
            continuityRetryAttempt = 0
            await restoreCheckpointIntoCurrentSession()
            await retryPendingDelegationResults()
        case .stateChanged(.connecting):
            state = .connecting
        case .stateChanged(.reconnecting):
            state = .reconnecting
            scheduleReconnect()
        case .stateChanged(.failed), .stateChanged(.disconnected):
            connectionWatchdogTask?.cancel()
            connectionWatchdogTask = nil
            continuityRetryTask?.cancel()
            continuityRetryTask = nil
            state = desiredRunning ? .reconnecting : .disconnected
            scheduleReconnect()
        case .stateChanged(.disconnecting):
            state = .disconnecting
        case .stateChanged(.idle):
            state = .idle
        case let .transcript(segment) where segment.isFinal:
            publish(.transcript(segment))
            await recordFinalTranscript(segment)
        case .recoverableError:
            publish(.error("The voice connection encountered a problem. You can end the conversation and try again."))
        case let .delegationRequested(request):
            await acceptDelegation(request)
        default:
            return
        }
    }

    private func acceptDelegation(_ request: VoiceDelegationRequest) async {
        guard let session,
              let providerSessionID,
              activeCallRecordIDs[request.callID] == nil
        else { return }

        let recordID = PersistedVoiceDelegation.makeRecordID(
            providerSessionID: providerSessionID,
            callID: request.callID
        )
        guard checkpoint?.delegations.contains(where: { $0.recordID == recordID }) != true else { return }
        let timestamp = now()
        let record: PersistedVoiceDelegation
        do {
            record = try PersistedVoiceDelegation(
                recordID: recordID,
                providerSessionID: providerSessionID,
                callID: request.callID,
                request: request,
                state: .inFlight,
                result: nil,
                recordedAt: timestamp,
                updatedAt: timestamp
            )
            try await upsertAndPersist(record)
        } catch {
            let result = VoiceDelegationResult(
                status: .rejected,
                spokenSummary: "I couldn't safely save that request."
            )
            try? await session.sendDelegationResult(callID: request.callID, result: result)
            return
        }
        let remainsOriginalProvider = self.providerSessionID == providerSessionID
        if remainsOriginalProvider {
            activeCallRecordIDs[request.callID] = recordID
            try? await session.sendDelegationAcknowledgement(
                callID: request.callID,
                spokenText: "I'll check that."
            )
        }
        Task { [weak self] in
            await self?.performDelegation(request, recordID: recordID)
        }
        if !remainsOriginalProvider {
            await restoreCheckpointIntoCurrentSession()
        }
    }

    private func performDelegation(_ request: VoiceDelegationRequest, recordID: String) async {
        activeDelegations += 1
        publish(.working(true))
        defer {
            activeDelegations -= 1
            publish(.working(activeDelegations > 0))
        }
        let authority = await operationRecognizer.recognizedActionAuthority(for: request)
        if authority != nil { publish(.actionPrepared(false)) }
        let route = await router.route(request)
        let result: VoiceDelegationResult
        do {
            result = try await delegationBridge.delegate(
                AuthenticatedVoiceDelegation(
                    request: request,
                    route: route,
                    actionAuthority: authority,
                    userID: identity.userID,
                    sessionID: identity.sessionID
                )
            )
        } catch {
            result = VoiceDelegationResult(
                status: .rejected,
                spokenSummary: VoiceDelegationFailure.summary(for: error)
            )
        }
        guard let existing = checkpoint?.delegations.first(where: { $0.recordID == recordID }),
              existing.state == .inFlight
        else { return }
        do {
            let completed = try existing.replacing(
                state: .awaitingOriginalCall,
                result: result,
                updatedAt: now()
            )
            try await upsertAndPersist(completed)
            publish(.result(result))
            await deliverPendingDelegationResult(recordID: recordID)
            if providerSessionID != completed.providerSessionID {
                continuityRetryTask?.cancel()
                continuityRetryTask = nil
                continuityRetryAttempt = 0
                await restoreCheckpointIntoCurrentSession()
            }
        } catch {
            // The side effect may already have occurred in AgentOS. Do not
            // delegate again and do not claim a result that was not durably saved.
        }
    }

    /// Explicit retry hook for a UI/network coordinator, also invoked whenever
    /// the current WebRTC adapter reports that its data channel reconnected.
    public func retryPendingDelegationResults() async {
        let recordIDs = checkpoint?.delegations
            .filter { $0.state == .awaitingOriginalCall }
            .map(\.recordID)
            .sorted() ?? []
        for recordID in recordIDs {
            await deliverPendingDelegationResult(recordID: recordID)
        }
    }

    public func undeliveredDelegationResults() -> [String: VoiceDelegationResult] {
        var results: [String: VoiceDelegationResult] = [:]
        for record in checkpoint?.delegations ?? [] {
            guard record.state == .awaitingOriginalCall, let result = record.result else { continue }
            results[record.callID] = result
        }
        return results
    }

    private func deliverPendingDelegationResult(recordID: String) async {
        guard let session,
              let currentProviderSessionID = providerSessionID,
              let record = checkpoint?.delegations.first(where: { $0.recordID == recordID }),
              record.state == .awaitingOriginalCall,
              record.providerSessionID == currentProviderSessionID,
              let result = record.result
        else { return }
        do {
            try await session.sendDelegationResult(callID: record.callID, result: result)
            guard let latest = checkpoint?.delegations.first(where: { $0.recordID == recordID }),
                  latest == record
            else { return }
            let delivered = try latest.replacing(
                state: .deliveredToOriginalCall,
                result: result,
                updatedAt: now()
            )
            try await upsertAndPersist(delivered)
            activeCallRecordIDs.removeValue(forKey: record.callID)
        } catch {
            // The provider adapter internally remembers whether the terminal
            // output was accepted. Keep the durable record unchanged; a new
            // provider session will represent it as context, never replay its ID.
        }
    }

    private func connectReplacement() async throws {
        guard desiredRunning, let configuration else { throw LiveVoiceError.notConnected }
        let oldSession = session
        session = nil
        providerSessionID = nil
        // Invalidate every callback from the old adapter before awaiting its
        // disconnect; its terminal state cannot schedule a second replacement.
        generation &+= 1
        continuityRetryTask?.cancel()
        continuityRetryTask = nil
        let candidateGeneration = generation
        await oldSession?.disconnect()
        guard desiredRunning, generation == candidateGeneration else {
            throw LiveVoiceError.connectionCancelled
        }

        let access = try await accessProvider.clientAccess(
            for: identity.userID,
            sessionID: identity.sessionID
        )
        guard desiredRunning, generation == candidateGeneration else {
            throw LiveVoiceError.connectionCancelled
        }
        guard access.expiresAt > now().addingTimeInterval(5) else {
            throw LiveVoiceError.expiredClientAccess
        }
        let candidate = try await sessionFactory.makeSession()
        guard desiredRunning, generation == candidateGeneration else {
            await candidate.disconnect()
            throw LiveVoiceError.connectionCancelled
        }
        let candidateProviderSessionID = UUID().uuidString.lowercased()
        providerSessionID = candidateProviderSessionID
        activeCallRecordIDs.removeAll()
        restoredTranscriptForProvider = false
        restoredDelegationVersions.removeAll()
        session = candidate
        state = reconnectAttempt == 0 ? .connecting : .reconnecting
        let delegate = GenerationScopedLiveVoiceDelegate(
            coordinator: self,
            generation: candidateGeneration
        )
        do {
            try await candidate.connect(
                access: access,
                configuration: configuration,
                delegate: delegate
            )
            scheduleConnectionWatchdog(forGeneration: candidateGeneration)
        } catch {
            if generation == candidateGeneration {
                session = nil
                providerSessionID = nil
            }
            await candidate.disconnect()
            throw error
        }
    }

    private func scheduleReconnect() {
        guard desiredRunning, reconnectTask == nil else { return }
        guard reconnectAttempt < reconnectPolicy.maximumAttempts else {
            finishAfterReconnectExhaustion()
            return
        }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delay = reconnectPolicy.delay(forAttempt: attempt)
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                await self?.runReconnectAttempt(attempt)
            } catch {
                // Cancellation is an expected stop/recovery path.
            }
        }
    }

    private func runReconnectAttempt(_ attempt: Int) async {
        guard desiredRunning, reconnectAttempt == attempt else { return }
        reconnectTask = nil
        do {
            try await connectReplacement()
        } catch {
            if desiredRunning {
                state = .reconnecting
                scheduleReconnect()
            }
        }
    }

    private func scheduleConnectionWatchdog(forGeneration watchedGeneration: UInt64) {
        connectionWatchdogTask?.cancel()
        guard desiredRunning,
              generation == watchedGeneration,
              state != .connected
        else {
            connectionWatchdogTask = nil
            return
        }
        let timeout = reconnectPolicy.connectionTimeoutNanoseconds
        connectionWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
                try Task.checkCancellation()
                await self?.connectionTimedOut(generation: watchedGeneration)
            } catch {
                // Connected and stopped sessions cancel this watchdog.
            }
        }
    }

    private func connectionTimedOut(generation watchedGeneration: UInt64) {
        guard desiredRunning,
              generation == watchedGeneration,
              state != .connected
        else { return }
        connectionWatchdogTask = nil
        state = .reconnecting
        scheduleReconnect()
    }

    private func finishAfterReconnectExhaustion() {
        guard desiredRunning else { return }
        desiredRunning = false
        state = .failed
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
        continuityRetryTask?.cancel()
        continuityRetryTask = nil
        routeTask?.cancel()
        routeTask = nil
        let failedSession = session
        session = nil
        providerSessionID = nil
        generation &+= 1
        Task { [routeMonitor] in
            await routeMonitor.stop()
            await failedSession?.disconnect()
        }
    }

    private func startRouteObservation() {
        routeTask?.cancel()
        routeTask = Task { [weak self, routeMonitor] in
            let updates = await routeMonitor.updates(bufferLimit: 4)
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                await self?.handleRouteSnapshot(snapshot)
            }
        }
    }

    private func handleRouteSnapshot(_ snapshot: LiveVoiceAudioRouteSnapshot) {
        let previous = lastRouteSnapshot
        lastRouteSnapshot = snapshot
        if let current = configuration {
            configuration = LiveVoiceSessionConfiguration(
                userID: current.userID,
                productSessionID: current.productSessionID,
                preferredInputFormat: current.preferredInputFormat,
                voiceProcessingEnabled: snapshot.voiceProcessingRecommendation.enabled
                    ?? voiceProcessingFallback
            )
        }
        guard desiredRunning,
              let previous,
              previous.inputFormat != snapshot.inputFormat
                || previous.outputFormat != snapshot.outputFormat
                || previous.voiceProcessingRecommendation != snapshot.voiceProcessingRecommendation
        else { return }
        // libwebrtc owns the media graph. Replacing the complete authenticated
        // session is the only supported rebuild boundary for the selected
        // binary; no competing AVAudioEngine capture path is started.
        state = .reconnecting
        reconnectTask?.cancel()
        reconnectTask = nil
        scheduleReconnect()
    }

    private func recordFinalTranscript(_ segment: LiveTranscriptSegment) async {
        guard checkpointPersistenceHealthy, var current = checkpoint else { return }
        let text = LiveVoiceContinuityLimits.bounded(
            segment.text,
            maximumUTF8Bytes: LiveVoiceContinuityLimits.maximumTranscriptSegmentBytes
        )
        guard !text.isEmpty else { return }
        let bounded = LiveTranscriptSegment(speaker: segment.speaker, text: text, isFinal: true)
        var transcript = current.finalTranscript
        transcript.append(bounded)
        transcript = Array(transcript.suffix(LiveVoiceContinuityLimits.maximumFinalTranscriptSegments))
        do {
            current = try LiveVoiceContinuityCheckpoint(
                userID: identity.userID,
                productSessionID: identity.sessionID,
                finalTranscript: transcript,
                delegations: current.delegations,
                updatedAt: now()
            )
            try await persistCheckpoint(current)
        } catch {
            // Keep the last durably known checkpoint; never claim this segment
            // is recoverable when persistence rejected it.
        }
    }

    private func restoreCheckpointIntoCurrentSession() async {
        guard checkpointPersistenceHealthy,
              let session,
              let currentProviderSessionID = providerSessionID,
              var current = checkpoint
        else { return }
        let delegationsToRestore = current.delegations.filter {
            $0.providerSessionID != currentProviderSessionID
                && restoredDelegationVersions[$0.recordID] != $0.updatedAt
        }
        let context = Self.continuationContext(
            from: current,
            delegations: delegationsToRestore,
            includeTranscript: !restoredTranscriptForProvider
        )
        guard !context.isEmpty else {
            restoredTranscriptForProvider = true
            continuityRetryAttempt = 0
            return
        }
        do {
            try await session.restoreContinuity(context)
            guard providerSessionID == currentProviderSessionID else { return }
            let timestamp = now()
            let previousIDs = Set(delegationsToRestore.map(\.recordID))
            let updated = try current.delegations.map { record -> PersistedVoiceDelegation in
                guard previousIDs.contains(record.recordID), let result = record.result else { return record }
                return try record.replacing(
                    state: .representedInReplacement,
                    result: result,
                    updatedAt: timestamp
                )
            }
            current = try LiveVoiceContinuityCheckpoint(
                userID: identity.userID,
                productSessionID: identity.sessionID,
                finalTranscript: current.finalTranscript,
                delegations: updated,
                updatedAt: timestamp
            )
            try await persistCheckpoint(current)
            restoredTranscriptForProvider = true
            for record in current.delegations where previousIDs.contains(record.recordID) {
                restoredDelegationVersions[record.recordID] = record.updatedAt
            }
            continuityRetryAttempt = 0
            continuityRetryTask?.cancel()
            continuityRetryTask = nil
        } catch {
            // Context is optional to transport liveness but not considered
            // restored unless both provider acceptance and local state persist.
            scheduleContinuityRetry(forGeneration: generation)
        }
    }

    private func scheduleContinuityRetry(forGeneration targetGeneration: UInt64) {
        guard desiredRunning,
              state == .connected,
              continuityRetryTask == nil,
              continuityRetryAttempt < 3
        else { return }
        continuityRetryAttempt += 1
        let attempt = continuityRetryAttempt
        let delay = min(
            reconnectPolicy.initialDelayNanoseconds * UInt64(attempt),
            reconnectPolicy.maximumDelayNanoseconds
        )
        continuityRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                await self?.runContinuityRetry(
                    attempt: attempt,
                    targetGeneration: targetGeneration
                )
            } catch {
                // Session replacement and stop cancel this retry.
            }
        }
    }

    private func runContinuityRetry(attempt: Int, targetGeneration: UInt64) async {
        guard desiredRunning,
              state == .connected,
              generation == targetGeneration,
              continuityRetryAttempt == attempt
        else { return }
        continuityRetryTask = nil
        await restoreCheckpointIntoCurrentSession()
    }

    private func upsertAndPersist(_ record: PersistedVoiceDelegation) async throws {
        guard checkpointPersistenceHealthy,
              let current = checkpoint
        else { throw LiveVoiceContinuityError.persistenceRequired }
        var records = current.delegations.filter { $0.recordID != record.recordID }
        records.append(record)
        records.sort { $0.updatedAt < $1.updatedAt }
        if records.count > LiveVoiceContinuityLimits.maximumDelegationRecords {
            let removableIndex = records.firstIndex {
                $0.state == .deliveredToOriginalCall || $0.state == .representedInReplacement
            }
            guard let removableIndex else {
                throw LiveVoiceContinuityError.checkpointTooLarge
            }
            records.remove(at: removableIndex)
        }
        let updated = try LiveVoiceContinuityCheckpoint(
            userID: identity.userID,
            productSessionID: identity.sessionID,
            finalTranscript: current.finalTranscript,
            delegations: records,
            updatedAt: now()
        )
        try await persistCheckpoint(updated)
    }

    /// Publish the candidate in memory before suspension so another actor turn
    /// cannot derive and persist a stale whole-checkpoint snapshot. On failure,
    /// roll back only when no later mutation has already incorporated it.
    private func persistCheckpoint(_ updated: LiveVoiceContinuityCheckpoint) async throws {
        guard checkpointPersistenceHealthy else {
            throw LiveVoiceContinuityError.persistenceRequired
        }
        let previous = checkpoint
        checkpoint = updated
        do {
            try await checkpointStore.saveCheckpoint(updated)
        } catch {
            checkpointPersistenceHealthy = false
            if checkpoint == updated { checkpoint = previous }
            throw error
        }
    }

    static func continuationContext(
        from checkpoint: LiveVoiceContinuityCheckpoint,
        delegations: [PersistedVoiceDelegation],
        includeTranscript: Bool
    ) -> LiveVoiceContinuationContext {
        // Old assistant speech is not application state. In particular, older
        // builds persisted spoken approval claims even when no review existed.
        // Keep user context; restore outcomes through typed records below.
        let transcriptLines = (includeTranscript ? checkpoint.finalTranscript : [])
            .filter { $0.speaker == .user }
            .map { "Earlier user context (not a new request): \($0.text)" }
        let transcript = LiveVoiceContinuityLimits.bounded(
            transcriptLines.joined(separator: "\n"),
            maximumUTF8Bytes: LiveVoiceContinuityLimits.maximumTranscriptSummaryBytes
        )
        let compactDelegations = delegations.suffix(LiveVoiceContinuityLimits.maximumDelegationRecords).map { record in
            // A checkpoint records what was reported, not what is pending now.
            // Only the native review queue may assert current approval state.
            let unconfirmedApproval = record.result?.status == .requiresExternalAction
            return LiveVoiceContinuationContext.Delegation(
                recordID: record.recordID,
                status: unconfirmedApproval ? "historical_unconfirmed"
                    : record.result?.status.rawValue ?? "may_still_be_running",
                deliveryState: record.state,
                shouldAnnounce: !unconfirmedApproval && record.state == .awaitingOriginalCall && record.result != nil,
                taskSummary: LiveVoiceContinuityLimits.bounded(
                    record.request.task,
                    maximumUTF8Bytes: LiveVoiceContinuityLimits.maximumTaskSummaryBytes
                ),
                spokenSummary: unconfirmedApproval
                    ? "An earlier action request has no reconciled outcome. This saved record is not proof "
                        + "of a current approval or completion. Do not repeat it automatically."
                    : record.result.map {
                    LiveVoiceContinuityLimits.bounded(
                        $0.spokenSummary,
                        maximumUTF8Bytes: LiveVoiceContinuityLimits.maximumSpokenSummaryBytes
                    )
                },
                runID: record.result?.runID.map {
                    LiveVoiceContinuityLimits.bounded($0, maximumUTF8Bytes: 256)
                }
            )
        }
        return LiveVoiceContinuationContext(
            productSessionID: checkpoint.productSessionID,
            transcriptSummary: transcript,
            delegations: compactDelegations
        )
    }
}

public enum LiveVoiceError: Error, Sendable, Equatable {
    case invalidAudioFormat
    case emptyAudioFrame
    case invalidClientAccess
    case expiredClientAccess
    case invalidDelegation
    case invalidRouteRegistry
    case invalidReconnectPolicy
    case connectionCancelled
    case notConnected
    case transportOwnsMicrophoneCapture
}
