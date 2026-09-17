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
                        if let result = model.latestResult {
                            resultView(result)
                        }
                        ForEach(model.pendingActions) { action in
                            approvalView(action)
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
                .onChange(of: model.pendingActions.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.latestResult) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
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
            case .action:
                PrepareActionView(model: model)
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
            Text("Talk through a task. When it's time to act on your Mac, you stay in control.")
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
                Button("Approve") { model.decide(actionID: action.id, decision: .allowOnce) }
                    .buttonStyle(.borderedProminent)
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
                Text(result.status == .completed ? "Done" : result.status == .rejected ? "Couldn't complete" : "Waiting for approval")
                    .font(.callout.weight(.semibold))
                Text(result.spokenSummary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            if let app = model.stagedActionLabel {
                HStack(spacing: 8) {
                    Text("Prepared for \(app)").font(.callout)
                    Text("· next request").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.clearPreparedAction() }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 16) {
                Button {
                    model.presentedSheet = .action
                } label: {
                    Label("Prepare action", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!model.isLiveVoiceConfigured || model.isWorking)
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
            Text(model.isConversationActive ? "Microphone on · You can speak naturally and interrupt." : "Your microphone stays off until you start.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .background(MensoStyle.surface)
    }
}

private struct PrepareActionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Prepare a Mac action").font(.title2.weight(.semibold))
            Text("Choose exactly what Menso may do on your next voice request. You'll approve it before it runs.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.accessibilityGranted {
                Button("Allow Accessibility") { model.requestPermission(.accessibility) }
            }
            Picker("Action", selection: $model.semanticActionKind) {
                Text("Open an app").tag(ApplicationSemanticActionKind.openApplication)
                Text("Focus a window").tag(ApplicationSemanticActionKind.focusWindow)
                Text("Insert text").tag(ApplicationSemanticActionKind.insertText)
                Text("Set a control").tag(ApplicationSemanticActionKind.activateControl)
            }
            .pickerStyle(.menu)
            if model.semanticActionKind == .openApplication {
                HStack {
                    Text(model.semanticAppName.isEmpty ? "No app selected" : model.semanticAppName)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose app…") { model.chooseApplication() }
                }
            } else {
                Text("Menso will hide for three seconds. Focus the window or control you want to use.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(model.isCapturingTarget ? "Capturing…" : "Capture target") { model.captureSemanticTarget() }
                    .disabled(model.isCapturingTarget || !model.accessibilityGranted)
                if let target = model.capturedSemanticTarget {
                    Text([model.semanticAppName, target.windowTitle, target.elementLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if model.semanticActionKind == .insertText {
                TextField("Exact text to insert", text: $model.semanticActionText, axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder)
            }
            if model.semanticActionKind == .activateControl {
                TextField("Expected state after the action", text: $model.semanticExpectedState)
                    .textFieldStyle(.roundedBorder)
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use for next request") { model.stageSemanticActionForVoice() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.semanticBundleIdentifier.isEmpty || model.isCapturingTarget)
            }
            Text("Expires after five minutes. Preparing an action does not execute it.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 480)
        .tint(MensoStyle.accent)
    }
}
