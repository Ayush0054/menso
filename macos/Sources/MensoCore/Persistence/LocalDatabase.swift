import Foundation
import GRDB

public final class LocalDatabase: @unchecked Sendable {
    public let pool: DatabasePool

    public init(url: URL) throws {
        var configuration = Configuration()
        configuration.label = "MensoLocalDatabase"
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }

        pool = try DatabasePool(path: url.path, configuration: configuration)
        try Self.migrator.migrate(pool)
    }

    public static func openDefault(fileManager: FileManager = .default) throws -> LocalDatabase {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appending(path: "Menso", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try LocalDatabase(url: directory.appending(path: "menso.sqlite"))
    }

    public var usageStore: SQLiteUsageEventStore {
        SQLiteUsageEventStore(pool: pool)
    }

    public var cursorStore: SQLiteFileCursorStore {
        SQLiteFileCursorStore(pool: pool)
    }

    public var rateLimitStore: SQLiteAgentRateLimitStore {
        SQLiteAgentRateLimitStore(pool: pool)
    }

    public var positionStore: SQLiteWindowPositionStore {
        SQLiteWindowPositionStore(pool: pool)
    }

    public var settingsStore: SQLiteSettingsStore {
        SQLiteSettingsStore(pool: pool)
    }

    /// Fail-closed action audit/result persistence. Do not replace this with
    /// `VolatilePersistence` when constructing `ActionExecutor`.
    public var actionStore: SQLiteActionStore {
        SQLiteActionStore(pool: pool)
    }

    public var runContinuationOutbox: SQLiteRunContinuationOutbox {
        SQLiteRunContinuationOutbox(pool: pool)
    }

    public var trustedRunAuthorityStore: SQLiteTrustedRunAuthorityStore {
        SQLiteTrustedRunAuthorityStore(pool: pool)
    }

    public var pendingRunReviewStore: SQLitePendingRunReviewStore {
        SQLitePendingRunReviewStore(pool: pool)
    }
}
