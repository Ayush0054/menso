import AppKit
import MensoCore
import ServiceManagement

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    weak var windowController: WidgetPanelController?

    private let model: AppModel
    private let updaterController: AppUpdaterController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu(title: "Menso")

    init(model: AppModel, updaterController: AppUpdaterController) {
        self.model = model
        self.updaterController = updaterController
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func install() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Menso")
            button.image?.isTemplate = true
            button.toolTip = "Menso"
        }
        rebuildMenu()
        statusItem.menu = menu
    }

    func presentContextMenu(with event: NSEvent) {
        rebuildMenu()
        guard let view = event.window?.contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(item(
            model.presentation.isVisible ? "Hide Menso" : "Show Menso",
            action: #selector(toggleVisibility),
            key: "m"
        ))
        menu.addItem(item(
            model.presentation.isExpanded ? "Collapse" : "Open Panel",
            action: #selector(toggleExpanded),
            key: "o"
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            "Do Not Disturb",
            action: #selector(toggleDoNotDisturb),
            state: model.presentation.preferences.doNotDisturb
        ))
        menu.addItem(item(
            "Ghost / Click-through",
            action: #selector(toggleGhostMode),
            state: model.presentation.preferences.ghostMode
        ))

        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: "Size")
        for size in WidgetSize.allCases {
            let child = item(
                size.title,
                action: #selector(selectSize(_:)),
                state: model.presentation.preferences.size == size
            )
            child.representedObject = size.rawValue
            sizeMenu.addItem(child)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(item(
            "Hide in Full Screen",
            action: #selector(toggleHideInFullScreen),
            state: model.presentation.preferences.hideInFullScreen
        ))
        menu.addItem(item(
            "Exclude from Screen Share",
            action: #selector(toggleScreenShareExclusion),
            state: model.presentation.preferences.excludeFromScreenShare
        ))
        menu.addItem(item(
            "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            state: SMAppService.mainApp.status == .enabled
        ))
        menu.addItem(.separator())
        menu.addItem(item("Connections…", action: #selector(showConnections)))
        let learningsItem = item("What Menso learned…", action: #selector(showLearnings))
        learningsItem.isEnabled = model.trustedRuntime?.learningManager != nil
        menu.addItem(learningsItem)
        let updateItem = item("Check for Updates…", action: #selector(checkForUpdates))
        updateItem.isEnabled = updaterController.canCheckForUpdates
        updateItem.toolTip = updaterController.unavailableReason
        menu.addItem(updateItem)
        menu.addItem(item("Reset Position", action: #selector(resetPosition)))
        menu.addItem(item("Quit Menso", action: #selector(quit), key: "q"))
    }

    private func item(
        _ title: String,
        action: Selector,
        key: String = "",
        state: Bool = false
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = state ? .on : .off
        item.isEnabled = true
        return item
    }

    @objc private func toggleVisibility() {
        if model.presentation.isVisible {
            windowController?.hide()
        } else {
            windowController?.show()
        }
    }

    @objc private func toggleExpanded() {
        model.presentation.isExpanded.toggle()
        windowController?.show()
    }

    @objc private func toggleDoNotDisturb() {
        model.presentation.preferences.doNotDisturb.toggle()
    }

    @objc private func toggleGhostMode() {
        model.presentation.preferences.ghostMode.toggle()
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let size = WidgetSize(rawValue: rawValue)
        else { return }
        model.presentation.preferences.size = size
    }

    @objc private func toggleHideInFullScreen() {
        model.presentation.preferences.hideInFullScreen.toggle()
    }

    @objc private func toggleScreenShareExclusion() {
        model.presentation.preferences.excludeFromScreenShare.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                model.presentation.preferences.launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                model.presentation.preferences.launchAtLogin = true
            }
        } catch {
            model.presentation.nonfatalMessage = "Launch at login could not be changed: \(error.localizedDescription)"
        }
    }

    @objc private func resetPosition() {
        windowController?.resetPosition()
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates()
    }

    @objc private func showConnections() {
        model.presentConnections()
        windowController?.showForUserInteraction(expanded: true)
    }

    @objc private func showLearnings() {
        model.presentLearnings()
        windowController?.showForUserInteraction(expanded: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
