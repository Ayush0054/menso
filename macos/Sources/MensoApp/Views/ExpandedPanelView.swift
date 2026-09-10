import AppKit
import MensoCore
import SwiftUI

struct ExpandedPanelView: View {
    let model: AppModel
    let onContextMenu: @MainActor (NSEvent) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Group {
                switch model.presentation.selectedTab {
                case .apps:
                    AppsTabView(monitor: model.appMonitor)
                case .agents:
                    AgentsTabView(monitor: model.agentMonitor, todayUsage: model.todayUsage)
                case .actions:
                    ActionsTabView(
                        model: model,
                        actions: model.presentation.pendingActions,
                        continuationRetries: model.exhaustedContinuations,
                        decide: model.decide(actionID:decision:),
                        retryContinuation: model.retryContinuation(id:)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            RuntimeHealthRow(model: model)
            footer
        }
        .frame(width: 320, height: 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
        .overlay(alignment: .top) {
            if let message = model.presentation.nonfatalMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.red.opacity(0.88), in: Capsule())
                    .padding(.top, 54)
                    .onTapGesture { model.presentation.nonfatalMessage = nil }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                HStack(spacing: 10) {
                RobotSpriteView(
                    state: model.agentFaces.first?.state ?? .idle,
                    dimension: 42,
                    pendingCount: model.presentation.pendingActions.count
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Menso")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                }
                .allowsHitTesting(false)
                PanelDragSurface(onClick: {}, onContextMenu: onContextMenu)
            }
            .contentShape(Rectangle())
            Button {
                model.presentation.isExpanded = false
            } label: {
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(.primary.opacity(0.07), in: Circle())
            .help("Collapse Menso")
            .accessibilityLabel("Collapse Menso")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: 62)
    }

    private var tabPicker: some View {
        Picker(
            "Section",
            selection: Binding(
                get: { model.presentation.selectedTab },
                set: { model.presentation.selectedTab = $0 }
            )
        ) {
            ForEach(ExpandedTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.toggleDictation()
            } label: {
                Label("Dictate", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FooterButtonStyle(tint: .mint))
            .disabled(!model.isDictationConfigured)
            .help(model.isDictationConfigured
                ? "Dictate into the focused app (Control-Option-Space)"
                : "Dictation requires authenticated speech and insertion adapters")
            Button {
                model.toggleLiveVoice()
            } label: {
                Label("Talk", systemImage: "waveform.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FooterButtonStyle(tint: .cyan))
            .disabled(!model.isLiveVoiceConfigured)
            .help(model.isLiveVoiceConfigured
                ? "Start or stop live voice"
                : "Live voice requires authenticated audio and Realtime adapters")
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(12)
        .overlay(alignment: .top) { Divider() }
    }

    private var statusText: String {
        if !model.presentation.pendingActions.isEmpty {
            return "\(model.presentation.pendingActions.count) action\(model.presentation.pendingActions.count == 1 ? "" : "s") waiting"
        }
        if let session = model.agentMonitor.state.sessions.first,
           session.isProcessRunning || session.lastActivityAt > Date.now.addingTimeInterval(-90) {
            return "Watching \(session.provider.displayName)"
        }
        return "Keeping an eye on things"
    }
}

private struct FooterButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 8)
            .foregroundStyle(.primary)
            .background(tint.opacity(configuration.isPressed ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(tint.opacity(0.25))
            }
    }
}
