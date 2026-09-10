import Foundation
import GRDB

public enum RunContinuationEndpointKind: String, Codable, Hashable, Sendable {
    case agent
    case workflow
}

public enum RunContinuationDeliveryState: String, Codable, Hashable, Sendable {
    case pending
    case exhausted
    case delivered
}

/// The exact endpoint-specific continuation payload is encoded once and kept as
/// opaque JSON. Retries decode this same blob; they never rebuild requirements
/// from an ActionResult or execute the local semantic action again.
public struct RunContinuationOutboxEntry: Sendable, Hashable {
    public let id: String
    public let endpointKind: RunContinuationEndpointKind
    public let executorID: String
    public let runID: String
    public let userID: UserID
    public let sessionID: ProductSessionID
    public let payloadHash: ContentHash
    public let payloadJSON: Data
    public let deliveryState: RunContinuationDeliveryState
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let createdAt: Date

    public static func agent(
        _ continuation: AgentRunContinuation,
        createdAt: Date = Date()
    ) throws -> RunContinuationOutboxEntry {
        try make(
            endpointKind: .agent,
            executorID: continuation.agentID,
            runID: continuation.runID,
            userID: continuation.userID,
            sessionID: continuation.sessionID,
            continuation: continuation,
            createdAt: createdAt
        )
    }

    public static func workflow(
        _ continuation: WorkflowRunContinuation,
        createdAt: Date = Date()
    ) throws -> RunContinuationOutboxEntry {
        try make(
            endpointKind: .workflow,
            executorID: continuation.workflowID,
            runID: continuation.runID,
            userID: continuation.userID,
            sessionID: continuation.sessionID,
            continuation: continuation,
            createdAt: createdAt
        )
    }

    public func agentContinuation() throws -> AgentRunContinuation {
        guard endpointKind == .agent else { throw RunContinuationOutboxError.endpointMismatch }
        let continuation = try JSONDecoder().decode(
            AgentRunContinuation.self,
            from: verifiedPayload()
        )
        guard deliveryState == .pending,
              continuation.agentID == executorID,
              continuation.runID == runID,
              continuation.userID == userID,
              continuation.sessionID == sessionID
        else { throw RunContinuationOutboxError.authorityMismatch }
        return continuation
    }

    public func workflowContinuation() throws -> WorkflowRunContinuation {
        guard endpointKind == .workflow else { throw RunContinuationOutboxError.endpointMismatch }
        let continuation = try JSONDecoder().decode(
            WorkflowRunContinuation.self,
            from: verifiedPayload()
        )
        guard deliveryState == .pending,
              continuation.workflowID == executorID,
              continuation.runID == runID,
              continuation.userID == userID,
              continuation.sessionID == sessionID
        else { throw RunContinuationOutboxError.authorityMismatch }
        return continuation
    }

    private static func make<Continuation: Encodable>(
        endpointKind: RunContinuationEndpointKind,
        executorID: String,
        runID: String,
        userID: UserID,
        sessionID: ProductSessionID,
        continuation: Continuation,
        createdAt: Date
    ) throws -> RunContinuationOutboxEntry {
        guard !executorID.isEmpty,
              !runID.isEmpty,
              !userID.rawValue.isEmpty,
              !sessionID.rawValue.isEmpty
        else { throw RunContinuationOutboxError.invalidIdentity }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(continuation)
        guard let payloadText = String(data: payload, encoding: .utf8) else {
            throw RunContinuationOutboxError.invalidPayload
        }
        let payloadHash = ContentHash.sha256(of: payloadText)
        let identity = ContentHash.sha256(
            of: "\(endpointKind.rawValue)\u{1f}\(executorID)\u{1f}\(runID)\u{1f}\(payloadHash.rawValue)"
        ).rawValue
        return RunContinuationOutboxEntry(
            id: "continuation:\(identity)",
            endpointKind: endpointKind,
            executorID: executorID,
            runID: runID,
            userID: userID,
            sessionID: sessionID,
            payloadHash: payloadHash,
            payloadJSON: payload,
            deliveryState: .pending,
            attemptCount: 0,
            nextAttemptAt: createdAt,
            createdAt: createdAt
        )
    }

    private func verifiedPayload() throws -> Data {
        guard let payloadText = String(data: payloadJSON, encoding: .utf8),
              ContentHash.sha256(of: payloadText) == payloadHash
        else { throw RunContinuationOutboxError.payloadIntegrityFailure }
        return payloadJSON
    }

    fileprivate init(
        id: String,
        endpointKind: RunContinuationEndpointKind,
        executorID: String,
        runID: String,
        userID: UserID,
        sessionID: ProductSessionID,
        payloadHash: ContentHash,
        payloadJSON: Data,
        deliveryState: RunContinuationDeliveryState,
        attemptCount: Int,
        nextAttemptAt: Date,
        createdAt: Date
    ) {
        self.id = id
        self.endpointKind = endpointKind
        self.executorID = executorID
        self.runID = runID
        self.userID = userID
        self.sessionID = sessionID
        self.payloadHash = payloadHash
        self.payloadJSON = payloadJSON
        self.deliveryState = deliveryState
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.createdAt = createdAt
    }
}

public enum RunContinuationEnqueueOutcome: Sendable, Hashable {
    case pending(RunContinuationOutboxEntry)
    case alreadyDelivered
}

public enum RunContinuationDeliveryOutcome: Sendable, Hashable {
    case accepted
    case deferred
    case exhausted
}

public enum RunContinuationOutboxError: Error, Sendable, Equatable {
    case invalidIdentity
    case invalidPayload
    case payloadIntegrityFailure
    case endpointMismatch
    case authorityMismatch
    case conflictingRecord
}

public protocol RunContinuationOutboxPersisting: Sendable {
    func enqueue(_ entry: RunContinuationOutboxEntry) async throws -> RunContinuationEnqueueOutcome
    func dueContinuations(at date: Date, limit: Int) async throws -> [RunContinuationOutboxEntry]
    func continuations(
        deliveryState: RunContinuationDeliveryState,
        limit: Int
    ) async throws -> [RunContinuationOutboxEntry]
    func markContinuationDelivered(id: String, deliveredAt: Date) async throws
    func recordContinuationFailure(
        id: String,
        attemptCount: Int,
        nextAttemptAt: Date,
        exhausted: Bool
    ) async throws
    func retryContinuation(id: String, at date: Date) async throws
    func deliveryState(id: String) async throws -> RunContinuationDeliveryState?
    func continuation(id: String) async throws -> RunContinuationOutboxEntry?
}

public actor SQLiteRunContinuationOutbox: RunContinuationOutboxPersisting {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func enqueue(
        _ entry: RunContinuationOutboxEntry
    ) throws -> RunContinuationEnqueueOutcome {
        try pool.write { database in
            if let existing = try Self.fetch(id: entry.id, database: database) {
                guard existing.endpointKind == entry.endpointKind,
                      existing.executorID == entry.executorID,
                      existing.runID == entry.runID,
                      existing.userID == entry.userID,
                      existing.sessionID == entry.sessionID,
                      existing.payloadHash == entry.payloadHash,
                      existing.payloadJSON == entry.payloadJSON
                else { throw RunContinuationOutboxError.conflictingRecord }
                return existing.deliveryState == .delivered
                    ? .alreadyDelivered
                    : .pending(existing)
            }

            try database.execute(
                sql: """
                INSERT INTO agentos_continuation_outbox (
                    id, endpoint_kind, executor_id, run_id, user_id, session_id,
                    payload_hash, payload_json, delivery_state, delivery_nonce, attempt_count,
                    next_attempt_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                """,
                arguments: [
                    entry.id,
                    entry.endpointKind.rawValue,
                    entry.executorID,
                    entry.runID,
                    entry.userID.rawValue,
                    entry.sessionID.rawValue,
                    entry.payloadHash.rawValue,
                    entry.payloadJSON,
                    RunContinuationDeliveryState.pending.rawValue,
                    entry.id,
                    entry.nextAttemptAt,
                    entry.createdAt,
                    entry.createdAt,
                ]
            )
            return .pending(entry)
        }
    }

    public func dueContinuations(at date: Date, limit: Int) throws -> [RunContinuationOutboxEntry] {
        guard limit > 0 else { return [] }
        return try pool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                SELECT * FROM agentos_continuation_outbox
                WHERE delivery_state = 'pending' AND next_attempt_at <= ?
                ORDER BY created_at ASC
                LIMIT ?
                """,
                arguments: [date, min(limit, 64)]
            ).map(Self.decode)
        }
    }

    public func continuations(
        deliveryState: RunContinuationDeliveryState,
        limit: Int
    ) throws -> [RunContinuationOutboxEntry] {
        guard limit > 0 else { return [] }
        return try pool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                SELECT * FROM agentos_continuation_outbox
                WHERE delivery_state = ?
                ORDER BY created_at ASC
                LIMIT ?
                """,
                arguments: [deliveryState.rawValue, min(limit, 1_000)]
            ).map(Self.decode)
        }
    }

    public func markContinuationDelivered(id: String, deliveredAt: Date) throws {
        try pool.write { database in
            let exists = try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM agentos_continuation_outbox WHERE id = ?)",
                arguments: [id]
            ) ?? false
            guard exists else { throw RunContinuationOutboxError.conflictingRecord }
            try database.execute(
                sql: """
                UPDATE agentos_continuation_outbox
                SET delivery_state = 'delivered', delivered_at = ?, updated_at = ?, last_error_code = NULL
                WHERE id = ? AND delivery_state != 'delivered'
                """,
                arguments: [deliveredAt, deliveredAt, id]
            )
        }
    }

    public func recordContinuationFailure(
        id: String,
        attemptCount: Int,
        nextAttemptAt: Date,
        exhausted: Bool
    ) throws {
        try pool.write { database in
            let exists = try Bool.fetchOne(
                database,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM agentos_continuation_outbox
                    WHERE id = ? AND delivery_state != 'delivered'
                )
                """,
                arguments: [id]
            ) ?? false
            guard exists else { throw RunContinuationOutboxError.conflictingRecord }
            try database.execute(
                sql: """
                UPDATE agentos_continuation_outbox
                SET delivery_state = ?, attempt_count = ?, next_attempt_at = ?,
                    last_error_code = 'delivery_failed', updated_at = ?
                WHERE id = ? AND delivery_state != 'delivered'
                """,
                arguments: [
                    exhausted
                        ? RunContinuationDeliveryState.exhausted.rawValue
                        : RunContinuationDeliveryState.pending.rawValue,
                    max(0, attemptCount),
                    nextAttemptAt,
                    Date(),
                    id,
                ]
            )
        }
    }

    public func retryContinuation(id: String, at date: Date) throws {
        try pool.write { database in
            try database.execute(
                sql: """
                UPDATE agentos_continuation_outbox
                SET delivery_state = 'pending', attempt_count = 0,
                    next_attempt_at = ?, last_error_code = NULL, updated_at = ?
                WHERE id = ? AND delivery_state = 'exhausted'
                """,
                arguments: [date, date, id]
            )
            guard database.changesCount == 1 else {
                throw RunContinuationOutboxError.conflictingRecord
            }
        }
    }

    public func deliveryState(id: String) throws -> RunContinuationDeliveryState? {
        try pool.read { database in
            guard let raw = try String.fetchOne(
                database,
                sql: "SELECT delivery_state FROM agentos_continuation_outbox WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            guard let state = RunContinuationDeliveryState(rawValue: raw) else {
                throw RunContinuationOutboxError.invalidPayload
            }
            return state
        }
    }

    public func continuation(id: String) throws -> RunContinuationOutboxEntry? {
        try pool.read { database in
            try Self.fetch(id: id, database: database)
        }
    }

    private static func fetch(id: String, database: Database) throws -> RunContinuationOutboxEntry? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM agentos_continuation_outbox WHERE id = ?",
            arguments: [id]
        ) else { return nil }
        return try decode(row)
    }

    private static func decode(_ row: Row) throws -> RunContinuationOutboxEntry {
        guard let id: String = row["id"],
              let kindRaw: String = row["endpoint_kind"],
              let kind = RunContinuationEndpointKind(rawValue: kindRaw),
              let executorID: String = row["executor_id"],
              let runID: String = row["run_id"],
              let userID: String = row["user_id"],
              let sessionID: String = row["session_id"],
              let payloadHashRaw: String = row["payload_hash"],
              let payloadJSON: Data = row["payload_json"],
              let stateRaw: String = row["delivery_state"],
              let state = RunContinuationDeliveryState(rawValue: stateRaw),
              let attemptCount: Int = row["attempt_count"],
              let nextAttemptAt: Date = row["next_attempt_at"],
              let createdAt: Date = row["created_at"]
        else { throw RunContinuationOutboxError.invalidPayload }
        let payloadHash = ContentHash(rawValue: payloadHashRaw)
        guard payloadHash.isValidSHA256 else {
            throw RunContinuationOutboxError.payloadIntegrityFailure
        }
        return RunContinuationOutboxEntry(
            id: id,
            endpointKind: kind,
            executorID: executorID,
            runID: runID,
            userID: UserID(rawValue: userID),
            sessionID: ProductSessionID(rawValue: sessionID),
            payloadHash: payloadHash,
            payloadJSON: payloadJSON,
            deliveryState: state,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            createdAt: createdAt
        )
    }
}
