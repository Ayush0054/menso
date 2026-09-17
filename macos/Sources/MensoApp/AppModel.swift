import AppKit
import Foundation
import MensoCore
import Observation

@MainActor
@Observable
final class AppModel {
    enum Sheet: String, Identifiable {
        case connections
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

    @ObservationIgnored private var runtimeTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored var onReviewNeeded: (@MainActor () -> Void)?

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
        case .connected:
            !pendingActions.isEmpty ? "Waiting for your approval"
                : isWorking ? "Working on your request" : "Conversation live"
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
                guard let self else { return }
                let previous = Set(pendingActions.map(\.id))
                pendingActions = actions
                if isConversationActive, actions.contains(where: { !previous.contains($0.id) }) {
                    onReviewNeeded?()
                }
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
                    case .actionPrepared: break // Legacy prepared-action sessions.
                    case let .result(result): latestResult = result
                    case let .error(text): message = text
                    }
                }
            })
        }
    }

    func stop() {
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
            catch { self?.message = error.localizedDescription }
        }
    }

    func endConversation() {
        guard let runtime = trustedRuntime?.liveVoiceRuntime else { return }
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
    static func requiresApplicationsInstall(bundleURL: URL) -> Bool {
        guard bundleURL.pathExtension.lowercased() == "app" else { return false }
        let standardizedPath = bundleURL.standardizedFileURL.path
        return standardizedPath.contains("/AppTranslocation/")
            || !(standardizedPath == "/Applications/Menso.app"
                || standardizedPath.hasPrefix("/Applications/")
                || standardizedPath.hasPrefix("/System/Applications/"))
    }
}
