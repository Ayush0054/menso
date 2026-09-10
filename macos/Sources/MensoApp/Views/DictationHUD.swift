import AppKit
import MensoCore
import Observation
import SwiftUI

@MainActor
@Observable
final class DictationHUDModel {
    var state: DictationRuntimeState = .idle

    var isPresented: Bool {
        switch state {
        case .idle:
            false
        default:
            true
        }
    }

    var displayText: String {
        switch state {
        case .idle:
            ""
        case .preparing:
            "Preparing local dictation…"
        case let .recording(partialText):
            partialText.isEmpty ? "Listening…" : partialText
        case let .finalizing(partialText):
            partialText.isEmpty ? "Finishing…" : partialText
        case let .executing(text):
            text
        case .awaitingHumanReview:
            "Approval required before inserting text"
        case let .delegating(text):
            text
        case let .completed(summary):
            summary
        case let .failed(failure):
            failure.userMessage
        }
    }

    var statusLabel: String {
        switch state {
        case .idle: "Dictation"
        case .preparing: "Loading local model"
        case .recording: "Dictating"
        case .finalizing: "Transcribing"
        case .executing: "Inserting"
        case .awaitingHumanReview: "Waiting"
        case .delegating: "Running command"
        case .completed: "Done"
        case .failed: "Couldn't dictate"
        }
    }

    var isWaveformActive: Bool {
        switch state {
        case .preparing, .recording, .finalizing:
            true
        default:
            false
        }
    }

    var statusColor: Color {
        switch state {
        case .failed: .red
        case .completed: .green
        case .awaitingHumanReview: .orange
        default: .cyan
        }
    }
}

struct DictationHUDView: View {
    let model: DictationHUDModel

    var body: some View {
        HStack(spacing: 12) {
            DictationWaveform(
                isActive: model.isWaveformActive,
                color: model.statusColor
            )
            .frame(width: 44, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusLabel.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(model.statusColor)
                Text(model.displayText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.isWaveformActive {
                Text("HOTKEY TO STOP")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 420)
        .frame(minHeight: 64)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
        .padding(18)
    }
}

private struct DictationWaveform: View {
    let isActive: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<7, id: \.self) { index in
                    let wave = abs(sin(time * 8 + Double(index) * 0.72))
                    Capsule()
                        .fill(color.opacity(isActive ? 0.88 : 0.45))
                        .frame(
                            width: 3,
                            height: isActive ? 7 + wave * 21 : 7
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

@MainActor
final class DictationHUDController {
    private let runtime: any DictationRuntimeControlling
    private let model: DictationHUDModel
    private let panel: DictationHUDPanel
    private var updatesTask: Task<Void, Never>?
    private var delayedHideTask: Task<Void, Never>?
    private var dismissGeneration: UInt64 = 0

    init(runtime: any DictationRuntimeControlling) {
        self.runtime = runtime
        model = DictationHUDModel()
        panel = DictationHUDPanel()
        panel.contentView = NSHostingView(rootView: DictationHUDView(model: model))
    }

    deinit {
        updatesTask?.cancel()
        delayedHideTask?.cancel()
    }

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self, runtime] in
            let updates = await runtime.stateUpdates()
            for await state in updates {
                guard !Task.isCancelled else { return }
                self?.apply(state)
            }
        }
    }

    func stop() {
        dismissGeneration &+= 1
        updatesTask?.cancel()
        updatesTask = nil
        delayedHideTask?.cancel()
        delayedHideTask = nil
        panel.orderOut(nil)
    }

    private func apply(_ state: DictationRuntimeState) {
        dismissGeneration &+= 1
        let generation = dismissGeneration
        delayedHideTask?.cancel()
        delayedHideTask = nil
        model.state = state

        guard model.isPresented else {
            panel.orderOut(nil)
            return
        }
        positionOnActiveScreen()
        panel.orderFrontRegardless()

        let delay: Duration?
        switch state {
        case .completed:
            delay = .milliseconds(1_100)
        case .failed:
            delay = .seconds(4)
        default:
            delay = nil
        }
        if let delay {
            delayedHideTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                guard let self, self.dismissGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = panel.frame
        let visible = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.minY + 26
            )
        )
    }
}

private final class DictationHUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 456, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        animationBehavior = .none
        isMovable = false
        isMovableByWindowBackground = false
        isExcludedFromWindowsMenu = true
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
