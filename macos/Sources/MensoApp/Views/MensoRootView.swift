import AppKit
import MensoCore
import SwiftUI

struct MensoRootView: View {
    let model: AppModel
    let onContextMenu: @MainActor (NSEvent) -> Void

    private var edge: DockEdge {
        model.presentation.currentPosition?.edge ?? .right
    }

    var body: some View {
        ZStack(alignment: WidgetGeometry.alignment(for: edge)) {
            if model.presentation.isExpanded {
                ExpandedPanelView(model: model, onContextMenu: onContextMenu)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                CollapsedWidgetView(
                    faces: model.agentFaces,
                    dimension: model.presentation.preferences.size.dimension,
                    actions: model.presentation.pendingActions,
                    edge: edge,
                    onClick: { model.presentation.isExpanded = true },
                    onContextMenu: onContextMenu,
                    decide: model.decide(actionID:decision:)
                )
                .opacity(model.collapsedOpacity)
                .transition(.scale(scale: 0.84).combined(with: .opacity))
            }
        }
        .frame(
            width: MensoPanel.expandedSize.width,
            height: MensoPanel.expandedSize.height,
            alignment: WidgetGeometry.alignment(for: edge)
        )
        .animation(.spring(duration: 0.34, bounce: 0.18), value: model.presentation.isExpanded)
        .animation(.easeOut(duration: 0.3), value: model.collapsedOpacity)
        .sheet(item: Binding(
            get: { model.presentedSheet },
            set: { model.presentedSheet = $0 }
        )) { sheet in
            switch sheet {
            case .connections:
                ConnectionsSettingsView(coordinator: model.provisioningCoordinator)
            case .learnings:
                LearningManagementView(manager: model.trustedRuntime?.learningManager)
            }
        }
    }
}

private struct CollapsedWidgetView: View {
    let faces: [AgentFace]
    let dimension: CGFloat
    let actions: [PendingActionSummary]
    let edge: DockEdge
    let onClick: @MainActor () -> Void
    let onContextMenu: @MainActor (NSEvent) -> Void
    let decide: @MainActor (String, ActionPresentationDecision) -> Void

    var body: some View {
        ZStack(alignment: WidgetGeometry.alignment(for: edge)) {
            RobotStackView(
                faces: faces,
                dimension: dimension,
                pendingCount: actions.count,
                onClick: onClick,
                onContextMenu: onContextMenu
            )
            if !actions.isEmpty {
                ApprovalBubbleStackView(actions: actions, decide: decide)
                    .frame(
                        width: WidgetGeometry.approvalBubbleWidth,
                        height: bubbleHeight
                    )
                    .modifier(ApprovalBubblePlacement(edge: edge, robotDimension: dimension))
                    .transition(.move(edge: transitionEdge).combined(with: .opacity))
            }
        }
        .frame(
            width: MensoPanel.expandedSize.width,
            height: MensoPanel.expandedSize.height,
            alignment: WidgetGeometry.alignment(for: edge)
        )
        .animation(.spring(duration: 0.3, bounce: 0.16), value: actions.map(\.id))
    }

    private var bubbleHeight: CGFloat {
        let count = CGFloat(min(actions.count, 3))
        return WidgetGeometry.approvalBubbleRowHeight * count
            + WidgetGeometry.approvalBubbleSpacing * max(0, count - 1)
    }

    private var transitionEdge: Edge {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }
}

private struct ApprovalBubblePlacement: ViewModifier {
    let edge: DockEdge
    let robotDimension: CGFloat

    func body(content: Content) -> some View {
        switch edge {
        case .left:
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .offset(x: robotDimension + WidgetGeometry.approvalBubbleGap)
        case .right:
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(x: -(robotDimension + WidgetGeometry.approvalBubbleGap))
        case .top:
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .offset(y: robotDimension + WidgetGeometry.approvalBubbleGap)
        case .bottom:
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .offset(y: -(robotDimension + WidgetGeometry.approvalBubbleGap))
        }
    }
}
