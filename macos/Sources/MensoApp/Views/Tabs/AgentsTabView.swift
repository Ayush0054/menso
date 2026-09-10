import MensoCore
import SwiftUI

struct AgentsTabView: View {
    let monitor: AgentTelemetryMonitor
    let todayUsage: TokenUsage

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 9) {
                usageCard
                if monitor.state.rateLimits.isEmpty {
                    quotaUnavailableCard
                } else {
                    ForEach(monitor.state.rateLimits) { limit in
                        RateLimitRow(limit: limit)
                    }
                }
                if monitor.state.sessions.isEmpty {
                    ContentUnavailableView(
                        "No local agent usage yet",
                        systemImage: "terminal",
                        description: Text("Menso reads new Claude Code and Codex JSONL records incrementally.")
                    )
                    .frame(minHeight: 150)
                } else {
                    ForEach(monitor.state.sessions.prefix(12)) { session in
                        AgentSessionRow(session: session)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TODAY")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(todayUsage.total.formatted())
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("tokens observed locally")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                UsageSparkline(values: sparklineValues)
                    .frame(width: 112, height: 42)
            }
        }
        .padding(11)
        .background(.mint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.mint.opacity(0.18))
        }
    }

    private var quotaUnavailableCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.0percent")
            Text("Quota appears when Codex emits local rate limits or a Claude local-history baseline exists.")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sparklineValues: [Double] {
        let calendar = Calendar.current
        let now = Date.now
        return (0..<12).map { index in
            let end = now.addingTimeInterval(TimeInterval(index - 11) * 2 * 60 * 60)
            let start = end.addingTimeInterval(-2 * 60 * 60)
            return Double(monitor.state.recentEvents
                .filter { $0.occurredAt >= start && $0.occurredAt < end && calendar.isDate($0.occurredAt, inSameDayAs: now) }
                .reduce(0) { $0 + $1.usage.total })
        }
    }
}

private struct RateLimitRow: View {
    let limit: AgentRateLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(limit.provider.displayName) · \(windowTitle)")
                    .font(.system(size: 11, weight: .semibold))
                if limit.isEstimate {
                    Text("LOCAL ESTIMATE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("\(Int(limit.usedPercent.rounded()))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            ProgressView(value: limit.usedPercent, total: 100)
                .tint(limit.usedPercent >= 90 ? .red : limit.usedPercent >= 70 ? .orange : .mint)
            if let resetsAt = limit.resetsAt {
                Text("Resets \(resetsAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private var windowTitle: String {
        switch limit.window {
        case .fiveHour: "5 hour"
        case .weekly: "Weekly"
        case .unknown: "Quota"
        }
    }
}

private struct AgentSessionRow: View {
    let session: AgentSessionSummary

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: session.provider == .claudeCode ? "sparkles" : "chevron.left.forwardslash.chevron.right")
                .frame(width: 25, height: 25)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.provider.displayName)
                        .font(.system(size: 11, weight: .semibold))
                    if session.isProcessRunning {
                        Circle().fill(.green).frame(width: 5, height: 5)
                    }
                }
                Text(session.model ?? shortSessionID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.usage.total.formatted())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Text(session.lastActivityAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var shortSessionID: String {
        String(session.sessionID.prefix(14))
    }
}

private struct UsageSparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let maximum = values.max(), maximum > 0 else {
                return
            }
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let y = size.height - size.height * CGFloat(value / maximum)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.mint), lineWidth: 2)
        }
        .accessibilityHidden(true)
    }
}
