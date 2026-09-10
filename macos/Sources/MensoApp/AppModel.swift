import Foundation
import MensoCore
import Observation

@MainActor
@Observable
final class AppModel {
    let presentation: WidgetPresentationModel
    let appMonitor: AppMonitor
    let agentMonitor: AgentTelemetryMonitor
    let trustedRuntime: TrustedRuntime?

    enum Sheet: String, Identifiable {
        case connections
        case learnings

        var id: String { rawValue }
    }

    var permissionHealth: PermissionHealthSnapshot?
    var exhaustedContinuations: [RunContinuationDeliveryUpdate] = []
    var needsApplicationsInstall: Bool
    var presentedSheet: Sheet?
    var semanticActionKind: ApplicationSemanticActionKind = .focusWindow
    var semanticBundleIdentifier = ""
    var semanticActionText = ""
    var semanticExpectedState = ""
    var capturedSemanticTarget: FocusedApplicationTarget?
    var semanticActionIsRunning = false
    var semanticActionIsStagedForVoice = false

    @ObservationIgnored
    private let settingsStore: any SettingsPersisting
    @ObservationIgnored
    let provisioningCoordinator: TrustedRuntimeProvisioningCoordinator
    @ObservationIgnored
    private var observationStarted = false
    @ObservationIgnored
    private var runtimeTasks: [Task<Void, Never>] = []

    private static let preferencesKey = "widget.preferences.v1"

    init(
        presentation: WidgetPresentationModel = WidgetPresentationModel(),
        appMonitor: AppMonitor,
        agentMonitor: AgentTelemetryMonitor,
        settingsStore: any SettingsPersisting,
        trustedRuntime: TrustedRuntime? = nil,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.presentation = presentation
        self.appMonitor = appMonitor
        self.agentMonitor = agentMonitor
        self.settingsStore = settingsStore
        self.provisioningCoordinator = TrustedRuntimeProvisioningCoordinator(
            settingsStore: settingsStore
        )
        self.trustedRuntime = trustedRuntime
        self.needsApplicationsInstall = Self.requiresApplicationsInstall(bundleURL: bundleURL)
    }

    var agentFaces: [AgentFace] {
        let recentThreshold = Date.now.addingTimeInterval(-90)
        let activeSessions = agentMonitor.state.sessions.filter {
            $0.isProcessRunning || $0.lastActivityAt >= recentThreshold
        }
        let faces = activeSessions.map { session in
            AgentFace(
                id: session.id,
                name: session.provider.displayName,
                state: presentation.pendingActions.isEmpty ? .running : .waitingForPermission,
                provider: session.provider
            )
        }
        if faces.isEmpty {
            return [
                AgentFace(
                    id: "menso",
                    name: "Menso",
                    state: presentation.pendingActions.isEmpty ? .idle : .waitingForPermission
                ),
            ]
        }
        return faces
    }

    var collapsedOpacity: Double {
        !presentation.isExpanded && appMonitor.state.secondsSinceUserInput >= 30 ? 0.6 : 1
    }

    var todayUsage: TokenUsage {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        return agentMonitor.state.recentEvents
            .filter { $0.occurredAt >= startOfDay }
            .reduce(TokenUsage()) { $0 + $1.usage }
    }

    var isDictationConfigured: Bool {
        trustedRuntime?.capabilities.dictationConfigured == true
    }

    var isLiveVoiceConfigured: Bool {
        trustedRuntime?.capabilities.liveVoiceConfigured == true
    }

    var isSemanticActionConfigured: Bool {
        trustedRuntime?.capabilities.backendContinuationConfigured == true
    }

    var nextOnboardingPermission: MensoPermission? {
        for permission in [
            MensoPermission.accessibility,
            .microphone,
            .speechRecognition,
        ] {
            if permissionHealth?.permissions[permission]?.status != .authorized {
                return permission
            }
        }
        return nil
    }

    func start() {
        guard !observationStarted else { return }
        observationStarted = true
        appMonitor.start()
        agentMonitor.start()
        observePresentation()
        observeAgentFaces()
        observeTrustedRuntime()

        Task { [weak self, settingsStore] in
            guard
                let data = try? await settingsStore.data(forKey: Self.preferencesKey),
                let preferences = try? JSONDecoder().decode(WidgetPreferences.self, from: data)
            else { return }
            self?.presentation.preferences = preferences
        }
    }

    func stop() {
        appMonitor.stop()
        agentMonitor.stop()
        for task in runtimeTasks { task.cancel() }
        runtimeTasks.removeAll()
        if let trustedRuntime {
            Task { await trustedRuntime.stop() }
        }
    }

    func decide(actionID: String, decision: ActionPresentationDecision) {
        guard let trustedRuntime else {
            presentation.pendingActions.removeAll { $0.id == actionID }
            presentation.nonfatalMessage = "Trusted action storage is unavailable; the action remains blocked."
            return
        }
        let resolution: HumanReviewResolution
        switch decision {
        case .allowOnce: resolution = .approveOnce
        case .deny: resolution = .deny
        case .alwaysAllow: resolution = .alwaysAllow
        }
        Task { [weak self] in
            do {
                try await trustedRuntime.pauseCoordinator.resolve(
                    actionID: ActionID(rawValue: actionID),
                    resolution: resolution
                )
            } catch {
                self?.presentation.nonfatalMessage = "This approval is no longer active."
            }
        }
    }

    func replacePendingActions(_ actions: [PendingActionSummary]) {
        presentation.pendingActions = actions
    }

    func toggleDictation() {
        guard let runtime = trustedRuntime?.dictationRuntime else {
            presentation.nonfatalMessage = "Dictation is disabled until authenticated local speech components are configured."
            return
        }
        Task { await runtime.toggle(intent: .insertText) }
    }

    func toggleLiveVoice() {
        guard let runtime = trustedRuntime?.liveVoiceRuntime else {
            presentation.nonfatalMessage = "Live voice is disabled until authenticated audio and Realtime adapters are configured."
            return
        }
        Task { [weak self] in
            do {
                try await runtime.toggle()
            } catch {
                self?.presentation.nonfatalMessage = "Live voice could not start with the current authenticated configuration."
            }
        }
    }

    func captureSemanticTarget() {
        do {
            let target = try MacOSTrustedSemanticTargetProvider(
                excludedBundleIdentifiers: [Bundle.main.bundleIdentifier ?? "com.menso.app"]
            ).focusedTarget()
            capturedSemanticTarget = target
            semanticBundleIdentifier = target.bundleIdentifier
        } catch {
            presentation.nonfatalMessage = "Focus one exact app control, then capture the target again."
        }
    }

    func runSemanticAction() {
        guard !semanticActionIsRunning,
              let runtime = trustedRuntime,
              isSemanticActionConfigured
        else {
            presentation.nonfatalMessage = "Configure authenticated AgentOS before running desktop actions."
            return
        }
        do {
            let bound = try makeSemanticActionBinding()
            semanticActionIsRunning = true
            Task { [weak self] in
                defer { self?.semanticActionIsRunning = false }
                do {
                    try await runtime.startAgentRun(
                        agentID: "menso",
                        message: Self.semanticActionMessage(
                            target: bound.target,
                            operation: bound.operation
                        ),
                        expectedTarget: .focusedApplication(bound.target),
                        expectedOperation: .application(bound.operation),
                        expiresAt: Date().addingTimeInterval(5 * 60)
                    )
                } catch {
                    self?.presentation.nonfatalMessage = "The trusted desktop-action run could not be started."
                }
            }
        } catch {
            presentation.nonfatalMessage = "Capture every exact target field and complete the action value first."
        }
    }

    func stageSemanticActionForVoice() {
        guard let authorityStore = trustedRuntime?.voiceActionAuthorityStore else {
            presentation.nonfatalMessage = "Live voice is not configured for this account."
            return
        }
        do {
            let bound = try makeSemanticActionBinding()
            Task { [weak self] in
                do {
                    try await authorityStore.stage(
                        target: .focusedApplication(bound.target),
                        operation: .application(bound.operation),
                        expiresAt: Date().addingTimeInterval(5 * 60)
                    )
                    self?.semanticActionIsStagedForVoice = true
                    self?.presentation.nonfatalMessage = "The next voice desktop action may use this exact target and value for five minutes."
                } catch {
                    self?.semanticActionIsStagedForVoice = false
                    self?.presentation.nonfatalMessage = "That desktop action could not be staged safely."
                }
            }
        } catch {
            presentation.nonfatalMessage = "Capture every exact target field and complete the action value first."
        }
    }

    func presentConnections() {
        presentedSheet = .connections
    }

    func presentLearnings() {
        presentedSheet = .learnings
    }

    func retryContinuation(id: String) {
        guard let trustedRuntime else { return }
        Task { [weak self] in
            do {
                try await trustedRuntime.retryContinuation(id: id)
            } catch {
                self?.presentation.nonfatalMessage = "That saved AgentOS continuation could not be retried."
            }
        }
    }

    func refreshPermissionHealth() {
        guard let trustedRuntime else { return }
        Task { _ = await trustedRuntime.permissionHealthMonitor.refresh() }
    }

    func requestNextOnboardingPermission() {
        guard let trustedRuntime, let permission = nextOnboardingPermission else { return }
        let capability: MensoCapability
        switch permission {
        case .microphone, .speechRecognition:
            capability = .appleSpeechDictation
        case .accessibility:
            capability = .windowTitleMonitoring
        default:
            return
        }
        Task { [weak self] in
            do {
                _ = try await trustedRuntime.permissionRequestCoordinator.request(
                    permission,
                    for: capability
                )
                _ = await trustedRuntime.permissionHealthMonitor.refresh()
            } catch {
                self?.presentation.nonfatalMessage = "Menso could not request that permission."
            }
        }
    }

    private func observePresentation() {
        withObservationTracking {
            _ = presentation.isExpanded
            _ = presentation.preferences
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                appMonitor.setPanelExpanded(presentation.isExpanded)
                agentMonitor.setPanelExpanded(presentation.isExpanded)
                if let data = try? JSONEncoder().encode(presentation.preferences) {
                    try? await settingsStore.saveData(data, forKey: Self.preferencesKey)
                }
                observePresentation()
            }
        }
    }

    private func observeAgentFaces() {
        withObservationTracking {
            _ = agentMonitor.state.sessions
            _ = presentation.pendingActions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                presentation.collapsedFaceCount = min(max(agentFaces.count, 1), 4)
                observeAgentFaces()
            }
        }
    }

    private func observeTrustedRuntime() {
        guard let trustedRuntime else { return }

        runtimeTasks.append(Task { await trustedRuntime.start() })
        runtimeTasks.append(Task { [weak self] in
            let updates = await trustedRuntime.pauseCoordinator.pendingActionUpdates()
            for await actions in updates {
                guard !Task.isCancelled else { return }
                self?.presentation.pendingActions = actions
            }
        })
        runtimeTasks.append(Task { [weak self] in
            let notices = await trustedRuntime.pauseCoordinator.notices()
            for await notice in notices {
                guard !Task.isCancelled else { return }
                self?.presentation.nonfatalMessage = notice.message
            }
        })
        runtimeTasks.append(Task { [weak self] in
            guard let updates = await trustedRuntime.continuationDeliveryUpdates() else { return }
            for await update in updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                switch update.state {
                case .exhausted:
                    if let index = exhaustedContinuations.firstIndex(where: {
                        $0.continuationID == update.continuationID
                    }) {
                        exhaustedContinuations[index] = update
                    } else {
                        exhaustedContinuations.append(update)
                    }
                    exhaustedContinuations.sort { $0.occurredAt > $1.occurredAt }
                    presentation.selectedTab = .actions
                    presentation.nonfatalMessage = "An AgentOS continuation needs an explicit retry."
                case .pending, .delivered:
                    exhaustedContinuations.removeAll {
                        $0.continuationID == update.continuationID
                    }
                }
            }
        })
        runtimeTasks.append(Task { [weak self] in
            let updates = await trustedRuntime.permissionHealthMonitor.updates()
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.permissionHealth = snapshot
            }
        })
        runtimeTasks.append(Task { [weak self] in
            let events = await trustedRuntime.signalBus.events(bufferLimit: 64)
            for await signal in events {
                guard !Task.isCancelled else { return }
                guard case let .attention(attention) = signal.payload else { continue }
                self?.presentation.nonfatalMessage = "\(attention.applicationIdentifier): \(attention.title)"
            }
        })

        if let dictationRuntime = trustedRuntime.dictationRuntime {
            runtimeTasks.append(Task { [weak self] in
                let updates = await dictationRuntime.stateUpdates()
                for await state in updates {
                    guard !Task.isCancelled else { return }
                    await self?.consumeDictationState(
                        state,
                        runtime: dictationRuntime,
                        pauseCoordinator: trustedRuntime.pauseCoordinator
                    )
                }
            })
        }
    }

    private func consumeDictationState(
        _ state: DictationRuntimeState,
        runtime: any DictationRuntimeControlling,
        pauseCoordinator: RunPauseCoordinator
    ) async {
        switch state {
        case let .awaitingHumanReview(requirement):
            let summary = PendingActionSummary(
                id: requirement.actionID.rawValue,
                title: "Insert dictated text",
                detail: "Insert the exact locally transcribed text into the focused app.",
                sourceLabel: "Dictation",
                targetLabel: Self.targetLabel(requirement.target),
                expiresAt: requirement.expiresAt,
                canCreateAlwaysRule: false
            )
            do {
                try await pauseCoordinator.registerLocalReview(
                    requirement,
                    summary: summary,
                    approve: { reviewID in
                        await runtime.resumeAfterHumanReview(id: reviewID)
                    },
                    deny: { _ in
                        await runtime.cancel()
                    }
                )
            } catch {
                await runtime.cancel()
                presentation.nonfatalMessage = "Dictation approval could not be bound safely."
            }
        case let .failed(failure):
            presentation.nonfatalMessage = failure.userMessage
        default:
            break
        }
    }

    private static func targetLabel(_ target: ActionTarget) -> String {
        switch target {
        case let .focusedApplication(value): value.bundleIdentifier
        }
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

    private static func semanticActionMessage(
        target: FocusedApplicationTarget,
        operation: ApplicationSemanticOperation
    ) -> String {
        let arguments: String
        switch operation.kind {
        case .openApplication:
            arguments = "bundle_id=\(target.bundleIdentifier)"
        case .focusWindow:
            arguments = "bundle_id=\(target.bundleIdentifier), pid=\(target.processIdentifier ?? 0), window_title=\(target.windowTitle ?? "")"
        case .insertText:
            arguments = "bundle_id=\(target.bundleIdentifier), pid=\(target.processIdentifier ?? 0), window_title=\(target.windowTitle ?? ""), field_role=\(target.elementRole ?? ""), field_label=\(target.elementLabel ?? ""), text=\(operation.text ?? "")"
        case .activateControl:
            arguments = "bundle_id=\(target.bundleIdentifier), pid=\(target.processIdentifier ?? 0), window_title=\(target.windowTitle ?? ""), control_role=\(target.elementRole ?? ""), control_label=\(target.elementLabel ?? ""), expected_state=\(operation.expectedState ?? "")"
        }
        return "Perform exactly one \(operation.kind.rawValue) call with these trusted arguments: \(arguments). Do not substitute another tool, target, or value."
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
