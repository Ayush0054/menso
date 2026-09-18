import Foundation
import XCTest
@testable import MensoCore

final class TypeSafeVoiceBridgeTests: XCTestCase {
    func testNavigationRunsWithoutReviewAndDuplicateCallDoesNotRepeat() async throws {
        let fixture = Fixture()
        let updates = await fixture.reviews.pendingActionUpdates()
        var cards = updates.makeAsyncIterator()
        _ = await cards.next() // Initial empty state.
        let delegation = try fixture.delegation()
        let result = try await fixture.bridge.delegate(delegation)
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
        let fixture = Fixture(selector: FirstCandidateSelector(kind: "insert_text"))
        let updates = await fixture.reviews.pendingActionUpdates()
        var cards = updates.makeAsyncIterator()
        _ = await cards.next()
        let delegation = try fixture.delegation(task: "Type \"hello\"")
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

    func testEndingTaskCancelsPendingReviewWithoutExecution() async throws {
        let fixture = Fixture(selector: FirstCandidateSelector(kind: "insert_text"))
        let updates = await fixture.reviews.pendingActionUpdates()
        var cards = updates.makeAsyncIterator()
        _ = await cards.next()
        let delegation = try fixture.delegation(task: "Type \"hello\"")
        let task = Task { try await fixture.bridge.delegate(delegation) }
        defer { task.cancel() }
        let pending = await cards.next()
        XCTAssertEqual(pending?.count, 1)
        await fixture.bridge.cancelAll()
        let result = try await task.value
        XCTAssertEqual(result.status, .rejected)
        let count = await fixture.broker.count
        XCTAssertEqual(count, 0)
    }

    func testDriverStartupFailuresDoNotBlameTargetVerification() async throws {
        let failures: [(LocalToolBrokerError, String)] = [
            (.driverIntegrityFailed, "integrity check"),
            (.driverPermissionMissing, "permissions"),
            (.driverUnavailable, "driver could not start"),
        ]
        for (failure, expectedMessage) in failures {
            let fixture = Fixture(failure: failure)
            let delegation = try fixture.delegation()
            let result = try await fixture.bridge.delegate(delegation)
            XCTAssertEqual(result.status, .rejected)
            XCTAssertTrue(result.actionReceipts.isEmpty)
            XCTAssertTrue(result.spokenSummary.contains(expectedMessage))
            XCTAssertTrue(result.spokenSummary.contains("This step was not executed."))
        }
    }

    func testMultipleStepsAreVerifiedAndReturnedInOrder() async throws {
        let fixture = Fixture(selector: SequenceSelector(ids: ["action_0", "action_1"]))
        let result = try await fixture.bridge.delegate(fixture.delegation(task: "Open Example then Other"))
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.actionReceipts.count, 2)
        let count = await fixture.broker.count
        XCTAssertEqual(count, 2)
    }

    func testRepeatedStepStopsWithoutExecutingAgainAndKeepsPartialReceipt() async throws {
        let fixture = Fixture(selector: SequenceSelector(ids: ["action_0", "action_0"]))
        let result = try await fixture.bridge.delegate(fixture.delegation())
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.actionReceipts.count, 1)
        XCTAssertTrue(result.spokenSummary.contains("repeated step"))
        let count = await fixture.broker.count
        XCTAssertEqual(count, 1)
    }

    func testModelCannotClaimCompletionWithoutExecution() async throws {
        let fixture = Fixture(selector: SequenceSelector(ids: []))
        let result = try await fixture.bridge.delegate(fixture.delegation())
        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.actionReceipts.isEmpty)
        let count = await fixture.broker.count
        XCTAssertEqual(count, 0)
    }

    func testUnverifiedOutcomeDoesNotClaimNothingRan() async throws {
        let fixture = Fixture(failure: .verificationFailed)
        let result = try await fixture.bridge.delegate(fixture.delegation())
        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.spokenSummary.contains("may have executed"))
        XCTAssertFalse(result.spokenSummary.contains("Nothing was executed."))
    }
}

private struct Fixture {
    let broker: RecordingVoiceBroker
    let reviews: RunPauseCoordinator
    let bridge: TypeSafeVoiceDelegationBridge

    init(failure: LocalToolBrokerError? = nil, selector: any VoiceActionSelecting = FirstCandidateSelector()) {
        let audit = InMemoryActionAuditSink()
        let policy = PolicyEngine(auditSink: audit)
        let broker = RecordingVoiceBroker(failure: failure)
        let executor = ActionExecutor(
            policyEngine: policy, broker: broker, auditSink: audit,
            resultStore: InMemoryActionResultStore(), secureInput: VoiceTestSecureInput()
        )
        let reviews = RunPauseCoordinator(policyEngine: policy, actionExecutor: executor, auditSink: audit)
        self.broker = broker
        self.reviews = reviews
        self.bridge = TypeSafeVoiceDelegationBridge(
            selector: selector, authenticatedContextProvider: VoiceTestIdentity(),
            actionContextProvider: VoiceTestContext(), policyEngine: policy, executor: executor, reviews: reviews
        )
    }

    func delegation(task: String = "Open Example") throws -> AuthenticatedVoiceDelegation {
        .init(request: try .init(callID: "call-1", task: task), route: .nativeAction,
              actionAuthority: nil, userID: .init(rawValue: "user"), sessionID: .init(rawValue: "session"))
    }
}

private struct FirstCandidateSelector: VoiceActionSelecting {
    var kind = "open_application"
    func select(utterance: String, candidates: [VoiceActionCandidate], completedSteps: [VoiceActionCandidate], userID: UserID) async throws -> VoiceActionSelection {
        completedSteps.isEmpty
            ? .init(status: .selected, candidateID: candidates.first(where: { $0.kind == kind })?.id)
            : .init(status: .complete, candidateID: nil)
    }
}

private struct SequenceSelector: VoiceActionSelecting {
    let ids: [String]
    func select(utterance: String, candidates: [VoiceActionCandidate], completedSteps: [VoiceActionCandidate], userID: UserID) async throws -> VoiceActionSelection {
        completedSteps.count < ids.count
            ? .init(status: .selected, candidateID: ids[completedSteps.count])
            : .init(status: .complete, candidateID: nil)
    }
}

private struct VoiceTestIdentity: AuthenticatedProductContextProviding {
    func authenticatedProductContext() async throws -> AuthenticatedProductContext {
        try .init(userID: .init(rawValue: "user"), sessionID: .init(rawValue: "session"))
    }
}

private struct VoiceTestContext: VoiceActionContextProviding {
    func contextForRequest() async -> VoiceActionContext {
        .init(applications: [.init(name: "Example", bundleIdentifier: "com.example.app"),
                             .init(name: "Other", bundleIdentifier: "com.example.other")],
              focusedTarget: .init(bundleIdentifier: "com.example.app", processIdentifier: 42,
                                   windowTitle: "Example", elementRole: "AXTextField", elementLabel: "Input"),
              accessibilityGranted: true)
    }
}

private struct VoiceTestSecureInput: SecureInputStateProviding {
    func currentSecureInputState() async -> SecureInputState { .disabled }
}

private actor RecordingVoiceBroker: SemanticActionBroker {
    private(set) var count = 0
    let failure: LocalToolBrokerError?
    init(failure: LocalToolBrokerError? = nil) { self.failure = failure }
    func execute(_ request: ActionRequest) async throws -> ActionResult {
        count += 1
        if let failure { throw failure }
        return .init(actionID: request.actionID, status: .opened, target: request.target,
                     contentHash: request.operation.contentHash, verified: true)
    }
}
