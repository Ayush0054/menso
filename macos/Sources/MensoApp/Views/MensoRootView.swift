import MensoCore
import SwiftUI

// One workspace for listening, approving, and seeing what happened.
// Native typography, a four-point spacing grid, neutral surfaces, and a single
// green accent keep the conversation and the user's decision in the foreground.
enum MensoStyle {
    static let accent = Color(red: 0.26, green: 0.48, blue: 0.39)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color.primary.opacity(0.035)
    static let separator = Color.primary.opacity(0.08)
}

struct MensoRootView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(MensoStyle.separator)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.captions.isEmpty {
                            welcome
                        } else {
                            ForEach(model.captions) { caption in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(caption.speaker == .user ? "YOU" : "MENSO")
                                        .font(.system(size: 10, weight: .semibold))
                                        .tracking(1.2)
                                        .foregroundStyle(.secondary)
                                    Text(caption.text)
                                        .font(.system(size: 16))
                                        .lineSpacing(5)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        // Pending approval is rendered only from the native
                        // coordinator below, never from a model result label.
                        if let result = model.latestResult, result.status != .requiresExternalAction {
                            resultView(result)
                        }
                        ForEach(model.exhaustedContinuations, id: \.continuationID) { retry in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your action result needs to be delivered.")
                                Button("Retry delivery") { model.retryContinuation(id: retry.continuationID) }
                                Text("This sends the saved result without running the action again.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 620)
                    .padding(32)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.captionRevision) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.latestResult) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if !model.pendingActions.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.pendingActions) { action in
                            approvalView(action)
                        }
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 280)
                .accessibilityIdentifier("pending-action-reviews")
            }
            if let message = model.message {
                HStack(alignment: .top, spacing: 12) {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss message")
                }
                .padding(.horizontal, 32).padding(.bottom, 16)
            }
            footer
        }
        .background(MensoStyle.canvas)
        .tint(MensoStyle.accent)
        .sheet(item: $model.presentedSheet) { sheet in
            switch sheet {
            case .connections:
                ConnectionsSettingsView(coordinator: model.provisioningCoordinator)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("menso").font(.system(size: 21, weight: .semibold, design: .rounded))
            Spacer()
            Circle()
                .fill(model.voiceState == .connected ? MensoStyle.accent : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(model.voiceStatus).font(.callout).foregroundStyle(.secondary)
            Button { model.presentedSheet = .connections } label: {
                Image(systemName: "gearshape").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
        }
        .padding(.horizontal, 28).padding(.vertical, 20)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 40)
            Image(systemName: "waveform")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(MensoStyle.accent)
                .accessibilityHidden(true)
            Text("A little help,\njust a conversation away.")
                .font(.system(size: 30, weight: .medium))
                .tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)
            Text("Say \"Open Brave\" or focus a text field and ask Menso to type. Review the action before it runs—no setup form.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .frame(maxWidth: 400, alignment: .leading)
            if !model.isLiveVoiceConfigured {
                Button("Set up connection") { model.presentedSheet = .connections }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
            }
            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func approvalView(_ action: PendingActionSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your approval", systemImage: "hand.raised")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(action.title).font(.title3.weight(.semibold))
            Text(action.detail).font(.body).textSelection(.enabled)
            if let target = action.targetLabel {
                Text(target).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("Only this action. Only this time.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Decline") { model.decide(actionID: action.id, decision: .deny) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("decline-\(action.id)")
                Button("Approve") { model.decide(actionID: action.id, decision: .allowOnce) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("approve-\(action.id)")
            }
            .disabled(model.resolvingActionIDs.contains(action.id))
        }
        .padding(24)
        .background(MensoStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MensoStyle.separator))
    }

    private func resultView(_ result: VoiceDelegationResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: result.status == .completed ? "checkmark.circle" : "info.circle")
                .foregroundStyle(result.status == .completed ? MensoStyle.accent : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.status == .completed ? "Done" : "Couldn't complete")
                    .font(.callout.weight(.semibold))
                Text(result.spokenSummary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                if model.accessibilityGranted {
                    Label("Mac control ready", systemImage: "checkmark.shield")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Enable Mac control", systemImage: "hand.raised") {
                        model.requestPermission(.accessibility)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.trustedRuntime == nil)
                }
                Spacer()
                if model.isConversationActive {
                    Button("End conversation", systemImage: "stop.fill") { model.endConversation() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(model.voiceState == .disconnecting)
                } else if model.isLiveVoiceConfigured && !model.microphoneGranted {
                    Button("Allow microphone", systemImage: "mic") { model.requestPermission(.microphone) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button("Talk to Menso", systemImage: "waveform") { model.toggleLiveVoice() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.isLiveVoiceConfigured || !model.microphoneGranted || model.isChangingVoice)
                }
            }
            Text(model.isConversationActive
                 ? "Microphone on · App names and focused-target details help resolve your requests."
                 : "Microphone off · Speak to request an action. Approve before it runs.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .background(MensoStyle.surface)
    }
}
