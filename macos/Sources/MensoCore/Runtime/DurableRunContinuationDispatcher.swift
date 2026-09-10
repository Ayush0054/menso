import Foundation

public struct RunContinuationDeliveryUpdate: Sendable, Hashable {
    public let continuationID: String
    public let endpointKind: RunContinuationEndpointKind
    public let executorID: String
    public let runID: String
    public let state: RunContinuationDeliveryState
    public let attemptCount: Int
    public let occurredAt: Date

    public init(
        continuationID: String,
        endpointKind: RunContinuationEndpointKind,
        executorID: String,
        runID: String,
        state: RunContinuationDeliveryState,
        attemptCount: Int,
        occurredAt: Date
    ) {
        self.continuationID = continuationID
        self.endpointKind = endpointKind
        self.executorID = executorID
        self.runID = runID
        self.state = state
        self.attemptCount = attemptCount
        self.occurredAt = occurredAt
    }
}

/// Transactional outbox around endpoint-specific AgentOS continuation calls.
/// `dispatch` throws only when the exact payload could not be made durable.
/// Once enqueued, transient delivery failures are retained for bounded retry.
/// The outbox carries a stable `delivery_nonce` for a future idempotent AgentOS
/// proxy. Pinned direct continue endpoints do not consume it, so the unavoidable
/// cross-process accept/commit crash window is at-least-once; in-process retries
/// suppress every continuation known to have been accepted.
public actor DurableAgentOSRunContinuationDispatcher: RunContinuationDispatching {
    private let client: any AgentOSRunClient
    private let outbox: any RunContinuationOutboxPersisting
    private let streamHandler: any AgentOSRunStreamHandling
    private let now: @Sendable () -> Date
    private let retryIntervalNanoseconds: UInt64
    private let maximumAttempts: Int
    private let batchLimit: Int

    private var inFlight: Set<String> = []
    /// Requests for which the authenticated AgentOS endpoint has already
    /// returned 2xx but the local terminal write failed. These entries may
    /// retry only that local write while this process is alive; sending their
    /// network request again would duplicate an accepted continuation.
    private var acceptedAwaitingMark: [String: Date] = [:]
    private var retryTask: Task<Void, Never>?
    private var updateContinuations: [
        UUID: AsyncStream<RunContinuationDeliveryUpdate>.Continuation
    ] = [:]

    public init(
        client: any AgentOSRunClient,
        streamHandler: any AgentOSRunStreamHandling,
        outbox: any RunContinuationOutboxPersisting,
        retryInterval: TimeInterval = 15,
        maximumAttempts: Int = 64,
        batchLimit: Int = 16,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.outbox = outbox
        self.streamHandler = streamHandler
        self.retryIntervalNanoseconds = UInt64(
            min(max(retryInterval, 1), 300) * 1_000_000_000
        )
        self.maximumAttempts = min(max(maximumAttempts, 1), 128)
        self.batchLimit = min(max(batchLimit, 1), 64)
        self.now = now
    }

    public func dispatch(_ continuation: AgentRunContinuation) async throws {
        _ = try await dispatchWithOutcome(continuation)
    }

    /// Typed product updates for terminal and user-actionable outbox state. The
    /// continuation payload is intentionally not exposed to presentation code.
    public func deliveryUpdates(
        bufferLimit: Int = 32
    ) async -> AsyncStream<RunContinuationDeliveryUpdate> {
        let identifier = UUID()
        let pair = AsyncStream.makeStream(
            of: RunContinuationDeliveryUpdate.self,
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
        )
        updateContinuations[identifier] = pair.continuation
        if let exhausted = try? await outbox.continuations(
            deliveryState: .exhausted,
            limit: min(max(bufferLimit, 1), 1_000)
        ) {
            for entry in exhausted {
                pair.continuation.yield(
                    update(for: entry, state: .exhausted, attemptCount: entry.attemptCount)
                )
            }
        }
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeUpdateContinuation(identifier) }
        }
        return pair.stream
    }

    public func dispatchWithOutcome(
        _ continuation: AgentRunContinuation
    ) async throws -> RunContinuationDeliveryOutcome {
        let entry = try RunContinuationOutboxEntry.agent(continuation, createdAt: now())
        switch try await outbox.enqueue(entry) {
        case .alreadyDelivered:
            return .accepted
        case let .pending(persisted):
            await attemptDelivery(persisted)
            return try await outcome(for: persisted.id)
        }
    }

    public func dispatch(_ continuation: WorkflowRunContinuation) async throws {
        _ = try await dispatchWithOutcome(continuation)
    }

    public func dispatchWithOutcome(
        _ continuation: WorkflowRunContinuation
    ) async throws -> RunContinuationDeliveryOutcome {
        let entry = try RunContinuationOutboxEntry.workflow(continuation, createdAt: now())
        switch try await outbox.enqueue(entry) {
        case .alreadyDelivered:
            return .accepted
        case let .pending(persisted):
            await attemptDelivery(persisted)
            return try await outcome(for: persisted.id)
        }
    }

    /// Starts with an immediate bounded replay, then polls the due index. Only
    /// persisted continuations are retried; local semantic actions are never
    /// submitted from this worker.
    public func startRetrying() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            guard let self else { return }
            await self.retryDueContinuations()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: await self.retryDelayNanoseconds())
                } catch {
                    return
                }
                await self.retryDueContinuations()
            }
        }
    }

    public func stop() async {
        retryTask?.cancel()
        retryTask = nil
    }

    public func retryDueContinuations() async {
        await finishAcceptedMarks()

        let entries: [RunContinuationOutboxEntry]
        do {
            entries = try await outbox.dueContinuations(at: now(), limit: batchLimit)
        } catch {
            return
        }
        for entry in entries where !Task.isCancelled {
            await attemptDelivery(entry)
        }
    }

    /// Explicit user retry after a bounded worker has exhausted its attempts.
    /// This resets only the exact persisted envelope, never its local action.
    public func retryContinuation(id: String) async throws {
        try await outbox.retryContinuation(id: id, at: now())
        guard let entry = try await outbox.continuation(id: id),
              entry.deliveryState == .pending,
              entry.attemptCount == 0
        else { throw RunContinuationOutboxError.conflictingRecord }
        publishUpdate(for: entry, state: .pending, attemptCount: 0)
        await attemptDelivery(entry)
    }

    public func retry(
        _ continuation: AgentRunContinuation
    ) async throws -> RunContinuationDeliveryOutcome {
        let entry = try RunContinuationOutboxEntry.agent(continuation, createdAt: now())
        switch try await outbox.deliveryState(id: entry.id) {
        case .exhausted:
            try await retryContinuation(id: entry.id)
        case .delivered:
            return .accepted
        case .pending, nil:
            break
        }
        switch try await outbox.enqueue(entry) {
        case .alreadyDelivered:
            return .accepted
        case let .pending(persisted):
            await attemptDelivery(persisted)
            return try await outcome(for: persisted.id)
        }
    }

    public func retry(
        _ continuation: WorkflowRunContinuation
    ) async throws -> RunContinuationDeliveryOutcome {
        let entry = try RunContinuationOutboxEntry.workflow(continuation, createdAt: now())
        switch try await outbox.deliveryState(id: entry.id) {
        case .exhausted:
            try await retryContinuation(id: entry.id)
        case .delivered:
            return .accepted
        case .pending, nil:
            break
        }
        switch try await outbox.enqueue(entry) {
        case .alreadyDelivered:
            return .accepted
        case let .pending(persisted):
            await attemptDelivery(persisted)
            return try await outcome(for: persisted.id)
        }
    }

    private func attemptDelivery(_ entry: RunContinuationOutboxEntry) async {
        guard entry.deliveryState == .pending,
              entry.attemptCount < maximumAttempts,
              acceptedAwaitingMark[entry.id] == nil,
              !inFlight.contains(entry.id)
        else { return }

        inFlight.insert(entry.id)
        defer { inFlight.remove(entry.id) }

        var accepted = false
        do {
            let stream: AgentOSEventStream
            let origin: AgentOSRunStreamOrigin
            switch entry.endpointKind {
            case .agent:
                let continuation = try entry.agentContinuation()
                stream = try await client.continueAgentRun(continuation)
                origin = .continuedAgent(
                    agentID: continuation.agentID,
                    runID: continuation.runID,
                    authenticatedUserID: continuation.userID,
                    authenticatedSessionID: continuation.sessionID
                )
            case .workflow:
                let continuation = try entry.workflowContinuation()
                stream = try await client.continueWorkflowRun(continuation)
                origin = .continuedWorkflow(
                    workflowID: continuation.workflowID,
                    runID: continuation.runID,
                    authenticatedUserID: continuation.userID,
                    authenticatedSessionID: continuation.sessionID
                )
            }

            // The authenticated continuation POST has returned 2xx. Mark the
            // exact envelope terminal before consuming its response stream so
            // actor re-entry cannot resend an already-accepted request.
            let acceptedAt = now()
            accepted = true
            acceptedAwaitingMark[entry.id] = acceptedAt
            do {
                try await outbox.markContinuationDelivered(id: entry.id, deliveredAt: acceptedAt)
                acceptedAwaitingMark.removeValue(forKey: entry.id)
                publishUpdate(
                    for: entry,
                    state: .delivered,
                    attemptCount: entry.attemptCount
                )
            } catch {
                // The network request is already accepted. Keep consuming its
                // handed-off stream and let the periodic worker retry only the
                // local terminal write.
            }
            try await streamHandler.handle(stream, origin: origin)
        } catch {
            guard !accepted else {
                // The POST is terminal in the outbox. A later SSE parse/handler
                // failure must never resend the accepted continuation.
                return
            }
            let attempts = entry.attemptCount + 1
            let exhausted = attempts >= maximumAttempts
            let delay = min(pow(2, Double(min(attempts, 8))), 300)
            do {
                try await outbox.recordContinuationFailure(
                    id: entry.id,
                    attemptCount: attempts,
                    nextAttemptAt: now().addingTimeInterval(delay),
                    exhausted: exhausted
                )
                if exhausted {
                    publishUpdate(for: entry, state: .exhausted, attemptCount: attempts)
                }
            } catch {
                // Do not present an exhausted state that is not durable.
            }
        }
    }

    /// Finishes only the local half of an already-accepted delivery. The
    /// response stream cannot safely be reconstructed, but the continuation
    /// request itself must not be sent again within this process.
    private func finishAcceptedMarks() async {
        let pendingMarks = acceptedAwaitingMark
        for (id, acceptedAt) in pendingMarks where !Task.isCancelled {
            do {
                try await outbox.markContinuationDelivered(id: id, deliveredAt: acceptedAt)
                acceptedAwaitingMark.removeValue(forKey: id)
                if let entry = try await outbox.continuation(id: id) {
                    publishUpdate(
                        for: entry,
                        state: .delivered,
                        attemptCount: entry.attemptCount
                    )
                }
            } catch {
                continue
            }
        }
    }

    private func retryDelayNanoseconds() -> UInt64 {
        retryIntervalNanoseconds
    }

    private func outcome(for id: String) async throws -> RunContinuationDeliveryOutcome {
        switch try await outbox.deliveryState(id: id) {
        case .delivered: .accepted
        case .pending: .deferred
        case .exhausted: .exhausted
        case nil: throw RunContinuationOutboxError.conflictingRecord
        }
    }

    private func publishUpdate(
        for entry: RunContinuationOutboxEntry,
        state: RunContinuationDeliveryState,
        attemptCount: Int
    ) {
        let update = update(for: entry, state: state, attemptCount: attemptCount)
        for continuation in updateContinuations.values {
            continuation.yield(update)
        }
    }

    private func update(
        for entry: RunContinuationOutboxEntry,
        state: RunContinuationDeliveryState,
        attemptCount: Int
    ) -> RunContinuationDeliveryUpdate {
        RunContinuationDeliveryUpdate(
            continuationID: entry.id,
            endpointKind: entry.endpointKind,
            executorID: entry.executorID,
            runID: entry.runID,
            state: state,
            attemptCount: attemptCount,
            occurredAt: now()
        )
    }

    private func removeUpdateContinuation(_ identifier: UUID) {
        updateContinuations.removeValue(forKey: identifier)
    }
}
