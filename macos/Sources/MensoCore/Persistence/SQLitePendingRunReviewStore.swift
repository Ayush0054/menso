import Foundation
import GRDB

public struct StoredPendingRunReview: Sendable, Hashable {
    public let actionID: ActionID
    public let requirementJSON: Data
    public let requestJSON: Data
    public let contextJSON: Data
    public let resolvedContextJSON: Data?
    public let envelopeHash: ContentHash
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        actionID: ActionID,
        requirementJSON: Data,
        requestJSON: Data,
        contextJSON: Data,
        resolvedContextJSON: Data? = nil,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.actionID = actionID
        self.requirementJSON = requirementJSON
        self.requestJSON = requestJSON
        self.contextJSON = contextJSON
        self.resolvedContextJSON = resolvedContextJSON
        self.envelopeHash = Self.hash(
            actionID: actionID,
            requirementJSON: requirementJSON,
            requestJSON: requestJSON,
            contextJSON: contextJSON,
            resolvedContextJSON: resolvedContextJSON
        )
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    fileprivate init(
        actionID: ActionID,
        requirementJSON: Data,
        requestJSON: Data,
        contextJSON: Data,
        resolvedContextJSON: Data?,
        envelopeHash: ContentHash,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.actionID = actionID
        self.requirementJSON = requirementJSON
        self.requestJSON = requestJSON
        self.contextJSON = contextJSON
        self.resolvedContextJSON = resolvedContextJSON
        self.envelopeHash = envelopeHash
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public var hasValidIntegrity: Bool {
        !actionID.rawValue.isEmpty
            && !requirementJSON.isEmpty
            && !requestJSON.isEmpty
            && !contextJSON.isEmpty
            && envelopeHash == Self.hash(
                actionID: actionID,
                requirementJSON: requirementJSON,
                requestJSON: requestJSON,
                contextJSON: contextJSON,
                resolvedContextJSON: resolvedContextJSON
            )
    }

    private static func hash(
        actionID: ActionID,
        requirementJSON: Data,
        requestJSON: Data,
        contextJSON: Data,
        resolvedContextJSON: Data?
    ) -> ContentHash {
        ContentHash.sha256(
            of: actionID.rawValue
                + "\u{1f}" + requirementJSON.base64EncodedString()
                + "\u{1f}" + requestJSON.base64EncodedString()
                + "\u{1f}" + contextJSON.base64EncodedString()
                + "\u{1f}" + (resolvedContextJSON?.base64EncodedString() ?? "unresolved")
        )
    }
}

public protocol PendingRunReviewPersisting: Sendable {
    func savePendingRunReview(_ review: StoredPendingRunReview) async throws
    func pendingRunReviews(at date: Date, limit: Int) async throws -> [StoredPendingRunReview]
    func markPendingRunReviewResolved(
        actionID: ActionID,
        resolvedContextJSON: Data,
        at date: Date
    ) async throws
    func deletePendingRunReview(actionID: ActionID) async throws
}

public actor SQLitePendingRunReviewStore: PendingRunReviewPersisting {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func savePendingRunReview(_ review: StoredPendingRunReview) throws {
        guard review.hasValidIntegrity,
              review.expiresAt > review.createdAt
        else { throw PendingRunReviewStoreError.invalidReview }

        try pool.write { database in
            try database.execute(
                sql: "DELETE FROM pending_run_reviews WHERE expires_at <= ?",
                arguments: [review.createdAt]
            )
            try database.execute(
                sql: """
                INSERT INTO pending_run_reviews (
                    action_id, requirement_json, request_json, context_json,
                    resolved_context_json, envelope_hash, created_at, expires_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(action_id) DO NOTHING
                """,
                arguments: [
                    review.actionID.rawValue,
                    review.requirementJSON,
                    review.requestJSON,
                    review.contextJSON,
                    review.resolvedContextJSON,
                    review.envelopeHash.rawValue,
                    review.createdAt,
                    review.expiresAt,
                    review.createdAt,
                ]
            )
            if database.changesCount == 0 {
                guard let existing = try Self.fetch(
                    actionID: review.actionID,
                    database: database
                ), existing.requirementJSON == review.requirementJSON,
                   existing.requestJSON == review.requestJSON,
                   existing.contextJSON == review.contextJSON,
                   existing.resolvedContextJSON == nil,
                   review.resolvedContextJSON == nil,
                   existing.envelopeHash == review.envelopeHash,
                   abs(existing.expiresAt.timeIntervalSince(review.expiresAt)) < 0.002
                else { throw PendingRunReviewStoreError.bindingConflict }
            }
        }
    }

    public func pendingRunReviews(
        at date: Date,
        limit: Int
    ) throws -> [StoredPendingRunReview] {
        guard limit > 0 else { return [] }
        return try pool.write { database in
            try database.execute(
                sql: "DELETE FROM pending_run_reviews WHERE expires_at <= ?",
                arguments: [date]
            )
            return try Row.fetchAll(
                database,
                sql: """
                SELECT * FROM pending_run_reviews
                WHERE expires_at > ?
                ORDER BY created_at ASC
                LIMIT ?
                """,
                arguments: [date, min(limit, 1_000)]
            ).map(Self.decode)
        }
    }

    public func markPendingRunReviewResolved(
        actionID: ActionID,
        resolvedContextJSON: Data,
        at date: Date
    ) throws {
        guard !actionID.rawValue.isEmpty, !resolvedContextJSON.isEmpty else {
            throw PendingRunReviewStoreError.invalidReview
        }
        try pool.write { database in
            guard let existing = try Self.fetch(actionID: actionID, database: database),
                  existing.expiresAt > date
            else { throw PendingRunReviewStoreError.invalidReview }
            if let prior = existing.resolvedContextJSON {
                guard prior == resolvedContextJSON else {
                    throw PendingRunReviewStoreError.bindingConflict
                }
                return
            }
            let updated = StoredPendingRunReview(
                actionID: existing.actionID,
                requirementJSON: existing.requirementJSON,
                requestJSON: existing.requestJSON,
                contextJSON: existing.contextJSON,
                resolvedContextJSON: resolvedContextJSON,
                createdAt: existing.createdAt,
                expiresAt: existing.expiresAt
            )
            try database.execute(
                sql: """
                UPDATE pending_run_reviews
                SET resolved_context_json = ?, envelope_hash = ?, updated_at = ?
                WHERE action_id = ? AND resolved_context_json IS NULL
                """,
                arguments: [
                    resolvedContextJSON,
                    updated.envelopeHash.rawValue,
                    date,
                    actionID.rawValue,
                ]
            )
            guard database.changesCount == 1 else {
                throw PendingRunReviewStoreError.bindingConflict
            }
        }
    }

    public func deletePendingRunReview(actionID: ActionID) throws {
        guard !actionID.rawValue.isEmpty else { return }
        try pool.write { database in
            try database.execute(
                sql: "DELETE FROM pending_run_reviews WHERE action_id = ?",
                arguments: [actionID.rawValue]
            )
        }
    }

    private static func fetch(
        actionID: ActionID,
        database: Database
    ) throws -> StoredPendingRunReview? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM pending_run_reviews WHERE action_id = ?",
            arguments: [actionID.rawValue]
        ) else { return nil }
        return try decode(row)
    }

    private static func decode(_ row: Row) throws -> StoredPendingRunReview {
        guard let actionID: String = row["action_id"],
              let requirementJSON: Data = row["requirement_json"],
              let requestJSON: Data = row["request_json"],
              let contextJSON: Data = row["context_json"],
              let envelopeHashRaw: String = row["envelope_hash"],
              let createdAt: Date = row["created_at"],
              let expiresAt: Date = row["expires_at"]
        else { throw PendingRunReviewStoreError.invalidReview }
        let review = StoredPendingRunReview(
            actionID: ActionID(rawValue: actionID),
            requirementJSON: requirementJSON,
            requestJSON: requestJSON,
            contextJSON: contextJSON,
            resolvedContextJSON: row["resolved_context_json"],
            envelopeHash: ContentHash(rawValue: envelopeHashRaw),
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        guard review.hasValidIntegrity else {
            throw PendingRunReviewStoreError.integrityFailure
        }
        return review
    }
}

public enum PendingRunReviewStoreError: Error, Sendable, Equatable {
    case invalidReview
    case integrityFailure
    case bindingConflict
}
