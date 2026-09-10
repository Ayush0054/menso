import AppKit
import Foundation

public struct PanelSnapCoordinator: Sendable {
    public let peekInsetFraction: CGFloat

    public init(peekInsetFraction: CGFloat = 0.5) {
        self.peekInsetFraction = peekInsetFraction
    }

    public func capture(
        frame: NSRect,
        screen: NSScreen,
        spriteDimension: CGFloat
    ) -> DockedWindowPosition {
        let visible = screen.visibleFrame
        let distances: [(DockEdge, CGFloat)] = [
            (.left, abs(frame.minX - visible.minX)),
            (.right, abs(frame.maxX - visible.maxX)),
            (.top, abs(frame.maxY - visible.maxY)),
            (.bottom, abs(frame.minY - visible.minY)),
        ]
        let edge = distances.min(by: { $0.1 < $1.1 })?.0 ?? .right

        let fraction: CGFloat
        let isPeeking: Bool
        switch edge {
        case .left:
            fraction = verticalFraction(frame: frame, visibleFrame: visible)
            isPeeking = frame.minX < visible.minX - spriteDimension * 0.15
        case .right:
            fraction = verticalFraction(frame: frame, visibleFrame: visible)
            isPeeking = frame.maxX > visible.maxX + spriteDimension * 0.15
        case .top:
            fraction = horizontalFraction(frame: frame, visibleFrame: visible)
            isPeeking = frame.maxY > visible.maxY + spriteDimension * 0.15
        case .bottom:
            fraction = horizontalFraction(frame: frame, visibleFrame: visible)
            isPeeking = frame.minY < visible.minY - spriteDimension * 0.15
        }

        return DockedWindowPosition(
            displayID: screen.mensoDisplayID,
            edge: edge,
            fractionalOffset: Double(fraction),
            isPeeking: isPeeking
        )
    }

    public func frame(
        for position: DockedWindowPosition,
        on screen: NSScreen,
        panelSize: NSSize,
        spriteDimension: CGFloat,
        isExpanded: Bool
    ) -> NSRect {
        let visible = screen.visibleFrame
        let fraction = CGFloat(min(max(position.fractionalOffset, 0), 1))
        let peek = position.isPeeking && !isExpanded
            ? spriteDimension * peekInsetFraction
            : 0
        var origin = NSPoint.zero

        switch position.edge {
        case .left:
            origin.x = visible.minX - peek
            origin.y = visible.minY + max(0, visible.height - panelSize.height) * fraction
        case .right:
            origin.x = visible.maxX - panelSize.width + peek
            origin.y = visible.minY + max(0, visible.height - panelSize.height) * fraction
        case .top:
            origin.x = visible.minX + max(0, visible.width - panelSize.width) * fraction
            origin.y = visible.maxY - panelSize.height + peek
        case .bottom:
            origin.x = visible.minX + max(0, visible.width - panelSize.width) * fraction
            origin.y = visible.minY - peek
        }
        return NSRect(origin: origin, size: panelSize)
    }

    public func screen(for displayID: String) -> NSScreen? {
        NSScreen.screens.first { $0.mensoDisplayID == displayID }
    }

    public func nearestScreen(to frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { first, second in
            first.frame.intersection(frame).area < second.frame.intersection(frame).area
        } ?? NSScreen.main
    }

    private func verticalFraction(frame: NSRect, visibleFrame: NSRect) -> CGFloat {
        let available = max(visibleFrame.height - frame.height, 1)
        return min(max((frame.minY - visibleFrame.minY) / available, 0), 1)
    }

    private func horizontalFraction(frame: NSRect, visibleFrame: NSRect) -> CGFloat {
        let available = max(visibleFrame.width - frame.width, 1)
        return min(max((frame.minX - visibleFrame.minX) / available, 0), 1)
    }
}

public extension NSScreen {
    var mensoDisplayID: String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = deviceDescription[key] as? NSNumber {
            return number.stringValue
        }
        return localizedName
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
