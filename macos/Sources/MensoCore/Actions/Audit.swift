import Foundation

public enum ActionAuditEvent: Sendable, Hashable {
    case requestReceived(ActionRequest)
    case policyEvaluated(actionID: ActionID, decision: PolicyDecisionSummary, recordedAt: Date)
    case humanReviewResolved(
        actionID: ActionID,
        reviewID: HumanReviewID,
        resolution: HumanReviewResolution,
        recordedAt: Date
    )
    case executionStarted(actionID: ActionID, recordedAt: Date)
    case executionCompleted(ActionResult)
    case idempotentReplay(actionID: ActionID, idempotencyKey: IdempotencyKey, recordedAt: Date)
}

/// Production implementations persist to the on-device audit database before a side effect begins.
public protocol ActionAuditSink: Sendable {
    func record(_ event: ActionAuditEvent) async throws
}

public enum ActionAuditError: Error, Sendable, Equatable {
    case unavailable
    case rejected
}

public actor InMemoryActionAuditSink: ActionAuditSink {
    private var events: [ActionAuditEvent] = []

    public init() {}

    public func record(_ event: ActionAuditEvent) async throws {
        events.append(event)
    }

    public func allEvents() -> [ActionAuditEvent] {
        events
    }
}

public protocol ActionResultStore: Sendable {
    func execution(for idempotencyKey: IdempotencyKey) async throws -> StoredActionExecution?
    func execution(for actionID: ActionID) async throws -> StoredActionExecution?
    /// Must atomically insert the reservation or return the existing state.
    func reserve(_ reservation: ActionExecutionReservation) async throws -> ActionReservationOutcome
    func save(_ execution: StoredActionExecution) async throws
}

public struct ActionExecutionReservation: Codable, Hashable, Sendable {
    public let idempotencyKey: IdempotencyKey
    public let binding: ActionExecutionBinding
    public let reservedAt: Date

    public init(idempotencyKey: IdempotencyKey, binding: ActionExecutionBinding, reservedAt: Date) {
        self.idempotencyKey = idempotencyKey
        self.binding = binding
        self.reservedAt = reservedAt
    }
}

public enum ActionReservationOutcome: Sendable, Hashable {
    case acquired
    case existingTerminal(StoredActionExecution)
    /// A prior process may have crossed the side-effect boundary. Never execute it automatically again.
    case existingReservation(ActionExecutionReservation)
    case conflict
}

public struct StoredActionExecution: Codable, Hashable, Sendable {
    public let idempotencyKey: IdempotencyKey
    public let actionID: ActionID
    public let binding: ActionExecutionBinding
    public let result: ActionResult

    public init(
        idempotencyKey: IdempotencyKey,
        actionID: ActionID,
        binding: ActionExecutionBinding,
        result: ActionResult
    ) {
        self.idempotencyKey = idempotencyKey
        self.actionID = actionID
        self.binding = binding
        self.result = result
    }
}

public struct ActionExecutionBinding: Codable, Hashable, Sendable {
    public let actionID: ActionID
    public let idempotencyKey: IdempotencyKey
    public let userID: UserID
    public let sessionID: ProductSessionID
    public let source: ActionSource
    public let target: ActionTarget
    public let operation: ActionOperation
    public let capability: ActionCapabilityBinding

    public init(request: ActionRequest) {
        self.actionID = request.actionID
        self.idempotencyKey = request.idempotencyKey
        self.userID = request.userID
        self.sessionID = request.sessionID
        self.source = request.source
        self.target = request.target
        self.operation = request.operation
        self.capability = request.capability
    }

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case idempotencyKey = "idempotency_key"
        case userID = "user_id"
        case sessionID = "session_id"
        case source
        case target
        case operation
        case capability
    }
}

public actor InMemoryActionResultStore: ActionResultStore {
    private var executions: [IdempotencyKey: StoredActionExecution] = [:]
    private var reservations: [IdempotencyKey: ActionExecutionReservation] = [:]

    public init() {}

    public func execution(for idempotencyKey: IdempotencyKey) async throws -> StoredActionExecution? {
        executions[idempotencyKey]
    }

    public func execution(for actionID: ActionID) async throws -> StoredActionExecution? {
        executions.values.first { $0.actionID == actionID }
    }

    public func reserve(_ reservation: ActionExecutionReservation) async throws -> ActionReservationOutcome {
        if let execution = executions[reservation.idempotencyKey] {
            return execution.binding == reservation.binding ? .existingTerminal(execution) : .conflict
        }
        if let existing = reservations[reservation.idempotencyKey] {
            return existing.binding == reservation.binding ? .existingReservation(existing) : .conflict
        }
        reservations[reservation.idempotencyKey] = reservation
        return .acquired
    }

    public func save(_ execution: StoredActionExecution) async throws {
        if let reservation = reservations[execution.idempotencyKey], reservation.binding != execution.binding {
            throw ActionAuditError.rejected
        }
        executions[execution.idempotencyKey] = execution
        reservations.removeValue(forKey: execution.idempotencyKey)
    }
}
