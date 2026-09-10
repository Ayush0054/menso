import Foundation

public protocol UsageEventPersisting: Sendable {
    @discardableResult
    func insertUsageEvents(_ events: [AgentUsageEvent]) async throws -> Int
    func recentUsageEvents(since: Date, limit: Int) async throws -> [AgentUsageEvent]
}

public protocol FileCursorPersisting: Sendable {
    func cursor(forPath path: String) async throws -> FileTailCursor?
    func saveCursor(_ cursor: FileTailCursor) async throws
}

public protocol AgentRateLimitPersisting: Sendable {
    func saveRateLimits(_ limits: [AgentRateLimit]) async throws
    func currentRateLimits() async throws -> [AgentRateLimit]
}

public protocol WindowPositionPersisting: Sendable {
    func position(forDisplayID displayID: String) async throws -> DockedWindowPosition?
    func savePosition(_ position: DockedWindowPosition) async throws
    func deletePositions() async throws
}

public protocol SettingsPersisting: Sendable {
    func data(forKey key: String) async throws -> Data?
    func saveData(_ data: Data, forKey key: String) async throws
}

public typealias LocalTelemetryPersisting = UsageEventPersisting & FileCursorPersisting

public actor VolatilePersistence:
    UsageEventPersisting,
    FileCursorPersisting,
    AgentRateLimitPersisting,
    WindowPositionPersisting,
    SettingsPersisting
{
    private var usageEvents: [String: AgentUsageEvent] = [:]
    private var cursors: [String: FileTailCursor] = [:]
    private var rateLimits: [String: AgentRateLimit] = [:]
    private var positions: [String: DockedWindowPosition] = [:]
    private var settings: [String: Data] = [:]

    public init() {}

    public func insertUsageEvents(_ events: [AgentUsageEvent]) -> Int {
        var inserted = 0
        for event in events where usageEvents[event.id] == nil {
            usageEvents[event.id] = event
            inserted += 1
        }
        return inserted
    }

    public func recentUsageEvents(since: Date, limit: Int) -> [AgentUsageEvent] {
        Array(
            usageEvents.values
                .filter { $0.occurredAt >= since }
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(max(0, limit))
        )
    }

    public func cursor(forPath path: String) -> FileTailCursor? {
        cursors[path]
    }

    public func saveCursor(_ cursor: FileTailCursor) {
        cursors[cursor.path] = cursor
    }

    public func saveRateLimits(_ limits: [AgentRateLimit]) {
        for limit in limits {
            if rateLimits[limit.id].map({ $0.observedAt <= limit.observedAt }) ?? true {
                rateLimits[limit.id] = limit
            }
        }
    }

    public func currentRateLimits() -> [AgentRateLimit] {
        Array(rateLimits.values)
    }

    public func position(forDisplayID displayID: String) -> DockedWindowPosition? {
        positions[displayID]
    }

    public func savePosition(_ position: DockedWindowPosition) {
        positions[position.displayID] = position
    }

    public func deletePositions() {
        positions.removeAll()
    }

    public func data(forKey key: String) -> Data? {
        settings[key]
    }

    public func saveData(_ data: Data, forKey key: String) {
        settings[key] = data
    }

}
