import AppKit
import SwiftUI

@MainActor
public final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    public var containsInteractivePoint: (NSPoint, NSRect) -> Bool = { _, _ in true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsInteractivePoint(point, bounds) else { return nil }
        return super.hitTest(point)
    }
}

public enum WidgetGeometry {
    public static let approvalBubbleWidth: CGFloat = 220
    public static let approvalBubbleRowHeight: CGFloat = 72
    public static let approvalBubbleSpacing: CGFloat = 7
    public static let approvalBubbleGap: CGFloat = 8

    public static func robotRect(
        in bounds: CGRect,
        edge: DockEdge,
        dimension: CGFloat
    ) -> CGRect {
        switch edge {
        case .left:
            CGRect(x: bounds.minX, y: bounds.midY - dimension / 2, width: dimension, height: dimension)
        case .right:
            CGRect(x: bounds.maxX - dimension, y: bounds.midY - dimension / 2, width: dimension, height: dimension)
        case .top:
            CGRect(x: bounds.midX - dimension / 2, y: bounds.maxY - dimension, width: dimension, height: dimension)
        case .bottom:
            CGRect(x: bounds.midX - dimension / 2, y: bounds.minY, width: dimension, height: dimension)
        }
    }

    public static func robotStackRect(
        in bounds: CGRect,
        edge: DockEdge,
        dimension: CGFloat,
        faceCount: Int
    ) -> CGRect {
        let visibleCount = CGFloat(min(max(faceCount, 1), 4))
        let overlap = dimension * 0.22
        let stackHeight = dimension * visibleCount - overlap * max(0, visibleCount - 1)
        switch edge {
        case .left:
            return CGRect(x: bounds.minX, y: bounds.midY - stackHeight / 2, width: dimension, height: stackHeight)
        case .right:
            return CGRect(x: bounds.maxX - dimension, y: bounds.midY - stackHeight / 2, width: dimension, height: stackHeight)
        case .top:
            return CGRect(x: bounds.midX - dimension / 2, y: bounds.maxY - stackHeight, width: dimension, height: stackHeight)
        case .bottom:
            return CGRect(x: bounds.midX - dimension / 2, y: bounds.minY, width: dimension, height: stackHeight)
        }
    }

    public static func approvalBubbleStackRect(
        in bounds: CGRect,
        edge: DockEdge,
        dimension: CGFloat,
        faceCount: Int,
        bubbleCount: Int
    ) -> CGRect {
        guard bubbleCount > 0 else { return .null }
        let shown = CGFloat(min(bubbleCount, 3))
        let height = approvalBubbleRowHeight * shown
            + approvalBubbleSpacing * max(0, shown - 1)
        let robot = robotStackRect(
            in: bounds,
            edge: edge,
            dimension: dimension,
            faceCount: faceCount
        )

        switch edge {
        case .left:
            return CGRect(
                x: robot.maxX + approvalBubbleGap,
                y: bounds.midY - height / 2,
                width: approvalBubbleWidth,
                height: height
            )
        case .right:
            return CGRect(
                x: robot.minX - approvalBubbleGap - approvalBubbleWidth,
                y: bounds.midY - height / 2,
                width: approvalBubbleWidth,
                height: height
            )
        case .top:
            return CGRect(
                x: bounds.midX - approvalBubbleWidth / 2,
                y: robot.minY - approvalBubbleGap - height,
                width: approvalBubbleWidth,
                height: height
            )
        case .bottom:
            return CGRect(
                x: bounds.midX - approvalBubbleWidth / 2,
                y: robot.maxY + approvalBubbleGap,
                width: approvalBubbleWidth,
                height: height
            )
        }
    }

    public static func alignment(for edge: DockEdge) -> Alignment {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }
}
