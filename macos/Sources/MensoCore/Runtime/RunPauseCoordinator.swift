import Foundation

public enum AgentOSRunStreamOrigin: Sendable, Hashable {
    case startedAgent(TrustedAgentRunStart)
    case startedWorkflow(TrustedWorkflowRunStart)
    case continuedAgent(
        agentID: String,
        runID: String,
        authenticatedUserID: UserID,
        authenticatedSessionID: ProductSessionID
    )
    case continuedWorkflow(
        workflowID: String,
        runID: String,
        authenticatedUserID: UserID,
        authenticatedSessionID: ProductSessionID
    )
}

public protocol AgentOSRunStreamHandling: Sendable {
    func handle(_ stream: AgentOSEventStream, origin: AgentOSRunStreamOrigin) async throws
}

/// Endpoint-specific dispatch stays distinct even though Menso's generic CUA
/// Toolkit currently executes only direct Agent pauses.
public protocol RunContinuationDispatching: Sendable {
    func dispatch(_ continuation: AgentRunContinuation) async throws
    func dispatch(_ continuation: WorkflowRunContinuation) async throws
}

public struct AgentExternalExecutionPause: Sendable, Hashable {
    public let continuation: AgentRunContinuation
    public let toolCallID: String
    public let expectedToolName: String
    public let authenticatedUserID: UserID
    public let authenticatedSessionID: ProductSessionID
    public let expectedTarget: ActionTarget
    public let expectedOperation: ActionOperation
    public let expiresAt: Date

    public init(
        continuation: AgentRunContinuation,
        toolCallID: String,
        expectedToolName: String,
        authenticatedUserID: UserID,
        authenticatedSessionID: ProductSessionID,
        expectedTarget: ActionTarget,
        expectedOperation: ActionOperation,
        expiresAt: Date
    ) {
        self.continuation = continuation
        self.toolCallID = toolCallID
        self.expectedToolName = expectedToolName
        self.authenticatedUserID = authenticatedUserID
        self.authenticatedSessionID = authenticatedSessionID
        self.expectedTarget = expectedTarget
        self.expectedOperation = expectedOperation
        self.expiresAt = expiresAt
    }
}

public struct RuntimeNotice: Identifiable, Sendable, Hashable {
    public enum Severity: String, Sendable, Hashable {
        case information
        case warning
        case error
    }

    public let id: UUID
    public let severity: Severity
    public let message: String
    public let occurredAt: Date

    public init(
        id: UUID = UUID(),
        severity: Severity,
        message: String,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.occurredAt = occurredAt
    }
}

public enum RunPauseCoordinatorError: Error, Sendable, Equatable {
    case continuationDispatcherUnavailable
    case authenticatedIdentityMismatch
    case pendingReviewNotFound
    case reviewBindingMismatch
}

private struct AgentContinuationRoute: Codable, Sendable, Hashable {
    let continuation: AgentRunContinuation
    let toolCallID: String
    let expectedToolName: String
}

private enum PendingReviewContext: Sendable {
    case agent(request: ActionRequest, route: AgentContinuationRoute)
    case local(
        reviewID: HumanReviewID,
        approve: @Sendable (HumanReviewID) async -> Void,
        deny: @Sendable (HumanReviewID) async -> Void
    )
}

private struct PendingReviewEntry: Sendable {
    let requirement: HumanReviewRequirement
    let summary: PendingActionSummary
    let context: PendingReviewContext
}

/// Sole bridge from an authenticated Agent external-execution pause to Swift
/// policy, local semantic execution, durable continuation, and UI review.
public actor RunPauseCoordinator {
    private let policyEngine: PolicyEngine
    private let actionExecutor: ActionExecutor
    private let pendingReviewStore: (any PendingRunReviewPersisting)?
    private let continuationDispatcher: (any RunContinuationDispatching)?
    private let requestFactory: ExternalActionRequestFactory
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var pendingReviews: [ActionID: PendingReviewEntry] = [:]
    private var pendingResolvedContinuations: [ActionID: AgentRunContinuation] = [:]
    private var resolutionsInFlight: Set<ActionID> = []
    private var restored = false

    private var pendingContinuations: [
        UUID: AsyncStream<[PendingActionSummary]>.Continuation
    ] = [:]
    private var noticeContinuations: [UUID: AsyncStream<RuntimeNotice>.Continuation] = [:]

    public init(
        policyEngine: PolicyEngine,
        actionExecutor: ActionExecutor,
        auditSink _: any ActionAuditSink,
        pendingReviewStore: (any PendingRunReviewPersisting)? = nil,
        continuationDispatcher: (any RunContinuationDispatching)? = nil,
        requestFactory: ExternalActionRequestFactory = ExternalActionRequestFactory(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.policyEngine = policyEngine
        self.actionExecutor = actionExecutor
        self.pendingReviewStore = pendingReviewStore
        self.continuationDispatcher = continuationDispatcher
        self.requestFactory = requestFactory
        self.now = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func pendingActionUpdates(
        bufferLimit: Int = 16
    ) -> AsyncStream<[PendingActionSummary]> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: [PendingActionSummary].self,
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
        )
        pendingContinuations[id] = pair.continuation
        pair.continuation.yield(allPendingSummaries())
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removePendingSubscriber(id) }
        }
        return pair.stream
    }

    public func notices(bufferLimit: Int = 32) -> AsyncStream<RuntimeNotice> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: RuntimeNotice.self,
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
        )
        noticeContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeNoticeSubscriber(id) }
        }
        return pair.stream
    }

    /// Only a durable, unresolved review for this authenticated run can back
    /// a voice claim that Approve/Decline is available. Model JSON is not proof.
    public func hasPendingAgentReview(
        agentID: String,
        runID: String,
        userID: UserID,
        sessionID: ProductSessionID
    ) -> Bool {
        pendingReviews.contains { actionID, entry in
            guard !resolutionsInFlight.contains(actionID),
                  pendingResolvedContinuations[actionID] == nil,
                  entry.requirement.expiresAt > now(),
                  case let .agent(_, route) = entry.context
            else { return false }
            return route.continuation.agentID == agentID
                && route.continuation.runID == runID
                && route.continuation.userID == userID
                && route.continuation.sessionID == sessionID
        }
    }

    public func restorePendingReviews(limit: Int = 512) async {
        guard !restored else { return }
        restored = true
        guard let pendingReviewStore else { return }
        do {
            for stored in try await pendingReviewStore.pendingRunReviews(
                at: now(),
                limit: limit
            ) {
                guard stored.hasValidIntegrity else { continue }
                let requirement = try decoder.decode(
                    HumanReviewRequirement.self,
                    from: stored.requirementJSON
                )
                let request = try decoder.decode(ActionRequest.self, from: stored.requestJSON)
                let route = try decoder.decode(AgentContinuationRoute.self, from: stored.contextJSON)
                guard requirement.actionID == stored.actionID,
                      requirement.matches(request),
                      request.expiresAt > now()
                else { continue }

                let summary = Self.summary(requirement: requirement, request: request)
                pendingReviews[stored.actionID] = PendingReviewEntry(
                    requirement: requirement,
                    summary: summary,
                    context: .agent(request: request, route: route)
                )
                if let resolved = stored.resolvedContextJSON {
                    pendingResolvedContinuations[stored.actionID] = try decoder.decode(
                        AgentRunContinuation.self,
                        from: resolved
                    )
                } else {
                    _ = await policyEngine.restoreHumanReview(
                        request: request,
                        requirement: requirement
                    )
                }
            }
            publishPendingActions()
        } catch {
            publishNotice(.init(
                severity: .error,
                message: "Saved desktop-action reviews could not be restored safely."
            ))
        }
    }

    public func ingest(_ pause: AgentExternalExecutionPause) async throws {
        guard pause.continuation.userID == pause.authenticatedUserID,
              pause.continuation.sessionID == pause.authenticatedSessionID
        else { throw RunPauseCoordinatorError.authenticatedIdentityMismatch }
        let request = try requestFactory.makeAgentActionRequest(
            continuation: pause.continuation,
            toolCallID: pause.toolCallID,
            expectedToolName: pause.expectedToolName,
            authenticatedUserID: pause.authenticatedUserID,
            authenticatedSessionID: pause.authenticatedSessionID,
            trustedExpectedTarget: pause.expectedTarget,
            trustedExpectedOperation: pause.expectedOperation,
            trustedExpiresAt: pause.expiresAt,
            now: now()
        )
        await policyEngine.requireReviewForBoundRequest(request)
        _ = await submit(
            request,
            route: AgentContinuationRoute(
                continuation: pause.continuation,
                toolCallID: pause.toolCallID,
                expectedToolName: pause.expectedToolName
            )
        )
    }

    public func registerLocalReview(
        _ requirement: HumanReviewRequirement,
        summary: PendingActionSummary,
        approve: @escaping @Sendable (HumanReviewID) async -> Void,
        deny: @escaping @Sendable (HumanReviewID) async -> Void
    ) throws {
        guard summary.id == requirement.actionID.rawValue else {
            throw RunPauseCoordinatorError.reviewBindingMismatch
        }
        pendingReviews[requirement.actionID] = PendingReviewEntry(
            requirement: requirement,
            summary: summary,
            context: .local(reviewID: requirement.id, approve: approve, deny: deny)
        )
        publishPendingActions()
    }

    public func resolve(
        actionID: ActionID,
        resolution: HumanReviewResolution
    ) async throws {
        guard !resolutionsInFlight.contains(actionID) else {
            throw RunPauseCoordinatorError.reviewBindingMismatch
        }
        resolutionsInFlight.insert(actionID)
        defer { resolutionsInFlight.remove(actionID) }

        if let continuation = pendingResolvedContinuations[actionID] {
            try await dispatch(continuation)
            pendingResolvedContinuations.removeValue(forKey: actionID)
            pendingReviews.removeValue(forKey: actionID)
            try? await pendingReviewStore?.deletePendingRunReview(actionID: actionID)
            publishPendingActions()
            return
        }

        guard let entry = pendingReviews[actionID] else {
            throw RunPauseCoordinatorError.pendingReviewNotFound
        }
        _ = await policyEngine.resolveHumanReview(
            id: entry.requirement.id,
            resolution: resolution
        )
        switch entry.context {
        case let .local(reviewID, approve, deny):
            pendingReviews.removeValue(forKey: actionID)
            publishPendingActions()
            switch resolution {
            case .approveOnce, .alwaysAllow: await approve(reviewID)
            case .deny: await deny(reviewID)
            }
        case let .agent(request, route):
            _ = await submit(request, route: route)
        }
    }

    private func submit(
        _ request: ActionRequest,
        route: AgentContinuationRoute
    ) async -> Bool {
        switch await actionExecutor.submit(request) {
        case let .requiresHumanReview(requirement):
            let summary = Self.summary(requirement: requirement, request: request)
            let entry = PendingReviewEntry(
                requirement: requirement,
                summary: summary,
                context: .agent(request: request, route: route)
            )
            guard await persistReview(entry, request: request, route: route) else {
                publishNotice(.init(
                    severity: .error,
                    message: "The desktop-action review could not be saved; execution remains blocked."
                ))
                return false
            }
            pendingReviews[request.actionID] = entry
            publishPendingActions()
            return false

        case let .completed(result):
            do {
                let resolved = try route.continuation.resolving(
                    toolCallID: route.toolCallID,
                    expectedToolName: route.expectedToolName,
                    with: result
                )
                if pendingReviews[request.actionID] != nil {
                    try await pendingReviewStore?.markPendingRunReviewResolved(
                        actionID: request.actionID,
                        resolvedContextJSON: try encoder.encode(resolved),
                        at: now()
                    )
                }
                do {
                    try await dispatch(resolved)
                    pendingResolvedContinuations.removeValue(forKey: request.actionID)
                    pendingReviews.removeValue(forKey: request.actionID)
                    try? await pendingReviewStore?.deletePendingRunReview(actionID: request.actionID)
                    publishPendingActions()
                    return true
                } catch {
                    pendingResolvedContinuations[request.actionID] = resolved
                    publishNotice(.init(
                        severity: .error,
                        message: "The verified result is saved, but its AgentOS continuation needs retry."
                    ))
                    publishPendingActions()
                    return false
                }
            } catch {
                publishNotice(.init(
                    severity: .error,
                    message: "The exact Agent continuation could not be constructed."
                ))
                return false
            }
        }
    }

    private func dispatch(_ continuation: AgentRunContinuation) async throws {
        guard let continuationDispatcher else {
            throw RunPauseCoordinatorError.continuationDispatcherUnavailable
        }
        try await continuationDispatcher.dispatch(continuation)
    }

    private func persistReview(
        _ entry: PendingReviewEntry,
        request: ActionRequest,
        route: AgentContinuationRoute
    ) async -> Bool {
        guard let pendingReviewStore else { return true }
        do {
            try await pendingReviewStore.savePendingRunReview(
                StoredPendingRunReview(
                    actionID: request.actionID,
                    requirementJSON: try encoder.encode(entry.requirement),
                    requestJSON: try encoder.encode(request),
                    contextJSON: try encoder.encode(route),
                    createdAt: now(),
                    expiresAt: entry.requirement.expiresAt
                )
            )
            return true
        } catch { return false }
    }

    private func allPendingSummaries() -> [PendingActionSummary] {
        pendingReviews.values.map(\.summary)
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    private func publishPendingActions() {
        let value = allPendingSummaries()
        for continuation in pendingContinuations.values { continuation.yield(value) }
    }

    private func publishNotice(_ notice: RuntimeNotice) {
        for continuation in noticeContinuations.values { continuation.yield(notice) }
    }

    private func removePendingSubscriber(_ id: UUID) {
        pendingContinuations.removeValue(forKey: id)
    }

    private func removeNoticeSubscriber(_ id: UUID) {
        noticeContinuations.removeValue(forKey: id)
    }

    private static func summary(
        requirement: HumanReviewRequirement,
        request: ActionRequest
    ) -> PendingActionSummary {
        let target: String
        switch request.target {
        case let .focusedApplication(value):
            target = [value.bundleIdentifier, value.windowTitle, value.elementLabel]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        let title: String
        let detail: String
        switch request.operation {
        case let .application(operation):
            title = "Allow \(operation.kind.rawValue.replacingOccurrences(of: "_", with: " "))"
            detail = operation.text.map { "Insert \($0.count) characters into the exact target." }
                ?? operation.expectedState.map { "Require observed state: \($0)" }
                ?? "Perform this exact semantic desktop action."
        case let .insertDictationText(operation):
            title = "Insert dictated text"
            detail = "Insert \(operation.text.count) characters into the exact focused field."
        }
        return PendingActionSummary(
            id: requirement.actionID.rawValue,
            title: title,
            detail: detail,
            sourceLabel: request.source.rawValue,
            targetLabel: target,
            expiresAt: requirement.expiresAt,
            canCreateAlwaysRule: true
        )
    }
}
