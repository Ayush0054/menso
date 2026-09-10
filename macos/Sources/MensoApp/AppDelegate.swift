import AppKit
import MensoCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appModel: AppModel?
    private var windowController: WidgetPanelController?
    private var statusMenuController: StatusMenuController?
    private var updaterController: AppUpdaterController?
    private var approvalHotkeys: CarbonApprovalHotkeyRegistrar?
    private var dictationHotkey: CarbonDictationHotkeyRegistrar?
    private var dictationHUD: DictationHUDController?
    private var axDialogMonitor: AXDialogSignalMonitor?
    private var screenObserver: NSObjectProtocol?
    private var launchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launchTask = Task { [weak self] in
            await self?.finishLaunching()
        }
    }

    private func finishLaunching() async {
        let stores = await makeStores()
        let appMonitor = AppMonitor()
        let ingestor = AgentTelemetryIngestor(
            usageStore: stores.usage,
            cursorStore: stores.cursor,
            rateLimitStore: stores.rateLimits
        )
        let agentMonitor = AgentTelemetryMonitor(ingestor: ingestor)
        let model = AppModel(
            appMonitor: appMonitor,
            agentMonitor: agentMonitor,
            settingsStore: stores.settings,
            trustedRuntime: stores.trustedRuntime
        )
        model.presentation.nonfatalMessage = stores.nonfatalMessage
        let updater = AppUpdaterController()
        let statusMenu = StatusMenuController(model: model, updaterController: updater)
        let window = WidgetPanelController(
            presentation: model.presentation,
            positionStore: stores.position
        ) {
            MensoRootView(model: model) { event in
                statusMenu.presentContextMenu(with: event)
            }
        }

        statusMenu.windowController = window
        statusMenu.install()
        appModel = model
        windowController = window
        statusMenuController = statusMenu
        updaterController = updater

        model.start()
        window.restoreAndShow(expanded: false)

        if let runtime = stores.trustedRuntime {
            let dialogMonitor = AXDialogSignalMonitor(signalBus: runtime.signalBus)
            dialogMonitor.start()
            axDialogMonitor = dialogMonitor

            if let dictationRuntime = runtime.dictationRuntime {
                let hud = DictationHUDController(runtime: dictationRuntime)
                hud.start()
                dictationHUD = hud

                let hotkey = CarbonDictationHotkeyRegistrar()
                do {
                    try hotkey.register(hotkey: .standard) { [weak model] in
                        model?.toggleDictation()
                    }
                    dictationHotkey = hotkey
                } catch {
                    if model.presentation.nonfatalMessage == nil {
                        model.presentation.nonfatalMessage = "The dictation hotkey is unavailable; the Dictate button still works."
                    }
                }
            }
        }

        let hotkeys = CarbonApprovalHotkeyRegistrar()
        do {
            try hotkeys.register(
                approve: { [weak model] in
                    guard let action = model?.presentation.pendingActions.first else { return }
                    model?.decide(actionID: action.id, decision: .allowOnce)
                },
                deny: { [weak model] in
                    guard let action = model?.presentation.pendingActions.first else { return }
                    model?.decide(actionID: action.id, decision: .deny)
                }
            )
            approvalHotkeys = hotkeys
        } catch {
            if model.presentation.nonfatalMessage == nil {
                model.presentation.nonfatalMessage = "Approval hotkeys are unavailable; approval buttons still work."
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.windowController?.screenParametersDidChange()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchTask?.cancel()
        axDialogMonitor?.stop()
        dictationHUD?.stop()
        dictationHotkey?.unregister()
        appModel?.stop()
        approvalHotkeys?.unregister()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        windowController?.show(expanded: true)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appModel?.refreshPermissionHealth()
        axDialogMonitor?.refreshRunningApplications()
    }

    private func makeStores() async -> StoreBundle {
        do {
            let database = try LocalDatabase.openDefault()
            let requiresInstall = AppModel.requiresApplicationsInstall(bundleURL: Bundle.main.bundleURL)
            let runtimeResult: (TrustedRuntime?, String?)
            if requiresInstall {
                runtimeResult = (
                    nil,
                    "Move Menso to Applications before enabling trusted actions or permissions."
                )
            } else {
                runtimeResult = await makeTrustedRuntime(database: database)
            }
            return StoreBundle(
                usage: database.usageStore,
                cursor: database.cursorStore,
                rateLimits: database.rateLimitStore,
                position: database.positionStore,
                settings: database.settingsStore,
                trustedRuntime: runtimeResult.0,
                nonfatalMessage: runtimeResult.1
            )
        } catch {
            let fallback = VolatilePersistence()
            let bundle = StoreBundle(
                usage: fallback,
                cursor: fallback,
                rateLimits: fallback,
                position: fallback,
                settings: fallback,
                trustedRuntime: nil,
                nonfatalMessage: "Local persistence is unavailable. Monitoring remains in memory, but trusted actions and integrations are disabled."
            )
            return bundle
        }
    }

    private func makeTrustedRuntime(database: LocalDatabase) async -> (TrustedRuntime?, String?) {
        let loader = TrustedRuntimeConfigurationLoader(settingsStore: database.settingsStore)
        let claudeHookFactory = ClaudeHookRuntimeFactory()
        // Claude hooks are an independent local capability. A missing or
        // malformed hook token disables only the loopback receiver; it must not
        // disable authenticated AgentOS or voice composition.
        let claudeHookConfiguration = try? await claudeHookFactory
            .provisionedConfiguration()
        // One app-owned host is shared by whichever runtime branch wins. It
        // starts only when an authorized semantic action reaches the broker;
        // missing or mismatched reviewed resources fail that action closed.
        let cuaDriverHost = PinnedEmbeddedCuaDriverHost()
        switch await loader.load() {
        case let .disabled(reason):
            // The core graph still provides permissions, fail-closed local
            // action storage, and an independently provisioned local Claude
            // hook. No backend adapter is started.
            let runtime = TrustedRuntime(
                database: database,
                cuaDriverHost: cuaDriverHost
            ) { _, signalBus, _, _, pauseCoordinator in
                let receiver = claudeHookConfiguration.map {
                    claudeHookFactory.makeReceiver(
                        configuration: $0,
                        signalBus: signalBus,
                        pauseCoordinator: pauseCoordinator
                    )
                }
                return TrustedRuntimeFeatures(claudeHookReceiver: receiver)
            }
            return (
                runtime,
                reason
            )
        case let .agentOS(agentOS, notice):
            do {
                // Voice is optional. Pin its identity only when the verified
                // account was granted Realtime access, and do not let a
                // transient voice-only refresh disable AgentOS.
                let voiceIdentity: AuthenticatedProductContext?
                if agentOS.liveVoiceClientAccessProvider != nil {
                    voiceIdentity = try? await agentOS.authenticatedContextProvider
                        .authenticatedProductContext()
                } else {
                    voiceIdentity = nil
                }
                let voiceIdentityNotice: String? = agentOS.liveVoiceClientAccessProvider != nil
                    && voiceIdentity == nil
                    ? "Live voice is temporarily disabled because authenticated identity could not be refreshed."
                    : nil
                let voiceRouter = try RegisteredVoiceDelegationRouter(
                    agentID: MensoAgentOSVoiceDelegationBridge.agentID
                )
                let voiceInputFormat = try LiveVoiceAudioFormat(
                    sampleRate: 48_000,
                    channelCount: 1,
                    encoding: .linearPCM16
                )
                let runtime = try TrustedRuntime(
                    database: database,
                    agentOS: agentOS.configuration,
                    cuaDriverHost: cuaDriverHost
                ) { context in
                    let dictationRuntime = DictationCoordinator(
                        audioCapture: AVAudioEngineDictationCapture(),
                        transcriber: AppleOnDeviceDictationTranscriber(),
                        contextProvider: VerifiedAgentOSDictationContextProvider(
                            provider: context.authenticatedContextProvider
                        ),
                        targetProvider: MacOSFocusedApplicationTargetProvider(
                            excludedBundleIdentifiers: [Bundle.main.bundleIdentifier ?? "com.menso.app"]
                        ),
                        policyEngine: context.policyEngine,
                        actionExecutor: context.actionExecutor,
                        transcriptionConfiguration: DictationTranscriptionConfiguration(
                            localeIdentifier: Locale.current.identifier,
                            addsPunctuation: true
                        )
                    )
                    let liveVoiceRuntime: ConfiguredLiveVoiceRuntimeController?
                    let voiceActionAuthorityStore: UserStagedVoiceActionAuthorityStore?
                    if let accessProvider = agentOS.liveVoiceClientAccessProvider,
                       let voiceIdentity
                    {
                        let authorityStore = UserStagedVoiceActionAuthorityStore()
                        let delegationBridge = MensoAgentOSVoiceDelegationBridge(
                            client: context.runClient,
                            streamHandler: context.streamHandler,
                            authenticatedContextProvider: context.authenticatedContextProvider,
                            actionResultStore: context.database.actionStore
                        )
                        let voiceCoordinator = LiveVoiceCoordinator(
                            userID: voiceIdentity.userID,
                            sessionID: voiceIdentity.sessionID,
                            accessProvider: accessProvider,
                            sessionFactory: OpenAIRealtimeWebRTCSessionFactory(),
                            router: voiceRouter,
                            operationRecognizer: authorityStore,
                            delegationBridge: delegationBridge,
                            checkpointStore: SettingsLiveVoiceCheckpointStore(database: context.database)
                        )
                        liveVoiceRuntime = ConfiguredLiveVoiceRuntimeController(
                            coordinator: voiceCoordinator,
                            inputFormat: voiceInputFormat
                        )
                        voiceActionAuthorityStore = authorityStore
                    } else {
                        liveVoiceRuntime = nil
                        voiceActionAuthorityStore = nil
                    }
                    let receiver = claudeHookConfiguration.map {
                        claudeHookFactory.makeReceiver(
                            configuration: $0,
                            signalBus: context.signalBus,
                            pauseCoordinator: context.pauseCoordinator
                        )
                    }
                    return TrustedRuntimeFeatures(
                        claudeHookReceiver: receiver,
                        dictationRuntime: dictationRuntime,
                        liveVoiceRuntime: liveVoiceRuntime,
                        voiceActionAuthorityStore: voiceActionAuthorityStore
                    )
                }
                let effectiveNotice = [notice, voiceIdentityNotice]
                    .compactMap { $0 }
                    .joined(separator: " ")
                return (runtime, effectiveNotice.isEmpty ? nil : effectiveNotice)
            } catch {
                return (
                    TrustedRuntime(database: database, cuaDriverHost: cuaDriverHost),
                    "Authenticated runtime composition failed; trusted integrations remain disabled."
                )
            }
        }
    }
}

private struct StoreBundle {
    let usage: any UsageEventPersisting
    let cursor: any FileCursorPersisting
    let rateLimits: any AgentRateLimitPersisting
    let position: any WindowPositionPersisting
    let settings: any SettingsPersisting
    let trustedRuntime: TrustedRuntime?
    let nonfatalMessage: String?
}
