@preconcurrency import AppKit
import Darwin
import Foundation
import Observation

public actor AgentTelemetryIngestor {
    private let usageStore: any UsageEventPersisting
    private let cursorStore: any FileCursorPersisting
    private let rateLimitStore: any AgentRateLimitPersisting
    private let locator: TelemetryFileLocator
    private let tailer: IncrementalJSONLTailer
    private let parsers: [AgentProvider: any AgentTelemetryParsing]
    private var latestRateLimits: [String: AgentRateLimit] = [:]
    private var loadedPersistedRateLimits = false
    private var lastDiscoveredPaths: [String] = []

    public init(
        usageStore: any UsageEventPersisting,
        cursorStore: any FileCursorPersisting,
        rateLimitStore: any AgentRateLimitPersisting,
        locator: TelemetryFileLocator = TelemetryFileLocator(),
        tailer: IncrementalJSONLTailer = IncrementalJSONLTailer()
    ) {
        self.usageStore = usageStore
        self.cursorStore = cursorStore
        self.rateLimitStore = rateLimitStore
        self.locator = locator
        self.tailer = tailer
        parsers = [
            .claudeCode: ClaudeCodeTelemetryParser(),
            .codex: CodexTelemetryParser(),
        ]
    }

    public func poll() async -> AgentMonitorState {
        var diagnostics: [TelemetryParseDiagnostic] = []
        if !loadedPersistedRateLimits {
            do {
                for limit in try await rateLimitStore.currentRateLimits() {
                    latestRateLimits[limit.id] = limit
                }
                loadedPersistedRateLimits = true
            } catch {
                diagnostics.append(
                    .init(
                        kind: .unsupportedRecord,
                        sourcePath: "local-database",
                        message: "Saved quota observations are temporarily unavailable: \(error.localizedDescription)"
                    )
                )
            }
        }
        let files = locator.discover()
        lastDiscoveredPaths = files.map(\.path)

        for source in files {
            guard let parser = parsers[source.provider] else { continue }
            do {
                let cursor = try await cursorStore.cursor(forPath: source.path)
                let batch = try tailer.read(path: source.path, cursor: cursor)
                if batch.skippedOversizedFragment {
                    diagnostics.append(
                        .init(
                            kind: .oversizedLine,
                            sourcePath: source.path,
                            message: "Skipped a bounded oversized JSONL fragment"
                        )
                    )
                }

                var events: [AgentUsageEvent] = []
                var observedRateLimits: [AgentRateLimit] = []
                for line in batch.lines {
                    let parsed = parser.parse(line: line, sourcePath: source.path)
                    events.append(contentsOf: parsed.usageEvents)
                    diagnostics.append(contentsOf: parsed.diagnostics)
                    for rateLimit in parsed.rateLimits {
                        observedRateLimits.append(rateLimit)
                        let key = rateLimit.id
                        if latestRateLimits[key].map({ $0.observedAt < rateLimit.observedAt }) ?? true {
                            latestRateLimits[key] = rateLimit
                        }
                    }
                }

                // Cursor advancement follows successful durable insertion. A
                // crash before cursor save replays safely through event IDs.
                _ = try await usageStore.insertUsageEvents(events)
                try await rateLimitStore.saveRateLimits(observedRateLimits)
                try await cursorStore.saveCursor(batch.nextCursor)
            } catch {
                diagnostics.append(
                    .init(
                        kind: .unsupportedRecord,
                        sourcePath: source.path,
                        message: "Telemetry read deferred: \(error.localizedDescription)"
                    )
                )
            }
        }

        let recentEvents: [AgentUsageEvent]
        do {
            recentEvents = try await usageStore.recentUsageEvents(
                since: Date.now.addingTimeInterval(-7 * 24 * 60 * 60),
                limit: 10_000
            )
        } catch {
            recentEvents = []
            diagnostics.append(
                .init(
                    kind: .unsupportedRecord,
                    sourcePath: "local-database",
                    message: "Recent usage is temporarily unavailable: \(error.localizedDescription)"
                )
            )
        }

        let runningProviders = AgentProcessDetector.runningProviders()
        var limits = Array(latestRateLimits.values)
        if let claudeEstimate = ClaudeQuotaEstimator.estimate(from: recentEvents) {
            limits.append(claudeEstimate)
        }

        return AgentMonitorState(
            sessions: Self.sessionSummaries(from: recentEvents, runningProviders: runningProviders),
            rateLimits: limits.sorted {
                if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
                return $0.window.rawValue < $1.window.rawValue
            },
            recentEvents: recentEvents,
            diagnostics: Array(diagnostics.suffix(50)),
            runningProviders: runningProviders,
            lastUpdatedAt: .now
        )
    }

    public func discoveredPaths() -> [String] {
        lastDiscoveredPaths
    }

    private static func sessionSummaries(
        from events: [AgentUsageEvent],
        runningProviders: Set<AgentProvider>
    ) -> [AgentSessionSummary] {
        let grouped = Dictionary(grouping: events) { "\($0.provider.rawValue):\($0.sessionID)" }
        var summaries: [AgentSessionSummary] = grouped.values.compactMap { sessionEvents -> AgentSessionSummary? in
            guard let latest = sessionEvents.max(by: { $0.occurredAt < $1.occurredAt }) else {
                return nil
            }
            let usage = sessionEvents.reduce(TokenUsage()) { $0 + $1.usage }
            return AgentSessionSummary(
                provider: latest.provider,
                sessionID: latest.sessionID,
                model: latest.model,
                usage: usage,
                lastActivityAt: latest.occurredAt,
                isProcessRunning: runningProviders.contains(latest.provider)
            )
        }
        let representedProviders = Set(summaries.map(\.provider))
        for provider in runningProviders.subtracting(representedProviders) where provider != .unknown {
            summaries.append(
                AgentSessionSummary(
                    provider: provider,
                    sessionID: "process-liveness",
                    model: nil,
                    usage: TokenUsage(),
                    lastActivityAt: .now,
                    isProcessRunning: true
                )
            )
        }
        return summaries.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}

@MainActor
@Observable
public final class AgentTelemetryMonitor {
    public private(set) var state = AgentMonitorState()

    private let ingestor: AgentTelemetryIngestor
    private let fileLocator: TelemetryFileLocator
    private var timer: DispatchSourceTimer?
    private var pollTask: Task<Void, Never>?
    private var fileSystemWatcher: TelemetryFileSystemWatcher?
    private var fileActivityWatcher: TelemetryFileActivityWatcher?
    private var panelIsExpanded = false
    private var started = false

    public init(
        ingestor: AgentTelemetryIngestor,
        fileLocator: TelemetryFileLocator = TelemetryFileLocator()
    ) {
        self.ingestor = ingestor
        self.fileLocator = fileLocator
    }

    isolated deinit {
        timer?.cancel()
        pollTask?.cancel()
    }

    public func start() {
        guard !started else { return }
        started = true
        let watcher = TelemetryFileSystemWatcher(
            roots: fileLocator.watchRoots()
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedulePoll()
            }
        }
        if watcher.start() {
            fileSystemWatcher = watcher
        }
        fileActivityWatcher = TelemetryFileActivityWatcher { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedulePoll()
            }
        }
        configureTimer()
        schedulePoll()
    }

    public func stop() {
        started = false
        timer?.cancel()
        timer = nil
        pollTask?.cancel()
        pollTask = nil
        fileSystemWatcher?.stop()
        fileSystemWatcher = nil
        fileActivityWatcher?.stop()
        fileActivityWatcher = nil
    }

    public func setPanelExpanded(_ isExpanded: Bool) {
        guard panelIsExpanded != isExpanded else { return }
        panelIsExpanded = isExpanded
        configureTimer()
    }

    public func refreshNow() {
        schedulePoll()
    }

    private func configureTimer() {
        timer?.cancel()
        // The event handler is created in this @MainActor type, so dispatch it
        // on the main queue. Polling itself remains asynchronous below.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .seconds(1),
            repeating: panelIsExpanded ? .seconds(2) : .seconds(6),
            leeway: panelIsExpanded ? .milliseconds(300) : .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedulePoll()
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func schedulePoll() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self, ingestor] in
            let nextState = await ingestor.poll()
            let discoveredPaths = await ingestor.discoveredPaths()
            guard !Task.isCancelled else { return }
            self?.state = nextState
            self?.fileActivityWatcher?.update(paths: discoveredPaths)
            self?.pollTask = nil
        }
    }
}

private enum AgentProcessDetector {
    private static let maximumProcessPathSize = 4_096

    static func runningProviders() -> Set<AgentProvider> {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var processIdentifiers = [Int32](repeating: 0, count: capacity)
        let count = processIdentifiers.withUnsafeMutableBytes { buffer in
            Int(proc_listallpids(buffer.baseAddress, Int32(buffer.count)))
        }

        var providers = Set<AgentProvider>()
        for processIdentifier in processIdentifiers.prefix(max(0, count)) where processIdentifier > 0 {
            var pathBuffer = [CChar](repeating: 0, count: maximumProcessPathSize)
            let length = proc_pidpath(
                processIdentifier,
                &pathBuffer,
                UInt32(pathBuffer.count)
            )
            guard length > 0 else { continue }
            let pathBytes = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let executablePath = String(decoding: pathBytes, as: UTF8.self)
            let basename = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
            switch basename {
            case "claude":
                providers.insert(.claudeCode)
            case "codex":
                providers.insert(.codex)
            case "cursor":
                providers.insert(.cursor)
            case "windsurf":
                providers.insert(.windsurf)
            default:
                break
            }
        }
        return providers
    }
}

private enum ClaudeQuotaEstimator {
    private struct Block {
        let start: Date
        var usage: Int64
    }

    static func estimate(from events: [AgentUsageEvent]) -> AgentRateLimit? {
        let claudeEvents = events
            .filter { $0.provider == .claudeCode }
            .sorted { $0.occurredAt < $1.occurredAt }
        guard !claudeEvents.isEmpty else { return nil }

        var blocks: [Block] = []
        for event in claudeEvents {
            if let index = blocks.indices.last,
               event.occurredAt < blocks[index].start.addingTimeInterval(5 * 60 * 60) {
                blocks[index].usage += event.usage.total
            } else {
                blocks.append(Block(start: event.occurredAt, usage: event.usage.total))
            }
        }
        guard let current = blocks.last else { return nil }
        let completedPeak = blocks.dropLast().map(\.usage).max()
        guard let completedPeak, completedPeak > 0 else { return nil }

        return AgentRateLimit(
            provider: .claudeCode,
            window: .fiveHour,
            usedPercent: Double(current.usage) / Double(completedPeak) * 100,
            resetsAt: current.start.addingTimeInterval(5 * 60 * 60),
            isEstimate: true,
            observedAt: claudeEvents.last?.occurredAt ?? .now
        )
    }
}
