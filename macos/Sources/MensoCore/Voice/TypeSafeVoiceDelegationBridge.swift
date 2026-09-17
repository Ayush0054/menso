import Foundation

/// One model selection, one native review, one locally verified result.
/// There are no backend runs, pause envelopes, or model-authored approval states.
public actor TypeSafeVoiceDelegationBridge: MensoVoiceDelegating {
    private let selector: any VoiceActionSelecting
    private let authenticatedContextProvider: any AuthenticatedProductContextProviding
    private let actionContextProvider: any VoiceActionContextProviding
    private let policyEngine: PolicyEngine
    private let executor: ActionExecutor
    private let reviews: RunPauseCoordinator
    private var calls: [String: (AuthenticatedVoiceDelegation, Task<VoiceDelegationResult, Error>)] = [:]

    public init(
        selector: any VoiceActionSelecting,
        authenticatedContextProvider: any AuthenticatedProductContextProviding,
        actionContextProvider: any VoiceActionContextProviding,
        policyEngine: PolicyEngine, executor: ActionExecutor, reviews: RunPauseCoordinator
    ) {
        self.selector = selector
        self.authenticatedContextProvider = authenticatedContextProvider
        self.actionContextProvider = actionContextProvider
        self.policyEngine = policyEngine
        self.executor = executor
        self.reviews = reviews
    }

    public func delegate(_ delegation: AuthenticatedVoiceDelegation) async throws -> VoiceDelegationResult {
        guard delegation.route == .nativeAction else { throw LiveVoiceError.invalidDelegation }
        let key = "\(delegation.userID.rawValue):\(delegation.sessionID.rawValue):\(delegation.request.callID)"
        if let existing = calls[key] {
            guard existing.0 == delegation else { throw LiveVoiceError.invalidDelegation }
            return try await existing.1.value
        }
        // Do not evict a provider call ID and accidentally make it executable again.
        guard calls.count < 512 else {
            return .init(status: .rejected, spokenSummary: "Restart Menso before making more action requests.")
        }
        let work = Task { try await self.perform(delegation) }
        calls[key] = (delegation, work)
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func perform(_ delegation: AuthenticatedVoiceDelegation) async throws -> VoiceDelegationResult {
        let verified = try await authenticatedContextProvider.authenticatedProductContext()
        guard verified.userID == delegation.userID, verified.sessionID == delegation.sessionID else {
            throw AgentOSClientError.authenticatedIdentityMismatch
        }
        let context = await actionContextProvider.contextForRequest()
        guard context.accessibilityGranted else {
            return .init(status: .rejected,
                         spokenSummary: "Enable Mac control in Menso and allow Accessibility, then ask again.")
        }
        let catalog = NativeVoiceActionCatalog(context: context, utterance: delegation.request.task)
        let selection = try await selector.select(
            utterance: delegation.request.task, candidates: catalog.entries.map(\.candidate), userID: verified.userID
        )
        try Task.checkCancellation()
        switch selection.status {
        case .unclear:
            return .init(status: .rejected,
                         spokenSummary: "Please name the app or focused control and ask for one exact action.")
        case .unsupported:
            return .init(status: .rejected,
                         spokenSummary: "I can open an app, focus a known window, insert exact dictated text, or change a focused control's state. Ask for one of those actions.")
        case .selected: break
        }
        guard let entry = catalog.entries.first(where: { $0.candidate.id == selection.candidateID }),
              context.permits(entry.authority) else { throw LiveVoiceError.invalidDelegation }
        let action = ActionRequest(
            idempotencyKey: IdempotencyKey(rawValue: "voice-typesafe:\(UUID().uuidString.lowercased())"),
            userID: verified.userID, sessionID: verified.sessionID, source: .nativeVoice,
            target: entry.authority.target, operation: entry.authority.operation,
            capability: ActionCapabilityBinding(expectedToolName: entry.authority.operation.semanticToolName),
            expiresAt: Date().addingTimeInterval(180)
        )
        await policyEngine.requireReviewForBoundRequest(action)
        let result: ActionResult
        switch await executor.submit(action) {
        case let .completed(value): result = value
        case let .requiresHumanReview(requirement):
            result = try await review(action, requirement: requirement, entry: entry)
        }
        // Never translate a model choice, approval click, or unverified receipt into success.
        guard result.actionID == action.actionID, result.target == action.target,
              result.contentHash == action.operation.contentHash else { throw LiveVoiceError.invalidDelegation }
        if result.verified, [.opened, .focused, .inserted, .activated].contains(result.status) {
            return .init(status: .completed, spokenSummary: "Completed and verified: \(entry.title).",
                         actionReceipts: [try ExternalExecutionWireResult(actionResult: result)])
        }
        switch result.status {
        case .denied:
            return .init(status: .rejected, spokenSummary: result.errorCode == .humanReviewDenied
                         ? "The action was declined. Nothing was executed."
                         : "Local policy or secure input blocked the action. Nothing was executed.")
        case .expired: return .init(status: .rejected, spokenSummary: "The action expired. Ask again if you still want it.")
        default:
            return .init(status: .rejected,
                         spokenSummary: "The Mac could not verify that action. Check the target app before retrying.")
        }
    }

    private func review(
        _ request: ActionRequest, requirement: HumanReviewRequirement, entry: NativeVoiceActionCatalog.Entry
    ) async throws -> ActionResult {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncStream<ActionResult>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let executor = self.executor
        let reviews = self.reviews
        let identityProvider = authenticatedContextProvider
        let complete: @Sendable (HumanReviewID) async -> Void = { _ in
            defer { continuation.finish() }
            // Recheck identity after the human may have spent minutes reviewing.
            guard let current = try? await identityProvider.authenticatedProductContext(),
                  current.userID == request.userID, current.sessionID == request.sessionID else {
                continuation.yield(.failure(for: request, code: .policyDenied))
                return
            }
            switch await executor.submit(request) {
            case let .completed(result): continuation.yield(result)
            case .requiresHumanReview:
                continuation.yield(.failure(for: request, code: .humanReviewDenied))
            }
        }
        try await reviews.registerLocalReview(
            requirement,
            summary: PendingActionSummary(
                id: request.actionID.rawValue, title: entry.title, detail: entry.detail,
                sourceLabel: "Voice", expiresAt: requirement.expiresAt, canCreateAlwaysRule: false
            ), approve: complete, deny: complete
        )
        let expiry = Task {
            do { try await Task.sleep(for: .seconds(max(0, requirement.expiresAt.timeIntervalSinceNow))) }
            catch { return }
            try? await reviews.resolve(actionID: request.actionID, resolution: .deny)
        }
        defer { expiry.cancel() }
        return try await withTaskCancellationHandler {
            for await result in stream { return result }
            throw CancellationError()
        } onCancel: {
            continuation.finish()
            Task { try? await reviews.resolve(actionID: request.actionID, resolution: .deny) }
        }
    }
}
