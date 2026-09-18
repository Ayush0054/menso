import Foundation

/// Bounded observe/select/execute/verify loop, owned by the signed Mac.
/// There are no backend runs, pause envelopes, or model-authored approval states.
public actor TypeSafeVoiceDelegationBridge: MensoVoiceDelegating {
    private let selector: any VoiceActionSelecting
    private let authenticatedContextProvider: any AuthenticatedProductContextProviding
    private let actionContextProvider: any VoiceActionContextProviding
    private let policyEngine: PolicyEngine
    private let executor: ActionExecutor
    private let reviews: RunPauseCoordinator
    private var calls: [String: (AuthenticatedVoiceDelegation, Task<VoiceDelegationResult, Error>)] = [:]
    private var taskRunning = false

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
        guard !taskRunning else {
            return .init(status: .rejected, spokenSummary: "A Mac task is still running. Stop it before starting another.")
        }
        // Do not evict a provider call ID and accidentally make it executable again.
        guard calls.count < 512 else {
            return .init(status: .rejected, spokenSummary: "Restart Menso before making more action requests.")
        }
        taskRunning = true
        let work = Task {
            defer { self.taskRunning = false }
            return try await self.perform(delegation)
        }
        calls[key] = (delegation, work)
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    public func cancelAll() async {
        for (_, work) in calls.values { work.cancel() }
    }

    private func perform(_ delegation: AuthenticatedVoiceDelegation) async throws -> VoiceDelegationResult {
        let deadline = Date().addingTimeInterval(180)
        var completed: [VoiceActionCandidate] = []
        var receipts: [ExternalExecutionWireResult] = []
        var attempted: Set<TrustedVoiceActionAuthority> = []
        func stopped(_ reason: String) -> VoiceDelegationResult {
            .init(status: .rejected,
                  spokenSummary: "Task stopped. \(receipts.count) steps verified. \(reason) Earlier changes are not undone.",
                  actionReceipts: receipts)
        }
        do {
            // One final selection may report completion after the eighth step.
            for _ in 0...8 {
                try Task.checkCancellation()
                guard Date() < deadline else { return stopped("The task time limit was reached.") }
                let verified = try await authenticatedContextProvider.authenticatedProductContext()
                guard verified.userID == delegation.userID, verified.sessionID == delegation.sessionID else {
                    throw AgentOSClientError.authenticatedIdentityMismatch
                }
                let context = await actionContextProvider.contextForRequest()
                guard context.accessibilityGranted else { return stopped("Enable Mac control in Menso and allow Accessibility.") }
                let catalog = NativeVoiceActionCatalog(context: context, utterance: delegation.request.task)
                let selection = try await selector.select(
                    utterance: delegation.request.task, candidates: catalog.entries.map(\.candidate),
                    completedSteps: completed, userID: verified.userID
                )
                try Task.checkCancellation()
                guard Date() < deadline else { return stopped("The task time limit was reached.") }
                switch selection.status {
                case .complete:
                    guard !receipts.isEmpty, selection.candidateID == nil else { throw LiveVoiceError.invalidDelegation }
                    return .init(status: .completed,
                                 spokenSummary: "Verified steps: " + completed.map(\.description).joined(separator: "; "),
                                 actionReceipts: receipts)
                case .unclear: return stopped("Please clarify the remaining target or requested outcome.")
                case .unsupported: return stopped("The remaining work has no supported, verifiable Mac action.")
                case .selected: break
                }
                guard completed.count < 8 else { return stopped("The eight-step limit was reached.") }
                guard let entry = catalog.entries.first(where: { $0.candidate.id == selection.candidateID }),
                      context.permits(entry.authority) else { throw LiveVoiceError.invalidDelegation }
                guard attempted.insert(entry.authority).inserted else { return stopped("A repeated step was blocked; inspect the target before retrying.") }
                // Refresh after network latency, before granting any local authority.
                let fresh = await actionContextProvider.contextForRequest()
                guard fresh.permits(entry.authority) else { return stopped("The target changed before execution.") }
                let result = try await execute(entry, delegation: delegation, deadline: deadline)
                guard result.status == .completed else { return stopped(result.spokenSummary) }
                receipts.append(contentsOf: result.actionReceipts)
                completed.append(entry.candidate)
            }
            return stopped("The step limit was reached.")
        } catch is CancellationError {
            return stopped("Cancelled. The last step may already have changed the Mac; check it before retrying.")
        } catch {
            return stopped(VoiceDelegationFailure.summary(for: error))
        }
    }

    private func execute(
        _ entry: NativeVoiceActionCatalog.Entry, delegation: AuthenticatedVoiceDelegation, deadline: Date
    ) async throws -> VoiceDelegationResult {
        let verified = try await authenticatedContextProvider.authenticatedProductContext()
        guard verified.userID == delegation.userID, verified.sessionID == delegation.sessionID else {
            throw AgentOSClientError.authenticatedIdentityMismatch
        }
        try Task.checkCancellation()
        let action = ActionRequest(
            idempotencyKey: IdempotencyKey(rawValue: "voice-typesafe:\(UUID().uuidString.lowercased())"),
            userID: verified.userID, sessionID: verified.sessionID, source: .nativeVoice,
            target: entry.authority.target, operation: entry.authority.operation,
            capability: ActionCapabilityBinding(expectedToolName: entry.authority.operation.semanticToolName),
            expiresAt: deadline
        )
        if case let .application(operation) = entry.authority.operation,
           [.openApplication, .focusWindow].contains(operation.kind) {
            await policyEngine.authorizeTaskNavigation(action)
        } else {
            await policyEngine.requireReviewForBoundRequest(action)
        }
        let result: ActionResult
        do {
            try Task.checkCancellation()
            switch await executor.submit(action) {
            case let .completed(value): result = value
            case let .requiresHumanReview(requirement):
                result = try await review(action, requirement: requirement, entry: entry)
            }
        } catch {
            await policyEngine.removeTaskRule(for: action)
            throw error
        }
        await policyEngine.removeTaskRule(for: action)
        // Never translate a model choice, approval click, or unverified receipt into success.
        guard result.actionID == action.actionID, result.target == action.target,
              result.contentHash == action.operation.contentHash else { throw LiveVoiceError.invalidDelegation }
        if result.verified, [.opened, .focused, .inserted, .activated].contains(result.status) {
            return .init(status: .completed, spokenSummary: "Completed and verified: \(entry.title).",
                         actionReceipts: [try ExternalExecutionWireResult(actionResult: result)])
        }
        switch result.errorCode {
        case .driverToolRejected:
            return .init(status: .rejected, spokenSummary:
                "The Mac driver refused a step. It may already have changed the app. Check the target before retrying; the failing tool is recorded in Menso's local CUA log.")
        case .driverProtocolFailure:
            return .init(status: .rejected, spokenSummary:
                "The Mac driver did not return a usable result. The step may have executed; check the target before retrying.")
        case .driverIntegrityFailed:
            return .init(status: .rejected, spokenSummary:
                "Menso's Mac control installation failed its integrity check. Rebuild and reinstall Menso. This step was not executed.")
        case .driverPermissionMissing:
            return .init(status: .rejected, spokenSummary:
                "Mac control could not confirm Menso's permissions. Check Menso in System Settings, Privacy & Security, then restart Menso. This step was not executed.")
        case .transportUnavailable:
            return .init(status: .rejected, spokenSummary:
                "Menso's Mac control driver could not start. Restart Menso and try again. This step was not executed.")
        default: break
        }
        switch result.status {
        case .denied:
            return .init(status: .rejected, spokenSummary: result.errorCode == .humanReviewDenied
                         ? "This step was declined and was not executed."
                         : "Local policy or secure input blocked this step; it was not executed.")
        case .expired: return .init(status: .rejected, spokenSummary: "The action expired. Ask again if you still want it.")
        default:
            return .init(status: .rejected,
                         spokenSummary: "This step may have executed, but its outcome is unverified. Do not say nothing ran. Check the target app before retrying.")
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
