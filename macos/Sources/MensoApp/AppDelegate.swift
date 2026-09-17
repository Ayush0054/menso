import AppKit
import MensoCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var appModel: AppModel?
    private var window: NSWindow?
    private var launchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        showWindow()
        launchTask = Task { [weak self] in await self?.finishLaunching() }
    }

    private func finishLaunching() async {
        let model: AppModel
        do {
            let database = try LocalDatabase.openDefault()
            let runtime: TrustedRuntime?
            let notice: String?
            if AppModel.requiresApplicationsInstall(bundleURL: Bundle.main.bundleURL) {
                runtime = nil
                notice = "Move Menso to Applications to enable microphone access and Mac actions."
            } else {
                let result = await makeTrustedRuntime(database: database)
                runtime = result.0
                notice = result.1
            }
            model = AppModel(settingsStore: database.settingsStore, trustedRuntime: runtime)
            model.message = notice
        } catch {
            model = AppModel(settingsStore: VolatilePersistence(), trustedRuntime: nil)
            model.message = "Local storage could not open. Restart Menso to try again."
        }
        guard !Task.isCancelled else { return }
        appModel = model
        model.onReviewNeeded = { [weak self] in
            self?.window?.deminiaturize(nil)
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.contentView = NSHostingView(rootView: MensoRootView(model: model))
        model.start()
    }

    private func showWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Menso"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 600, height: 520)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MensoDesktopWindow")
        window.contentView = NSHostingView(rootView:
            VStack(spacing: 16) {
                ProgressView()
                Text("Connecting to Menso…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        window.delegate = self
        if !window.setFrameUsingName("MensoDesktopWindow") { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchTask?.cancel()
        appModel?.stop()
    }

    func windowWillClose(_ notification: Notification) {
        appModel?.endConversation()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appModel?.refreshPermissionHealth()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func showSettings() {
        window?.makeKeyAndOrderFront(nil)
        appModel?.presentedSheet = .connections
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Menso")
        appMenu.addItem(withTitle: "About Menso", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Menso", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Menso", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
            ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
        ] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    private func makeTrustedRuntime(database: LocalDatabase) async -> (TrustedRuntime?, String?) {
        let loader = TrustedRuntimeConfigurationLoader(settingsStore: database.settingsStore)
        let driver = PinnedEmbeddedCuaDriverHost()
        switch await loader.load() {
        case let .disabled(reason):
            return (TrustedRuntime(database: database, cuaDriverHost: driver), reason)
        case let .agentOS(agentOS, notice):
            do {
                let identity = try await agentOS.authenticatedContextProvider.authenticatedProductContext()
                let router = NativeVoiceDelegationRouter()
                let format = try LiveVoiceAudioFormat(sampleRate: 48_000, channelCount: 1, encoding: .linearPCM16)
                let runtime = TrustedRuntime(database: database, cuaDriverHost: driver) { database, policy, executor, reviews in
                    guard let access = agentOS.liveVoiceClientAccessProvider else { return TrustedRuntimeFeatures() }
                    let coordinator = LiveVoiceCoordinator(
                        userID: identity.userID,
                        sessionID: identity.sessionID,
                        accessProvider: access,
                        sessionFactory: OpenAILiveWebRTCSessionFactory(),
                        router: router,
                        operationRecognizer: UnpreparedVoiceOperationRecognizer(),
                        delegationBridge: TypeSafeVoiceDelegationBridge(
                            selector: agentOS.actionSelector,
                            authenticatedContextProvider: agentOS.authenticatedContextProvider,
                            actionContextProvider: MacOSVoiceActionContextProvider(),
                            policyEngine: policy, executor: executor, reviews: reviews
                        ),
                        checkpointStore: SettingsLiveVoiceCheckpointStore(database: database)
                    )
                    return TrustedRuntimeFeatures(
                        liveVoiceRuntime: ConfiguredLiveVoiceRuntimeController(coordinator: coordinator, inputFormat: format)
                    )
                }
                return (runtime, notice)
            } catch {
                return (TrustedRuntime(database: database, cuaDriverHost: driver),
                        "The connection could not be opened. Check your account in Settings.")
            }
        }
    }
}
