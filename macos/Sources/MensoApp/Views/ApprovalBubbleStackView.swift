import MensoCore
import SwiftUI

struct ApprovalBubbleStackView: View {
    let actions: [PendingActionSummary]
    let decide: @MainActor (String, ActionPresentationDecision) -> Void

    var body: some View {
        VStack(spacing: WidgetGeometry.approvalBubbleSpacing) {
            ForEach(actions.prefix(3)) { action in
                ApprovalBubble(action: action, decide: decide)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if actions.count > 3 {
                Text("+\(actions.count - 3)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.78), in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: -5, y: -5)
            }
        }
    }
}

private struct ApprovalBubble: View {
    let action: PendingActionSummary
    let decide: @MainActor (String, ActionPresentationDecision) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
                .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(action.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 1)
            Button {
                decide(action.id, .deny)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(BubbleDecisionButtonStyle(tint: .red))
            .help("Deny")
            Button {
                decide(action.id, .allowOnce)
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(BubbleDecisionButtonStyle(tint: .mint))
            .help("Allow once")
        }
        .padding(.horizontal, 9)
        .frame(height: WidgetGeometry.approvalBubbleRowHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.orange.opacity(0.24))
        }
        .shadow(color: .black.opacity(0.18), radius: 9, y: 4)
        .accessibilityElement(children: .contain)
    }
}

private struct BubbleDecisionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .black))
            .frame(width: 24, height: 24)
            .foregroundStyle(.primary)
            .background(
                tint.opacity(configuration.isPressed ? 0.30 : 0.15),
                in: RoundedRectangle(cornerRadius: 7)
            )
    }
}
