import AppKit
import SwiftUI

public struct PanelDragSurface: NSViewRepresentable {
    public var movementThreshold: CGFloat
    public var onClick: @MainActor () -> Void
    public var onContextMenu: @MainActor (NSEvent) -> Void

    public init(
        movementThreshold: CGFloat = 4,
        onClick: @escaping @MainActor () -> Void,
        onContextMenu: @escaping @MainActor (NSEvent) -> Void
    ) {
        self.movementThreshold = movementThreshold
        self.onClick = onClick
        self.onContextMenu = onContextMenu
    }

    public func makeNSView(context: Context) -> DragRegionView {
        let view = DragRegionView()
        update(view)
        return view
    }

    public func updateNSView(_ nsView: DragRegionView, context: Context) {
        update(nsView)
    }

    private func update(_ view: DragRegionView) {
        view.movementThreshold = movementThreshold
        view.onClick = onClick
        view.onContextMenu = onContextMenu
    }
}

public final class DragRegionView: NSView {
    fileprivate var movementThreshold: CGFloat = 4
    fileprivate var onClick: @MainActor () -> Void = {}
    fileprivate var onContextMenu: @MainActor (NSEvent) -> Void = { _ in }

    private var initialEvent: NSEvent?
    private var initialLocation = NSPoint.zero
    private var beganWindowDrag = false

    public override var acceptsFirstResponder: Bool { false }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override func mouseDown(with event: NSEvent) {
        initialEvent = event
        initialLocation = event.locationInWindow
        beganWindowDrag = false
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !beganWindowDrag, let initialEvent else { return }
        let dx = event.locationInWindow.x - initialLocation.x
        let dy = event.locationInWindow.y - initialLocation.y
        guard hypot(dx, dy) >= movementThreshold else { return }
        beganWindowDrag = true
        window?.performDrag(with: initialEvent)
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            initialEvent = nil
            beganWindowDrag = false
        }
        guard !beganWindowDrag else { return }
        onClick()
    }

    public override func rightMouseDown(with event: NSEvent) {
        onContextMenu(event)
    }
}
