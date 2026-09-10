import Foundation
import GRDB

/// The production on-device truth for policy and desktop execution.
/// Unlike monitor telemetry, this store has no volatile fallback.
public actor SQLiteActionStore: ActionAuditSink, ActionResultStore {
    private let pool: DatabasePool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(pool: DatabasePool) {
        self.pool = pool
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public func record(_ event: ActionAuditEvent) throws {
        let envelope = AuditEnvelope(event)
        let payload = try encoder.encode(envelope)

        try pool.write { database in
            try upsertActionRow(for: event, database: database)
            try database.execute(
                sql: """
                INSERT INTO action_audit_events (
                    action_id, event_type, payload_json, recorded_at
                ) VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    envelope.actionID,
                    envelope.eventType,
                    payload,
                    envelope.recordedAt,
                ]
            )
        }
    }

    public func execution(for idempotencyKey: IdempotencyKey) throws -> StoredActionExecution? {
        try pool.read { database in
            guard let data = try Data.fetchOne(
                database,
                sql: "SELECT execution_json FROM actions WHERE idempotency_key = ?",
                arguments: [idempotencyKey.rawValue]
            ) else { return nil }
            return try decoder.decode(StoredActionExecution.self, from: data)
        }
    }

    public func execution(for actionID: ActionID) throws -> StoredActionExecution? {
        try pool.read { database in
            guard let data = try Data.fetchOne(
                database,
                sql: "SELECT execution_json FROM actions WHERE id = ?",
                arguments: [actionID.rawValue]
            ) else { return nil }
            return try decoder.decode(StoredActionExecution.self, from: data)
        }
    }

    public func reserve(
        _ reservation: ActionExecutionReservation
    ) throws -> ActionReservationOutcome {
        let reservationData = try encoder.encode(reservation)
        let bindingData = try encoder.encode(reservation.binding)

        return try pool.write { database in
            if let executionData = try Data.fetchOne(
                database,
                sql: "SELECT execution_json FROM actions WHERE idempotency_key = ?",
                arguments: [reservation.idempotencyKey.rawValue]
            ) {
                let execution = try decoder.decode(StoredActionExecution.self, from: executionData)
                return execution.binding == reservation.binding
                    ? .existingTerminal(execution)
                    : .conflict
            }

            if let row = try Row.fetchOne(
                database,
                sql: "SELECT binding_json FROM actions WHERE id = ?",
                arguments: [reservation.binding.actionID.rawValue]
            ) {
                let bindingData: Data = row["binding_json"]
                guard let binding = try? decoder.decode(
                    ActionExecutionBinding.self,
                    from: bindingData
                ), binding == reservation.binding else {
                    return .conflict
                }
            }

            if let existingData = try Data.fetchOne(
                database,
                sql: "SELECT reservation_json FROM action_execution_reservations WHERE idempotency_key = ?",
                arguments: [reservation.idempotencyKey.rawValue]
            ) {
                let existing = try decoder.decode(ActionExecutionReservation.self, from: existingData)
                return existing.binding == reservation.binding
                    ? .existingReservation(existing)
                    : .conflict
            }

            if let existingData = try Data.fetchOne(
                database,
                sql: "SELECT reservation_json FROM action_execution_reservations WHERE action_id = ?",
                arguments: [reservation.binding.actionID.rawValue]
            ) {
                let existing = try decoder.decode(ActionExecutionReservation.self, from: existingData)
                return existing.binding == reservation.binding
                    ? .existingReservation(existing)
                    : .conflict
            }

            try database.execute(
                sql: """
                INSERT INTO action_execution_reservations (
                    idempotency_key, action_id, binding_json,
                    reservation_json, reserved_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    reservation.idempotencyKey.rawValue,
                    reservation.binding.actionID.rawValue,
                    bindingData,
                    reservationData,
                    reservation.reservedAt,
                ]
            )
            return .acquired
        }
    }

    public func save(_ execution: StoredActionExecution) throws {
        let bindingData = try encoder.encode(execution.binding)
        let targetData = try encoder.encode(execution.binding.target)
        let resultData = try encoder.encode(execution.result)
        let executionData = try encoder.encode(execution)
        let timestamp = execution.result.completedAt

        try pool.write { database in
            let existingRows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, idempotency_key, binding_json, execution_json
                FROM actions
                WHERE id = ? OR idempotency_key = ?
                """,
                arguments: [execution.actionID.rawValue, execution.idempotencyKey.rawValue]
            )
            for row in existingRows {
                let actionID: String = row["id"]
                let idempotencyKey: String = row["idempotency_key"]
                let existingBindingData: Data = row["binding_json"]
                guard actionID == execution.actionID.rawValue,
                      idempotencyKey == execution.idempotencyKey.rawValue,
                      let existingBinding = try? decoder.decode(
                          ActionExecutionBinding.self,
                          from: existingBindingData
                      ),
                      existingBinding == execution.binding
                else { throw ActionAuditError.rejected }

                let existingExecutionData: Data? = row["execution_json"]
                if let existingExecutionData {
                    guard let existingExecution = try? decoder.decode(
                        StoredActionExecution.self,
                        from: existingExecutionData
                    ), existingExecution == execution else {
                        throw ActionAuditError.rejected
                    }
                }
            }

            if let existingData = try Data.fetchOne(
                database,
                sql: "SELECT reservation_json FROM action_execution_reservations WHERE idempotency_key = ?",
                arguments: [execution.idempotencyKey.rawValue]
            ) {
                let reservation = try decoder.decode(ActionExecutionReservation.self, from: existingData)
                guard reservation.binding == execution.binding else {
                    throw ActionAuditError.rejected
                }
            }
            try database.execute(
                sql: """
                INSERT INTO actions (
                    id, idempotency_key, kind, source, target_json,
                    request_json, binding_json, policy_decision, status,
                    result_json, execution_json, evidence_ref, undo_deadline,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, NULL, ?, NULL, ?, ?, ?, ?, NULL, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    idempotency_key = excluded.idempotency_key,
                    kind = excluded.kind,
                    source = excluded.source,
                    target_json = excluded.target_json,
                    binding_json = excluded.binding_json,
                    status = excluded.status,
                    result_json = excluded.result_json,
                    execution_json = excluded.execution_json,
                    evidence_ref = excluded.evidence_ref,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    execution.actionID.rawValue,
                    execution.idempotencyKey.rawValue,
                    execution.binding.operation.semanticToolName,
                    execution.binding.source.rawValue,
                    targetData,
                    bindingData,
                    execution.result.status.rawValue,
                    resultData,
                    executionData,
                    execution.result.evidenceReference?.rawValue,
                    timestamp,
                    timestamp,
                ]
            )
            try database.execute(
                sql: "DELETE FROM action_execution_reservations WHERE idempotency_key = ?",
                arguments: [execution.idempotencyKey.rawValue]
            )
        }
    }

    private func upsertActionRow(
        for event: ActionAuditEvent,
        database: Database
    ) throws {
        switch event {
        case let .requestReceived(request):
            let targetData = try encoder.encode(request.target)
            let requestData = try encoder.encode(request)
            let binding = ActionExecutionBinding(request: request)
            let bindingData = try encoder.encode(binding)
            let existingRows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, idempotency_key, request_json, binding_json
                FROM actions
                WHERE id = ? OR idempotency_key = ?
                """,
                arguments: [request.actionID.rawValue, request.idempotencyKey.rawValue]
            )
            for row in existingRows {
                let actionID: String = row["id"]
                let idempotencyKey: String = row["idempotency_key"]
                let existingBindingData: Data = row["binding_json"]
                guard actionID == request.actionID.rawValue,
                      idempotencyKey == request.idempotencyKey.rawValue,
                      let existingBinding = try? decoder.decode(
                          ActionExecutionBinding.self,
                          from: existingBindingData
                      ),
                      existingBinding == binding
                else { throw ActionAuditError.rejected }

                let existingRequestData: Data? = row["request_json"]
                if let existingRequestData {
                    guard let existingRequest = try? decoder.decode(
                        ActionRequest.self,
                        from: existingRequestData
                    ), existingRequest == request else {
                        throw ActionAuditError.rejected
                    }
                }
            }
            try database.execute(
                sql: """
                INSERT INTO actions (
                    id, idempotency_key, kind, source, target_json,
                    request_json, binding_json, policy_decision, status,
                    result_json, execution_json, evidence_ref, undo_deadline,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL, NULL, NULL, NULL, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    request_json = excluded.request_json,
                    binding_json = excluded.binding_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    request.actionID.rawValue,
                    request.idempotencyKey.rawValue,
                    request.operation.semanticToolName,
                    request.source.rawValue,
                    targetData,
                    requestData,
                    bindingData,
                    "received",
                    request.createdAt,
                    request.createdAt,
                ]
            )

        case let .policyEvaluated(actionID, decision, recordedAt):
            try database.execute(
                sql: """
                UPDATE actions
                SET policy_decision = ?, status = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    AuditEnvelope.policyDescription(decision),
                    AuditEnvelope.policyStatus(decision),
                    recordedAt,
                    actionID.rawValue,
                ]
            )

        case let .humanReviewResolved(actionID, _, resolution, recordedAt):
            try database.execute(
                sql: "UPDATE actions SET status = ?, updated_at = ? WHERE id = ?",
                arguments: ["review_\(resolution.rawValue)", recordedAt, actionID.rawValue]
            )

        case let .executionStarted(actionID, recordedAt):
            try database.execute(
                sql: "UPDATE actions SET status = 'executing', updated_at = ? WHERE id = ?",
                arguments: [recordedAt, actionID.rawValue]
            )

        case let .executionCompleted(result):
            // `ActionResultStore.save` durably writes the terminal envelope
            // before the executor emits this audit event.
            try database.execute(
                sql: "UPDATE actions SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [result.status.rawValue, result.completedAt, result.actionID.rawValue]
            )

        case let .idempotentReplay(actionID, _, recordedAt):
            try database.execute(
                sql: "UPDATE actions SET updated_at = ? WHERE id = ?",
                arguments: [recordedAt, actionID.rawValue]
            )
        }

        guard database.changesCount > 0 else {
            throw ActionAuditError.rejected
        }
    }
}

private struct AuditEnvelope: Codable {
    let eventType: String
    let actionID: String
    let recordedAt: Date
    let request: ActionRequest?
    let policyDecision: String?
    let reviewID: String?
    let reviewResolution: String?
    let idempotencyKey: String?
    let result: ActionResult?

    init(_ event: ActionAuditEvent) {
        switch event {
        case let .requestReceived(value):
            eventType = "request_received"
            actionID = value.actionID.rawValue
            recordedAt = value.createdAt
            request = value
            policyDecision = nil
            reviewID = nil
            reviewResolution = nil
            idempotencyKey = value.idempotencyKey.rawValue
            result = nil
        case let .policyEvaluated(id, decision, date):
            eventType = "policy_evaluated"
            actionID = id.rawValue
            recordedAt = date
            request = nil
            policyDecision = Self.policyDescription(decision)
            reviewID = nil
            reviewResolution = nil
            idempotencyKey = nil
            result = nil
        case let .humanReviewResolved(id, review, resolution, date):
            eventType = "human_review_resolved"
            actionID = id.rawValue
            recordedAt = date
            request = nil
            policyDecision = nil
            reviewID = review.rawValue
            reviewResolution = resolution.rawValue
            idempotencyKey = nil
            result = nil
        case let .executionStarted(id, date):
            eventType = "execution_started"
            actionID = id.rawValue
            recordedAt = date
            request = nil
            policyDecision = nil
            reviewID = nil
            reviewResolution = nil
            idempotencyKey = nil
            result = nil
        case let .executionCompleted(value):
            eventType = "execution_completed"
            actionID = value.actionID.rawValue
            recordedAt = value.completedAt
            request = nil
            policyDecision = nil
            reviewID = nil
            reviewResolution = nil
            idempotencyKey = nil
            result = value
        case let .idempotentReplay(id, key, date):
            eventType = "idempotent_replay"
            actionID = id.rawValue
            recordedAt = date
            request = nil
            policyDecision = nil
            reviewID = nil
            reviewResolution = nil
            idempotencyKey = key.rawValue
            result = nil
        }
    }

    static func policyStatus(_ decision: PolicyDecisionSummary) -> String {
        switch decision {
        case .allowed: "authorized"
        case .humanReviewRequired: "awaiting_review"
        case .denied: "denied"
        }
    }

    static func policyDescription(_ decision: PolicyDecisionSummary) -> String {
        switch decision {
        case let .allowed(ruleID, reviewID):
            return "allowed:rule=\(ruleID?.rawValue ?? "none"):review=\(reviewID?.rawValue ?? "none")"
        case let .humanReviewRequired(reviewID):
            return "human_review_required:\(reviewID.rawValue)"
        case let .denied(reason):
            return "denied:\(String(describing: reason))"
        }
    }
}
