import MensoCore
import Observation
import SwiftUI

struct ActionsTabView: View {
    let model: AppModel
    let actions: [PendingActionSummary]
    let continuationRetries: [RunContinuationDeliveryUpdate]
    let decide: @MainActor (String, ActionPresentationDecision) -> Void
    let retryContinuation: @MainActor (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 9) {
                SemanticActionComposer(model: model)
                if actions.isEmpty && continuationRetries.isEmpty {
                    Text("No approvals are waiting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else {
                        ForEach(actions) { action in
                            PendingActionRow(action: action, decide: decide)
                        }
                        ForEach(continuationRetries, id: \.continuationID) { update in
                            ContinuationRetryRow(
                                update: update,
                                retry: retryContinuation
                            )
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

private struct SemanticActionComposer: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Desktop action", systemImage: "cursorarrow.motionlines")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Capture focused target") { model.captureSemanticTarget() }
                    .font(.caption2)
            }
            Picker("Action", selection: $model.semanticActionKind) {
                Text("Open app").tag(ApplicationSemanticActionKind.openApplication)
                Text("Focus window").tag(ApplicationSemanticActionKind.focusWindow)
                Text("Insert text").tag(ApplicationSemanticActionKind.insertText)
                Text("Set control").tag(ApplicationSemanticActionKind.activateControl)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            TextField("Bundle identifier", text: $model.semanticBundleIdentifier)
                .textFieldStyle(.roundedBorder)
            if model.semanticActionKind == .insertText {
                TextField("Exact text to insert", text: $model.semanticActionText, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            if model.semanticActionKind == .activateControl {
                TextField("Expected observed state", text: $model.semanticExpectedState)
                    .textFieldStyle(.roundedBorder)
            }
            if let target = model.capturedSemanticTarget {
                Text([
                    target.windowTitle,
                    target.elementRole,
                    target.elementLabel,
                ].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button(model.semanticActionIsRunning ? "Starting…" : "Review and run") {
                model.runSemanticAction()
            }
            .buttonStyle(ActionButtonStyle(tint: .cyan, prominent: true))
            .disabled(!model.isSemanticActionConfigured || model.semanticActionIsRunning)
            Button(model.semanticActionIsStagedForVoice ? "Staged for next voice action" : "Stage for voice") {
                model.stageSemanticActionForVoice()
            }
            .buttonStyle(ActionButtonStyle(tint: .mint, prominent: false))
            .disabled(!model.isLiveVoiceConfigured || model.semanticActionIsRunning)
            Text("The model sees only the typed Agno Toolkit action. Swift binds the exact target and value, asks for approval, and accepts only verified CUA evidence.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.cyan.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.cyan.opacity(0.18))
        }
    }
}

private struct ContinuationRetryRow: View {
    let update: RunContinuationDeliveryUpdate
    let retry: @MainActor (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AgentOS continuation needs retry")
                        .font(.system(size: 12, weight: .semibold))
                    Text("The local action is already terminal. Retry sends only its exact saved continuation envelope.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.yellow)
            }
            HStack(spacing: 5) {
                Text(update.endpointKind == .agent ? "Agent" : "Workflow")
                Text("·")
                Text("Attempt \(update.attemptCount)")
                Spacer()
                Text(update.occurredAt, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Button("Retry saved continuation") {
                retry(update.continuationID)
            }
            .buttonStyle(ActionButtonStyle(tint: .yellow, prominent: true))
        }
        .padding(10)
        .background(.yellow.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.yellow.opacity(0.2))
        }
    }
}

private struct PendingActionRow: View {
    let action: PendingActionSummary
    let decide: @MainActor (String, ActionPresentationDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(action.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 8)
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 5) {
                Text(action.sourceLabel)
                if let target = action.targetLabel {
                    Text("→")
                    Text(target)
                }
                Spacer()
                if let expiresAt = action.expiresAt {
                    Text("Expires \(expiresAt, style: .relative)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                Button("Deny") { decide(action.id, .deny) }
                    .buttonStyle(ActionButtonStyle(tint: .red, prominent: false))
                Button("Allow") { decide(action.id, .allowOnce) }
                    .buttonStyle(ActionButtonStyle(tint: .mint, prominent: true))
                if action.canCreateAlwaysRule {
                    Button("Always") { decide(action.id, .alwaysAllow) }
                        .buttonStyle(ActionButtonStyle(tint: .orange, prominent: false))
                        .help("Create a narrow rule after policy validation")
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.17))
        }
    }
}

private struct ActionButtonStyle: ButtonStyle {
    let tint: Color
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.black.opacity(0.8) : Color.primary)
            .background(
                tint.opacity(prominent ? (configuration.isPressed ? 0.62 : 0.85) : (configuration.isPressed ? 0.20 : 0.10)),
                in: RoundedRectangle(cornerRadius: 7)
            )
    }
}
