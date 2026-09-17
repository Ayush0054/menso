import AppKit
import Foundation
import MensoCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum Sheet: String, Identifiable {
        case connections, action
        var id: String { rawValue }
    }

    struct Caption: Identifiable {
        let id = UUID()
        let speaker: LiveTranscriptSegment.Speaker
        var text: String
        var updatedAt = Date()
    }

    let trustedRuntime: TrustedRuntime?
    let provisioningCoordinator: TrustedRuntimeProvisioningCoordinator
    var presentedSheet: Sheet?
    var message: String?
    var permissionHealth: PermissionHealthSnapshot?
    var pendingActions: [PendingActionSummary] = []
    var exhaustedContinuations: [RunContinuationDeliveryUpdate] = []
    var voiceState: LiveVoiceSessionState = .idle
    var captions: [Caption] = []
    var captionRevision = 0
    var latestResult: VoiceDelegationResult?
    var isWorking = false
    var isChangingVoice = false
    var resolvingActionIDs: Set<String> = []
    var semanticActionKind: ApplicationSemanticActionKind = .openApplication
    var semanticBundleIdentifier = ""
    var semanticAppName = ""
    var semanticActionText = ""
    var semanticExpectedState = ""
    var capturedSemanticTarget: FocusedApplicationTarget?
    var semanticActionIsStagedForVoice = false
    var stagedActionLabel: String?
    var isCapturingTarget = false

    @ObservationIgnored private var runtimeTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var stagedExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(settingsStore: any SettingsPersisting, trustedRuntime: TrustedRuntime?) {
        self.trustedRuntime = trustedRuntime
        self.provisioningCoordinator = TrustedRuntimeProvisioningCoordinator(settingsStore: settingsStore)
    }

    var isLiveVoiceConfigured: Bool { trustedRuntime?.capabilities.liveVoiceConfigured == true }
    var isConversationActive: Bool {
        [.connecting, .connected, .reconnecting, .disconnecting].contains(voiceState)
    }
    var microphoneGranted: Bool { permissionHealth?.permissions[.microphone]?.status == .authorized }
    var accessibilityGranted: Bool { permissionHealth?.permissions[.accessibility]?.status == .authorized }

    var voiceStatus: String {
        switch voiceState {
        case .idle, .disconnected: "Ready when you are"
        case .connecting: "Connecting…"
        case .connected: isWorking ? "Working on your request" : "Conversation live"
        case .reconnecting: "Reconnecting…"
        case .disconnecting: "Ending conversation…"
        case .failed: "Couldn't connect"
        }
    }

    func start() {
        guard !started, let runtime = trustedRuntime else { return }
        started = true
        runtimeTasks.append(Task { await runtime.start() })
        runtimeTasks.append(Task { [weak self] in
            for await actions in await runtime.pauseCoordinator.pendingActionUpdates() {
                guard !Task.isCancelled else { return }
                self?.pendingActions = actions
            }
        })
        runtimeTasks.append(Task { [weak self] in
            for await notice in await runtime.pauseCoordinator.notices() {
                guard !Task.isCancelled else { return }
                self?.message = notice.message
            }
        })
        runtimeTasks.append(Task { [weak self] in
            for await snapshot in await runtime.permissionHealthMonitor.updates() {
                guard !Task.isCancelled else { return }
                self?.permissionHealth = snapshot
            }
        })
        runtimeTasks.append(Task { [weak self] in
            guard let updates = await runtime.continuationDeliveryUpdates() else { return }
            for await update in updates {
                guard !Task.isCancelled, let self else { return }
                exhaustedContinuations.removeAll { $0.continuationID == update.continuationID }
                if update.state == .exhausted { exhaustedContinuations.append(update) }
            }
        })
        if let voice = runtime.liveVoiceRuntime {
            runtimeTasks.append(Task { [weak self] in
                for await update in await voice.updates() {
                    guard !Task.isCancelled, let self else { return }
                    switch update {
                    case let .state(state): voiceState = state
                    case let .transcript(segment): appendCaption(segment)
                    case let .working(working):
                        isWorking = working
                        if working { latestResult = nil }
                    case let .actionPrepared(prepared):
                        semanticActionIsStagedForVoice = prepared
                        if !prepared { stagedActionLabel = nil }
                    case let .result(result): latestResult = result
                    case let .error(text): message = text
                    }
                }
            })
        }
    }

    func stop() {
        captureTask?.cancel()
        stagedExpiryTask?.cancel()
        runtimeTasks.forEach { $0.cancel() }
        runtimeTasks.removeAll()
        if let trustedRuntime { Task { await trustedRuntime.stop() } }
    }

    func toggleLiveVoice() {
        guard !isChangingVoice, let runtime = trustedRuntime?.liveVoiceRuntime else { return }
        isChangingVoice = true
        message = nil
        Task { [weak self] in
            defer { self?.isChangingVoice = false }
            do { try await runtime.toggle() }
            catch { self?.message = "Couldn't start the conversation. Check your microphone and connection." }
        }
    }

    func endConversation() {
        guard let runtime = trustedRuntime?.liveVoiceRuntime else { return }
        clearPreparedAction()
        Task { await runtime.stop() }
    }

    private func appendCaption(_ segment: LiveTranscriptSegment) {
        // Full-duplex captions accumulate independently for each speaker.
        if let index = captions.lastIndex(where: { $0.speaker == segment.speaker }),
           Date().timeIntervalSince(captions[index].updatedAt) < 4 {
            captions[index].text = String((captions[index].text + segment.text).suffix(8_000))
            captions[index].updatedAt = Date()
        } else {
            captions.append(Caption(speaker: segment.speaker, text: segment.text))
        }
        if captions.count > 80 { captions.removeFirst(captions.count - 80) }
        captionRevision &+= 1
    }

    func decide(actionID: String, decision: ActionPresentationDecision) {
        guard let runtime = trustedRuntime, resolvingActionIDs.insert(actionID).inserted else { return }
        let resolution: HumanReviewResolution
        switch decision {
        case .deny: resolution = .deny
        case .allowOnce, .alwaysAllow: resolution = .approveOnce
        }
        Task { [weak self] in
            defer { self?.resolvingActionIDs.remove(actionID) }
            do {
                try await runtime.pauseCoordinator.resolve(
                    actionID: ActionID(rawValue: actionID),
                    resolution: resolution
                )
            } catch { self?.message = "This approval is no longer active." }
        }
    }

    func retryContinuation(id: String) {
        guard let runtime = trustedRuntime else { return }
        Task { [weak self] in
            do { try await runtime.retryContinuation(id: id) }
            catch { self?.message = "Couldn't deliver the saved result. Please try again." }
        }
    }

    func refreshPermissionHealth() {
        guard let runtime = trustedRuntime else { return }
        Task { _ = await runtime.permissionHealthMonitor.refresh() }
    }

    func requestPermission(_ permission: MensoPermission) {
        guard let runtime = trustedRuntime else { return }
        Task { [weak self] in
            do {
                let status = try await runtime.permissionRequestCoordinator.request(
                    permission, for: permission == .microphone ? .liveVoice : .semanticComputerUse
                )
                let health = await runtime.permissionHealthMonitor.refresh()
                if status == .denied, let url = health.permissions[permission]?.settingsDeepLink {
                    NSWorkspace.shared.open(url)
                }
            } catch { self?.message = "Open System Settings to allow this permission for Menso." }
        }
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose app"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        semanticBundleIdentifier = identifier
        semanticAppName = url.deletingPathExtension().lastPathComponent
        capturedSemanticTarget = nil
    }

    func captureSemanticTarget() {
        guard !isCapturingTarget else { return }
        isCapturingTarget = true
        NSApp.hide(nil)
        captureTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                guard let self else { return }
                defer {
                    isCapturingTarget = false
                    NSApp.unhide(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                let target = try MacOSTrustedSemanticTargetProvider(
                    excludedBundleIdentifiers: [Bundle.main.bundleIdentifier ?? "com.menso.app"]
                ).focusedTarget()
                capturedSemanticTarget = target
                semanticBundleIdentifier = target.bundleIdentifier
                semanticAppName = NSWorkspace.shared.runningApplications.first {
                    $0.bundleIdentifier == target.bundleIdentifier
                }?.localizedName ?? target.bundleIdentifier
            } catch {
                self?.isCapturingTarget = false
                self?.message = "Select an app window or text field, then capture it again."
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func stageSemanticActionForVoice() {
        guard let store = trustedRuntime?.voiceActionAuthorityStore else { return }
        do {
            let bound = try makeSemanticActionBinding()
            let label = semanticAppName.isEmpty ? semanticBundleIdentifier : semanticAppName
            Task { [weak self] in
                do {
                    try await store.stage(
                        target: .focusedApplication(bound.target),
                        operation: .application(bound.operation),
                        expiresAt: Date().addingTimeInterval(300)
                    )
                    guard let self else { return }
                    semanticActionIsStagedForVoice = true
                    stagedActionLabel = label
                    presentedSheet = nil
                    stagedExpiryTask?.cancel()
                    stagedExpiryTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(300))
                        guard !Task.isCancelled else { return }
                        self?.clearPreparedAction()
                    }
                } catch { self?.message = "Couldn't prepare that action. Capture the target again." }
            }
        } catch { message = "Choose the exact app or control and complete the action first." }
    }

    func clearPreparedAction() {
        semanticActionIsStagedForVoice = false
        stagedActionLabel = nil
        stagedExpiryTask?.cancel()
        if let store = trustedRuntime?.voiceActionAuthorityStore { Task { await store.clear() } }
    }

    private func makeSemanticActionBinding() throws -> (
        target: FocusedApplicationTarget,
        operation: ApplicationSemanticOperation
    ) {
        let bundle = semanticBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else { throw TrustedSemanticTargetError.unavailable }
        switch semanticActionKind {
        case .openApplication:
            return (
                FocusedApplicationTarget(bundleIdentifier: bundle),
                ApplicationSemanticOperation(kind: .openApplication)
            )
        case .focusWindow:
            guard let capturedSemanticTarget,
                  capturedSemanticTarget.bundleIdentifier == bundle,
                  capturedSemanticTarget.processIdentifier != nil,
                  capturedSemanticTarget.windowTitle?.isEmpty == false
            else { throw TrustedSemanticTargetError.unavailable }
            return (
                FocusedApplicationTarget(
                    bundleIdentifier: bundle,
                    processIdentifier: capturedSemanticTarget.processIdentifier,
                    windowTitle: capturedSemanticTarget.windowTitle
                ),
                ApplicationSemanticOperation(kind: .focusWindow)
            )
        case .insertText:
            guard let capturedSemanticTarget,
                  capturedSemanticTarget.bundleIdentifier == bundle,
                  ["AXTextField", "AXTextArea", "AXSearchField"].contains(
                      capturedSemanticTarget.elementRole ?? ""
                  ),
                  capturedSemanticTarget.windowTitle?.isEmpty == false,
                  capturedSemanticTarget.elementLabel?.isEmpty == false,
                  !semanticActionText.isEmpty
            else { throw TrustedSemanticTargetError.unavailable }
            return (
                capturedSemanticTarget,
                ApplicationSemanticOperation(kind: .insertText, text: semanticActionText)
            )
        case .activateControl:
            guard let capturedSemanticTarget,
                  capturedSemanticTarget.bundleIdentifier == bundle,
                  ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton"].contains(
                      capturedSemanticTarget.elementRole ?? ""
                  ),
                  capturedSemanticTarget.windowTitle?.isEmpty == false,
                  capturedSemanticTarget.elementLabel?.isEmpty == false,
                  !semanticExpectedState.isEmpty
            else { throw TrustedSemanticTargetError.unavailable }
            return (
                capturedSemanticTarget,
                ApplicationSemanticOperation(
                    kind: .activateControl,
                    expectedState: semanticExpectedState
                )
            )
        }
    }

    static func requiresApplicationsInstall(bundleURL: URL) -> Bool {
        guard bundleURL.pathExtension.lowercased() == "app" else { return false }
        let standardizedPath = bundleURL.standardizedFileURL.path
        return standardizedPath.contains("/AppTranslocation/")
            || !(standardizedPath == "/Applications/Menso.app"
                || standardizedPath.hasPrefix("/Applications/")
                || standardizedPath.hasPrefix("/System/Applications/"))
    }
}
