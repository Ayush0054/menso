import Foundation
import GRDB

public struct StoredTrustedRunAuthority: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case agent
        case workflow
    }

    public let id: String
    public let kind: Kind
    public let authorityJSON: Data
    public let updatedAt: Date
    public let expiresAt: Date

    public init(
        id: String,
        kind: Kind,
        authorityJSON: Data,
        updatedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.authorityJSON = authorityJSON
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

public protocol TrustedRunAuthorityPersisting: Sendable {
    func saveTrustedRunAuthority(_ authority: StoredTrustedRunAuthority) async throws
    func updateTrustedRunAuthority(
        _ authority: StoredTrustedRunAuthority,
        replacingAuthorityJSON: Data
    ) async throws
    func trustedRunAuthority(id: String, at date: Date) async throws -> StoredTrustedRunAuthority?
    func deleteTrustedRunAuthority(id: String) async throws
}

/// Opaque durable authority storage. The Runtime registry owns typed decoding
/// and equality checks; this layer rejects overwrites with a different binding.
public actor SQLiteTrustedRunAuthorityStore: TrustedRunAuthorityPersisting {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func saveTrustedRunAuthority(_ authority: StoredTrustedRunAuthority) throws {
        guard !authority.id.isEmpty,
              !authority.authorityJSON.isEmpty,
              authority.expiresAt > authority.updatedAt
        else { throw TrustedRunAuthorityStoreError.invalidAuthority }

        try pool.write { database in
            try database.execute(
                sql: "DELETE FROM trusted_run_authorities WHERE expires_at <= ?",
                arguments: [authority.updatedAt]
            )
            try database.execute(
                sql: """
                INSERT INTO trusted_run_authorities (
                    id, kind, authority_json, updated_at, expires_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    authority.id,
                    authority.kind.rawValue,
                    authority.authorityJSON,
                    authority.updatedAt,
                    authority.expiresAt,
                ]
            )
            if database.changesCount == 0 {
                guard let row = try Row.fetchOne(
                    database,
                    sql: "SELECT kind, authority_json, expires_at FROM trusted_run_authorities WHERE id = ?",
                    arguments: [authority.id]
                ),
                let kind: String = row["kind"],
                let data: Data = row["authority_json"],
                let expiresAt: Date = row["expires_at"],
                kind == authority.kind.rawValue,
                data == authority.authorityJSON,
                abs(expiresAt.timeIntervalSince(authority.expiresAt)) < 0.002
                else { throw TrustedRunAuthorityStoreError.bindingConflict }
                try database.execute(
                    sql: "UPDATE trusted_run_authorities SET updated_at = ? WHERE id = ?",
                    arguments: [authority.updatedAt, authority.id]
                )
            }
        }
    }

    public func trustedRunAuthority(
        id: String,
        at date: Date
    ) throws -> StoredTrustedRunAuthority? {
        guard !id.isEmpty else { return nil }
        return try pool.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM trusted_run_authorities WHERE id = ? AND expires_at > ?",
                arguments: [id, date]
            ),
            let rawKind: String = row["kind"],
            let kind = StoredTrustedRunAuthority.Kind(rawValue: rawKind),
            let authorityJSON: Data = row["authority_json"],
            let updatedAt: Date = row["updated_at"],
            let expiresAt: Date = row["expires_at"]
            else { return nil }
            return StoredTrustedRunAuthority(
                id: id,
                kind: kind,
                authorityJSON: authorityJSON,
                updatedAt: updatedAt,
                expiresAt: expiresAt
            )
        }
    }

    public func updateTrustedRunAuthority(
        _ authority: StoredTrustedRunAuthority,
        replacingAuthorityJSON: Data
    ) throws {
        guard !authority.id.isEmpty,
              !authority.authorityJSON.isEmpty,
              !replacingAuthorityJSON.isEmpty,
              authority.expiresAt > authority.updatedAt
        else { throw TrustedRunAuthorityStoreError.invalidAuthority }
        try pool.write { database in
            try database.execute(
                sql: """
                UPDATE trusted_run_authorities
                SET authority_json = ?, updated_at = ?
                WHERE id = ? AND kind = ? AND authority_json = ?
                """,
                arguments: [
                    authority.authorityJSON,
                    authority.updatedAt,
                    authority.id,
                    authority.kind.rawValue,
                    replacingAuthorityJSON,
                ]
            )
            guard database.changesCount == 1 else {
                throw TrustedRunAuthorityStoreError.bindingConflict
            }
        }
    }

    public func deleteTrustedRunAuthority(id: String) throws {
        guard !id.isEmpty else { return }
        try pool.write { database in
            try database.execute(
                sql: "DELETE FROM trusted_run_authorities WHERE id = ?",
                arguments: [id]
            )
        }
    }
}

public enum TrustedRunAuthorityStoreError: Error, Sendable, Equatable {
    case invalidAuthority
    case bindingConflict
    case corruptAuthority
}
