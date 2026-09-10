import Foundation
import GRDB

public actor SQLiteUsageEventStore: UsageEventPersisting {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func insertUsageEvents(_ events: [AgentUsageEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }
        return try pool.write { database in
            var inserted = 0
            for event in events {
                try database.execute(
                    sql: """
                    INSERT OR IGNORE INTO usage_events (
                        id, provider, session_id, occurred_at, model, request_id,
                        input_tokens, output_tokens, cache_read_tokens,
                        cache_write_tokens, reasoning_tokens, uncategorized_tokens,
                        source_path
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        event.id,
                        event.provider.rawValue,
                        event.sessionID,
                        event.occurredAt,
                        event.model,
                        event.requestID,
                        event.usage.input,
                        event.usage.output,
                        event.usage.cacheRead,
                        event.usage.cacheWrite,
                        event.usage.reasoning,
                        event.usage.uncategorized,
                        event.sourcePath,
                    ]
                )
                inserted += database.changesCount
            }
            return inserted
        }
    }

    public func recentUsageEvents(since: Date, limit: Int) throws -> [AgentUsageEvent] {
        try pool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT * FROM usage_events
                WHERE occurred_at >= ?
                ORDER BY occurred_at DESC
                LIMIT ?
                """,
                arguments: [since, max(0, limit)]
            )
            return rows.compactMap(Self.usageEvent(from:))
        }
    }

    private static func usageEvent(from row: Row) -> AgentUsageEvent? {
        guard
            let provider = AgentProvider(rawValue: row["provider"]),
            let id: String = row["id"],
            let sessionID: String = row["session_id"],
            let occurredAt: Date = row["occurred_at"],
            let sourcePath: String = row["source_path"]
        else { return nil }

        return AgentUsageEvent(
            id: id,
            provider: provider,
            sessionID: sessionID,
            occurredAt: occurredAt,
            model: row["model"],
            requestID: row["request_id"],
            usage: TokenUsage(
                input: row["input_tokens"],
                output: row["output_tokens"],
                cacheRead: row["cache_read_tokens"],
                cacheWrite: row["cache_write_tokens"],
                reasoning: row["reasoning_tokens"],
                uncategorized: row["uncategorized_tokens"]
            ),
            sourcePath: sourcePath
        )
    }
}

public actor SQLiteFileCursorStore: FileCursorPersisting {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func cursor(forPath path: String) throws -> FileTailCursor? {
        try pool.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM file_cursors WHERE path = ?",
                arguments: [path]
            ) else { return nil }

            guard
                let deviceID: Int64 = row["device_id"],
                let inode: Int64 = row["inode"],
                let byteOffset: Int64 = row["byte_offset"],
                let updatedAt: Date = row["updated_at"]
            else { return nil }

            return FileTailCursor(
                path: path,
                identity: FileIdentity(
                    deviceID: UInt64(bitPattern: deviceID),
                    inode: UInt64(bitPattern: inode)
                ),
                byteOffset: UInt64(bitPattern: byteOffset),
                updatedAt: updatedAt
            )
        }
    }

    public func saveCursor(_ cursor: FileTailCursor) throws {
        try pool.write { database in
            try database.execute(
                sql: """
                INSERT INTO file_cursors (path, device_id, inode, byte_offset, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    device_id = excluded.device_id,
                    inode = excluded.inode,
                    byte_offset = excluded.byte_offset,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    cursor.path,
                    Int64(bitPattern: cursor.identity.deviceID),
                    Int64(bitPattern: cursor.identity.inode),
                    Int64(bitPattern: cursor.byteOffset),
                    cursor.updatedAt,
                ]
            )
        }
    }
}

public actor SQLiteAgentRateLimitStore: AgentRateLimitPersisting {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func saveRateLimits(_ limits: [AgentRateLimit]) throws {
        guard !limits.isEmpty else { return }
        try pool.write { database in
            for limit in limits {
                try database.execute(
                    sql: """
                    INSERT INTO agent_rate_limits (
                        provider, window, used_percent, resets_at,
                        is_estimate, observed_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, window) DO UPDATE SET
                        used_percent = excluded.used_percent,
                        resets_at = excluded.resets_at,
                        is_estimate = excluded.is_estimate,
                        observed_at = excluded.observed_at
                    WHERE excluded.observed_at >= agent_rate_limits.observed_at
                    """,
                    arguments: [
                        limit.provider.rawValue,
                        limit.window.rawValue,
                        limit.usedPercent,
                        limit.resetsAt,
                        limit.isEstimate,
                        limit.observedAt,
                    ]
                )
            }
        }
    }

    public func currentRateLimits() throws -> [AgentRateLimit] {
        try pool.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT * FROM agent_rate_limits ORDER BY provider, window"
            ).compactMap { row in
                guard
                    let providerValue: String = row["provider"],
                    let provider = AgentProvider(rawValue: providerValue),
                    let windowValue: String = row["window"],
                    let window = RateLimitWindow(rawValue: windowValue),
                    let usedPercent: Double = row["used_percent"],
                    let isEstimate: Bool = row["is_estimate"],
                    let observedAt: Date = row["observed_at"]
                else { return nil }
                return AgentRateLimit(
                    provider: provider,
                    window: window,
                    usedPercent: usedPercent,
                    resetsAt: row["resets_at"],
                    isEstimate: isEstimate,
                    observedAt: observedAt
                )
            }
        }
    }
}

public actor SQLiteWindowPositionStore: WindowPositionPersisting {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func position(forDisplayID displayID: String) throws -> DockedWindowPosition? {
        try pool.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM positions WHERE display_id = ?",
                arguments: [displayID]
            ) else { return nil }
            guard
                let edgeValue: String = row["edge"],
                let edge = DockEdge(rawValue: edgeValue),
                let fraction: Double = row["fractional_offset"],
                let isPeeking: Bool = row["is_peeking"],
                let updatedAt: Date = row["updated_at"]
            else { return nil }
            return DockedWindowPosition(
                displayID: displayID,
                edge: edge,
                fractionalOffset: fraction,
                isPeeking: isPeeking,
                updatedAt: updatedAt
            )
        }
    }

    public func savePosition(_ position: DockedWindowPosition) throws {
        try pool.write { database in
            try database.execute(
                sql: """
                INSERT INTO positions (display_id, edge, fractional_offset, is_peeking, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(display_id) DO UPDATE SET
                    edge = excluded.edge,
                    fractional_offset = excluded.fractional_offset,
                    is_peeking = excluded.is_peeking,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    position.displayID,
                    position.edge.rawValue,
                    position.fractionalOffset,
                    position.isPeeking,
                    position.updatedAt,
                ]
            )
        }
    }

    public func deletePositions() throws {
        try pool.write { database in
            try database.execute(sql: "DELETE FROM positions")
        }
    }
}

public actor SQLiteSettingsStore: SettingsPersisting {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func data(forKey key: String) throws -> Data? {
        try pool.read { database in
            try Data.fetchOne(
                database,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: [key]
            )
        }
    }

    public func saveData(_ data: Data, forKey key: String) throws {
        try pool.write { database in
            try database.execute(
                sql: """
                INSERT INTO settings (key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updated_at = excluded.updated_at
                """,
                arguments: [key, data, Date.now]
            )
        }
    }
}
