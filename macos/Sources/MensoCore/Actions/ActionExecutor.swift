import Foundation

public enum ActionSubmission: Sendable, Hashable {
    case requiresHumanReview(HumanReviewRequirement)
    case completed(ActionResult)
}

private struct InFlightAction: Sendable {
    let binding: ActionExecutionBinding
    let task: Task<ActionSubmission, Never>
}

/// A single actor-backed queue shared by backend, auto-mode, and voice callers.
/// Actor reentrancy is not used as a serialization guarantee: each task explicitly waits for the prior tail.
public actor ActionExecutor {
    private let policyEngine: PolicyEngine
    private let broker: any SemanticActionBroker
    private let auditSink: any ActionAuditSink
    private let resultStore: any ActionResultStore
    private let secureInput: any SecureInputStateProviding
    private let now: @Sendable () -> Date

    private var queueTail: Task<ActionSubmission, Never>?
    private var inFlight: [IdempotencyKey: InFlightAction] = [:]
    private var terminalCache: [IdempotencyKey: StoredActionExecution] = [:]

    public init(
        policyEngine: PolicyEngine,
        broker: any SemanticActionBroker,
        auditSink: any ActionAuditSink,
        resultStore: any ActionResultStore,
        secureInput: any SecureInputStateProviding,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.policyEngine = policyEngine
        self.broker = broker
        self.auditSink = auditSink
        self.resultStore = resultStore
        self.secureInput = secureInput
        self.now = now
    }

    public func submit(_ request: ActionRequest) async -> ActionSubmission {
        let binding = ActionExecutionBinding(request: request)

        if let cached = terminalCache[request.idempotencyKey] {
            return replay(cached, for: request, binding: binding)
        }

        if let existing = inFlight[request.idempotencyKey] {
            guard existing.binding == binding else {
                return .completed(.failure(for: request, code: .idempotencyConflict))
            }
            return await existing.task.value
        }

        let previous = queueTail
        let task = Task<ActionSubmission, Never> { [weak self] in
            if let previous {
                _ = await previous.value
            }
            guard let self else {
                return .completed(.failure(for: request, status: .cancelled, code: .cancelled))
            }
            return await self.perform(request, binding: binding)
        }

        inFlight[request.idempotencyKey] = InFlightAction(binding: binding, task: task)
        queueTail = task

        let submission = await task.value
        inFlight.removeValue(forKey: request.idempotencyKey)
        return submission
    }

    private func perform(_ request: ActionRequest, binding: ActionExecutionBinding) async -> ActionSubmission {
        do {
            if let stored = try await resultStore.execution(for: request.idempotencyKey) {
                terminalCache[request.idempotencyKey] = stored
                if stored.binding == binding {
                    try? await auditSink.record(
                        .idempotentReplay(
                            actionID: request.actionID,
                            idempotencyKey: request.idempotencyKey,
                            recordedAt: now()
                        )
                    )
                    return .completed(stored.result)
                }
                return .completed(.failure(for: request, code: .idempotencyConflict))
            }
        } catch {
            return .completed(.failure(for: request, code: .persistenceFailure))
        }

        guard request.isStructurallyValid else {
            return await finish(.failure(for: request, code: .invalidRequest), request: request, binding: binding)
        }
        guard request.expiresAt > now() else {
            return await finish(
                .failure(for: request, status: .expired, code: .expired),
                request: request,
                binding: binding
            )
        }

        do {
            try await auditSink.record(.requestReceived(request))
        } catch {
            return await finish(.failure(for: request, code: .auditUnavailable), request: request, binding: binding)
        }

        let decision = await policyEngine.evaluate(request)
        do {
            try await auditSink.record(
                .policyEvaluated(actionID: request.actionID, decision: decision.summary, recordedAt: now())
            )
        } catch {
            return await finish(.failure(for: request, code: .auditUnavailable), request: request, binding: binding)
        }

        switch decision {
        case let .requireHumanReview(requirement):
            return .requiresHumanReview(requirement)
        case let .deny(reason):
            let code: ActionErrorCode = reason == .reviewDenied ? .humanReviewDenied : .policyDenied
            let status: ActionStatus = reason == .expired ? .expired : .denied
            return await finish(.failure(for: request, status: status, code: code), request: request, binding: binding)
        case .allow:
            break
        }

        // Secure input is checked immediately before the audited side-effect boundary.
        guard await secureInput.currentSecureInputState() == .disabled else {
            return await finish(
                .failure(for: request, status: .denied, code: .secureInputActive),
                request: request,
                binding: binding
            )
        }


        let reservation = ActionExecutionReservation(
            idempotencyKey: request.idempotencyKey,
            binding: binding,
            reservedAt: now()
        )
        do {
            switch try await resultStore.reserve(reservation) {
            case .acquired:
                break
            case let .existingTerminal(execution):
                terminalCache[request.idempotencyKey] = execution
                return replay(execution, for: request, binding: binding)
            case .existingReservation:
                let failure = ActionResult.failure(for: request, code: .persistenceFailure)
                terminalCache[request.idempotencyKey] = StoredActionExecution(
                    idempotencyKey: request.idempotencyKey,
                    actionID: request.actionID,
                    binding: binding,
                    result: failure
                )
                return .completed(failure)
            case .conflict:
                return .completed(.failure(for: request, code: .idempotencyConflict))
            }
        } catch {
            return .completed(.failure(for: request, code: .persistenceFailure))
        }

        do {
            try await auditSink.record(.executionStarted(actionID: request.actionID, recordedAt: now()))
        } catch {
            return await finish(.failure(for: request, code: .auditUnavailable), request: request, binding: binding)
        }

        let result: ActionResult
        do {
            try Task.checkCancellation()
            result = try await broker.execute(request)
        } catch is CancellationError {
            result = .failure(for: request, code: .cancelled)
        } catch let error as LocalToolBrokerError {
            result = .failure(for: request, code: Self.errorCode(for: error))
        } catch let error as PinnedEmbeddedCuaDriverHostError {
            result = .failure(for: request, code: error == .toolRejected ? .driverToolRejected : .driverProtocolFailure)
        } catch {
            result = .failure(for: request, code: .unknown)
        }

        guard result.actionID == request.actionID,
              result.target == request.target,
              result.contentHash == request.operation.contentHash
        else {
            return await finish(.failure(for: request, code: .verificationFailed), request: request, binding: binding)
        }

        if [.opened, .focused, .inserted, .activated].contains(result.status),
           !result.verified
        {
            return await finish(.failure(for: request, code: .verificationFailed), request: request, binding: binding)
        }

        return await finish(result, request: request, binding: binding)
    }

    private func finish(
        _ result: ActionResult,
        request: ActionRequest,
        binding: ActionExecutionBinding
    ) async -> ActionSubmission {
        let stored = StoredActionExecution(
            idempotencyKey: request.idempotencyKey,
            actionID: request.actionID,
            binding: binding,
            result: result
        )
        terminalCache[request.idempotencyKey] = stored

        do {
            try await resultStore.save(stored)
        } catch {
            let persistenceFailure = ActionResult.failure(for: request, code: .persistenceFailure)
            let failedStore = StoredActionExecution(
                idempotencyKey: request.idempotencyKey,
                actionID: request.actionID,
                binding: binding,
                result: persistenceFailure
            )
            // Keep the failure terminal in this process; never claim the side effect succeeded without durable truth.
            terminalCache[request.idempotencyKey] = failedStore
            try? await auditSink.record(.executionCompleted(persistenceFailure))
            return .completed(persistenceFailure)
        }

        try? await auditSink.record(.executionCompleted(result))
        return .completed(result)
    }

    private func replay(
        _ stored: StoredActionExecution,
        for request: ActionRequest,
        binding: ActionExecutionBinding
    ) -> ActionSubmission {
        guard stored.binding == binding else {
            return .completed(.failure(for: request, code: .idempotencyConflict))
        }
        return .completed(stored.result)
    }

    private static func errorCode(for error: LocalToolBrokerError) -> ActionErrorCode {
        switch error {
        case .unsupportedOperation: .invalidRequest
        case .targetMismatch: .targetMismatch
        case .contentMismatch: .contentMismatch
        case .verificationFailed: .verificationFailed
        case .driverUnavailable: .transportUnavailable
        case .driverIntegrityFailed: .driverIntegrityFailed
        case .driverPermissionMissing: .driverPermissionMissing
        case .persistenceFailure: .persistenceFailure
        }
    }
}
