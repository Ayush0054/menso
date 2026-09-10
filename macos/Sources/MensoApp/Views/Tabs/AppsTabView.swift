import AppKit
import MensoCore
import SwiftUI

struct AppsTabView: View {
    let monitor: AppMonitor

    var body: some View {
        VStack(spacing: 8) {
            summary
            if monitor.state.applications.isEmpty {
                ContentUnavailableView(
                    "No apps to show",
                    systemImage: "macwindow",
                    description: Text("App activity will appear here without an extra permission prompt.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(monitor.state.applications) { application in
                            ApplicationRow(application: application)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var summary: some View {
        HStack {
            Label("\(monitor.state.applications.count) apps", systemImage: "square.stack.3d.up")
            Spacer()
            if monitor.state.isSamplingPaused {
                Label("Paused", systemImage: "pause.fill")
            } else if let updatedAt = monitor.state.lastUpdatedAt {
                Text(updatedAt, style: .relative)
            } else {
                Text("Starting…")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
    }
}

private struct ApplicationRow: View {
    let application: ApplicationSnapshot

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(processIdentifier: application.processIdentifier)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(application.localizedName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if application.isActive {
                        Circle()
                            .fill(.green)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("Active")
                    }
                }
                Text(application.frontmostWindowTitle ?? application.kind.rawValue.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(cpuText)
                Text(memoryText)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.primary.opacity(application.isActive ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
    }

    private var cpuText: String {
        guard let cpu = application.cpuPercent else { return "CPU —" }
        return String(format: "CPU %.1f%%", cpu)
    }

    private var memoryText: String {
        guard let bytes = application.physicalFootprintBytes else { return "MEM —" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

private struct AppIcon: View {
    let processIdentifier: Int32

    var body: some View {
        Group {
            if let icon = NSRunningApplication(processIdentifier: processIdentifier)?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .padding(6)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}
