import Foundation
import GRDB

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
