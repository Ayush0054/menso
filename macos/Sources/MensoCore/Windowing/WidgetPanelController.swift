import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
public final class WidgetPanelController: NSObject, NSWindowDelegate {
    public let panel: MensoPanel

    private let presentation: WidgetPresentationModel
    private let positionStore: any WindowPositionPersisting
    private let snapCoordinator: PanelSnapCoordinator
    private var currentPosition: DockedWindowPosition?
    private var snapTask: Task<Void, Never>?
    private var isApplyingFrame = false

    public init<Content: View>(
        presentation: WidgetPresentationModel,
        positionStore: any WindowPositionPersisting,
        snapCoordinator: PanelSnapCoordinator = PanelSnapCoordinator(),
        @ViewBuilder content: () -> Content
    ) {
        self.presentation = presentation
        self.positionStore = positionStore
        self.snapCoordinator = snapCoordinator
        panel = MensoPanel()
        super.init()

        let hostingView = TransparentHostingView(rootView: AnyView(content()))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.containsInteractivePoint = { [weak presentation] point, bounds in
            guard let presentation else { return false }
            if presentation.isExpanded {
                return NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 22, yRadius: 22)
                    .contains(point)
            }
            let edge = presentation.currentPosition?.edge ?? .right
            let robotRect = WidgetGeometry.robotStackRect(
                in: bounds,
                edge: edge,
                dimension: presentation.preferences.size.dimension,
                faceCount: presentation.collapsedFaceCount
            )
            let bubbleRect = WidgetGeometry.approvalBubbleStackRect(
                in: bounds,
                edge: edge,
                dimension: presentation.preferences.size.dimension,
                faceCount: presentation.collapsedFaceCount,
                bubbleCount: presentation.pendingActions.count
            )
            return robotRect.contains(point) || bubbleRect.contains(point)
        }
        panel.contentView = hostingView
        panel.delegate = self
        observePresentation()
    }

    deinit {
        snapTask?.cancel()
    }

    public func restoreAndShow(expanded: Bool? = nil) {
        presentation.show(expanded: expanded)
        let screen = preferredScreen()
        let fallback = DockedWindowPosition(
            displayID: screen.mensoDisplayID,
            edge: .right,
            fractionalOffset: 0.55
        )
        currentPosition = fallback
        presentation.currentPosition = fallback
        apply(position: fallback, on: screen)
        panel.orderFrontRegardless()

        Task { [weak self, positionStore] in
            guard let saved = try? await positionStore.position(forDisplayID: screen.mensoDisplayID) else {
                return
            }
            self?.currentPosition = saved
            self?.presentation.currentPosition = saved
            self?.apply(position: saved, on: screen)
        }
    }

    public func show(expanded: Bool? = nil) {
        presentation.show(expanded: expanded)
        syncVisibility()
    }

    /// Temporarily activates the accessory app for a user-requested editor or
    /// settings sheet. The normal floating widget remains nonactivating, but a
    /// SwiftUI text field cannot receive keyboard input unless its containing
    /// panel is the key window of an active application.
    public func showForUserInteraction(expanded: Bool? = nil) {
        presentation.show(expanded: expanded)
        panel.ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        presentation.hide()
        syncVisibility()
    }

    public func resetPosition() {
        let screen = NSScreen.main ?? preferredScreen()
        let position = DockedWindowPosition(
            displayID: screen.mensoDisplayID,
            edge: .right,
            fractionalOffset: 0.55
        )
        currentPosition = position
        presentation.currentPosition = position
        apply(position: position, on: screen)
        Task { [positionStore] in
            try? await positionStore.deletePositions()
            try? await positionStore.savePosition(position)
        }
    }

    public func screenParametersDidChange() {
        let position = currentPosition
            ?? DockedWindowPosition(displayID: preferredScreen().mensoDisplayID, edge: .right, fractionalOffset: 0.55)
        let screen = snapCoordinator.screen(for: position.displayID) ?? preferredScreen()
        let redocked = DockedWindowPosition(
            displayID: screen.mensoDisplayID,
            edge: position.edge,
            fractionalOffset: position.fractionalOffset,
            isPeeking: position.isPeeking
        )
        currentPosition = redocked
        presentation.currentPosition = redocked
        apply(position: redocked, on: screen)
    }

    public func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame else { return }
        snapTask?.cancel()
        snapTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            self?.snapAndPersist()
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        presentation.hide()
        return false
    }

    private func snapAndPersist() {
        let screen = snapCoordinator.nearestScreen(to: panel.frame) ?? preferredScreen()
        let position = snapCoordinator.capture(
            frame: panel.frame,
            screen: screen,
            spriteDimension: presentation.preferences.size.dimension
        )
        currentPosition = position
        presentation.currentPosition = position
        apply(position: position, on: screen)
        Task { [positionStore] in
            try? await positionStore.savePosition(position)
        }
    }

    private func apply(position: DockedWindowPosition, on screen: NSScreen) {
        isApplyingFrame = true
        panel.setFrame(
            snapCoordinator.frame(
                for: position,
                on: screen,
                panelSize: MensoPanel.expandedSize,
                spriteDimension: presentation.preferences.size.dimension,
                isExpanded: presentation.isExpanded
            ),
            display: true,
            animate: false
        )
        isApplyingFrame = false
    }

    private func observePresentation() {
        withObservationTracking {
            _ = presentation.isExpanded
            _ = presentation.isVisible
            _ = presentation.preferences.ghostMode
            _ = presentation.preferences.size
            _ = presentation.preferences.hideInFullScreen
            _ = presentation.preferences.excludeFromScreenShare
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyPresentation()
                self?.observePresentation()
            }
        }
    }

    private func applyPresentation() {
        panel.ignoresMouseEvents = presentation.preferences.ghostMode
        panel.sharingType = presentation.preferences.excludeFromScreenShare ? .none : .readOnly
        panel.collectionBehavior = presentation.preferences.hideInFullScreen
            ? [.canJoinAllSpaces, .stationary, .ignoresCycle]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        if let currentPosition {
            let screen = snapCoordinator.screen(for: currentPosition.displayID) ?? preferredScreen()
            apply(position: currentPosition, on: screen)
        }
        syncVisibility()
    }

    private func syncVisibility() {
        if presentation.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func preferredScreen() -> NSScreen {
        panel.screen ?? NSScreen.main ?? NSScreen.screens.first!
    }
}
