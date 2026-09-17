import Foundation
import XCTest
@testable import MensoCore

final class TypeSafeVoiceBridgeTests: XCTestCase {
    func testSelectionCreatesRealReviewBeforeExecutionAndDuplicateCallDoesNotRepeat() async throws {
        let fixture = Fixture()
        let updates = await fixture.reviews.pendingActionUpdates()
        var cards = updates.makeAsyncIterator()
        _ = await cards.next() // Initial empty state.
        let delegation = try fixture.delegation()
        let task = Task { try await fixture.bridge.delegate(delegation) }
        defer { task.cancel() }
        let pending = await cards.next()
        let card = try XCTUnwrap(pending?.first)
        XCTAssertEqual(card.title, "Open Example")
        XCTAssertFalse(card.canCreateAlwaysRule)
        let before = await fixture.broker.count
        XCTAssertEqual(before, 0)
        try await fixture.reviews.resolve(actionID: .init(rawValue: card.id), resolution: .approveOnce)
        let result = try await task.value
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.actionReceipts.count, 1)
        XCTAssertTrue(result.actionReceipts[0].verified)
        XCTAssertNil(result.runID)
        let repeated = try await fixture.bridge.delegate(delegation)
        XCTAssertEqual(repeated, result)
        let after = await fixture.broker.count
        XCTAssertEqual(after, 1)
    }

    func testDecliningDoesNotExecute() async throws {
        let fixture = Fixture()
        let updates = await fixture.reviews.pendingActionUpdates()
        var cards = updates.makeAsyncIterator()
        _ = await cards.next()
        let delegation = try fixture.delegation()
        let task = Task { try await fixture.bridge.delegate(delegation) }
        defer { task.cancel() }
        let pending = await cards.next()
        let card = try XCTUnwrap(pending?.first)
        try await fixture.reviews.resolve(actionID: .init(rawValue: card.id), resolution: .deny)
        let result = try await task.value
        XCTAssertEqual(result.status, .rejected)
        let count = await fixture.broker.count
        XCTAssertEqual(count, 0)
    }

    func testLegacyVoiceWithoutOriginRemainsDenied() async throws {
        let policy = PolicyEngine(auditSink: InMemoryActionAuditSink())
        let operation = ActionOperation.application(.init(kind: .openApplication))
        let request = ActionRequest(
            idempotencyKey: .init(rawValue: "legacy"), userID: .init(rawValue: "user"),
            sessionID: .init(rawValue: "session"), source: .voiceDelegation,
            target: .focusedApplication(.init(bundleIdentifier: "com.example.app")),
            operation: operation, capability: .init(expectedToolName: operation.semanticToolName),
            expiresAt: Date().addingTimeInterval(60)
        )
        await policy.requireReviewForBoundRequest(request)
        let decision = await policy.evaluate(request)
        guard case .deny = decision else { return XCTFail("Legacy voice still requires a backend origin") }
    }
}

private struct Fixture {
    let broker: RecordingVoiceBroker
    let reviews: RunPauseCoordinator
    let bridge: TypeSafeVoiceDelegationBridge

    init() {
        let audit = InMemoryActionAuditSink()
        let policy = PolicyEngine(auditSink: audit)
        let broker = RecordingVoiceBroker()
        let executor = ActionExecutor(
            policyEngine: policy, broker: broker, auditSink: audit,
            resultStore: InMemoryActionResultStore(), secureInput: VoiceTestSecureInput()
        )
        let reviews = RunPauseCoordinator(policyEngine: policy, actionExecutor: executor, auditSink: audit)
        self.broker = broker
        self.reviews = reviews
        self.bridge = TypeSafeVoiceDelegationBridge(
            selector: FirstCandidateSelector(), authenticatedContextProvider: VoiceTestIdentity(),
            actionContextProvider: VoiceTestContext(), policyEngine: policy, executor: executor, reviews: reviews
        )
    }

    func delegation() throws -> AuthenticatedVoiceDelegation {
        .init(request: try .init(callID: "call-1", task: "Open Example"), route: .nativeAction,
              actionAuthority: nil, userID: .init(rawValue: "user"), sessionID: .init(rawValue: "session"))
    }
}

private struct FirstCandidateSelector: VoiceActionSelecting {
    func select(utterance: String, candidates: [VoiceActionCandidate], userID: UserID) async throws -> VoiceActionSelection {
        .init(status: .selected, candidateID: candidates.first?.id)
    }
}

private struct VoiceTestIdentity: AuthenticatedProductContextProviding {
    func authenticatedProductContext() async throws -> AuthenticatedProductContext {
        try .init(userID: .init(rawValue: "user"), sessionID: .init(rawValue: "session"))
    }
}

private struct VoiceTestContext: VoiceActionContextProviding {
    func contextForRequest() async -> VoiceActionContext {
        .init(applications: [.init(name: "Example", bundleIdentifier: "com.example.app")],
              focusedTarget: nil, accessibilityGranted: true)
    }
}

private struct VoiceTestSecureInput: SecureInputStateProviding {
    func currentSecureInputState() async -> SecureInputState { .disabled }
}

private actor RecordingVoiceBroker: SemanticActionBroker {
    private(set) var count = 0
    func execute(_ request: ActionRequest) async throws -> ActionResult {
        count += 1
        return .init(actionID: request.actionID, status: .opened, target: request.target,
                     contentHash: request.operation.contentHash, verified: true)
    }
}
