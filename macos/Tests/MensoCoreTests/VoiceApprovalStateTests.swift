import Foundation
import XCTest
@testable import MensoCore

final class VoiceApprovalStateTests: XCTestCase {
    private let userID = UserID(rawValue: "user-1")
    private let sessionID = ProductSessionID(rawValue: "session-1")

    func testModelCannotCreateApprovalWithTerminalJSON() throws {
        let result = try decodeCompleted("""
        {"status":"requires_external_action","spoken_summary":"Please approve Chrome in Menso.",
         "action_receipts":[],"run_id":"invented-run","continuation_kind":"agent",
         "continuation_resource_id":"menso"}
        """)
        XCTAssertEqual(result?.status, .rejected)
        XCTAssertTrue(result?.spokenSummary.contains("did not create an approval card") == true)
        XCTAssertNil(result?.runID)
        XCTAssertNil(result?.continuationKind)
        XCTAssertNil(result?.continuationResourceID)
    }

    func testTerminalOutputCannotSupplyContinuationMetadata() throws {
        let result = try decodeCompleted("""
        {"status":"completed","spoken_summary":"Hello.","action_receipts":[],
         "run_id":"invented-run","continuation_kind":"agent","continuation_resource_id":"menso"}
        """)
        XCTAssertEqual(result?.status, .completed)
        XCTAssertEqual(result?.spokenSummary, "Hello.")
        XCTAssertNil(result?.runID)
        XCTAssertNil(result?.continuationKind)
        XCTAssertNil(result?.continuationResourceID)
    }

    func testIncompleteStreamIsNotAPause() async throws {
        let observer = VoiceAgentStreamObserver(
            expectedAgentID: "menso", expectedUserID: userID, expectedSessionID: sessionID
        )
        let upstream = stream([event("RunStarted", body: "")])
        for try await _ in observer.observe(upstream) {}
        let paused = await observer.didPause()
        let result = try await observer.completedResult()
        XCTAssertFalse(paused)
        XCTAssertNil(result)
    }

    func testActualToolPausePublishesActionCardWithoutExecuting() async throws {
        let audit = InMemoryActionAuditSink()
        let policy = PolicyEngine(auditSink: audit)
        let executor = ActionExecutor(
            policyEngine: policy, broker: NeverExecuteBroker(), auditSink: audit,
            resultStore: InMemoryActionResultStore(), secureInput: FailClosedSecureInputStateProvider()
        )
        let coordinator = RunPauseCoordinator(
            policyEngine: policy, actionExecutor: executor, auditSink: audit,
            continuationDispatcher: NoopContinuationDispatcher()
        )
        let ingestor = AgentOSRunStreamIngestor(authorityRegistry: TrustedRunAuthorityRegistry())
        try ingestor.bind(to: coordinator)
        let start = TrustedAgentRunStart(
            launchID: "launch-1", agentID: "menso", authenticatedUserID: userID,
            authenticatedSessionID: sessionID, expectedTarget: nil, expectedOperation: nil,
            expiresAt: Date().addingTimeInterval(300),
            voiceActionContext: VoiceActionContext(
                applications: [.init(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")],
                focusedTarget: nil, accessibilityGranted: true
            )
        )
        try await ingestor.prepareAgentRunStart(start)
        let before = try await ingestor.hasPendingAgentReview(
            agentID: "menso", runID: "run-1", userID: userID, sessionID: sessionID
        )
        XCTAssertFalse(before)
        try await ingestor.handle(stream([
            event("RunStarted", body: ""),
            event("RunPaused", body: """
            ,"tools":[{"tool_call_id":"tool-1","tool_name":"open_application",
            "external_execution_required":true,"tool_args":{"bundle_id":"com.google.Chrome"}}]
            """),
        ]), origin: .startedAgent(start))

        let pending = try await ingestor.hasPendingAgentReview(
            agentID: "menso", runID: "run-1", userID: userID, sessionID: sessionID
        )
        XCTAssertTrue(pending)
        let otherRun = try await ingestor.hasPendingAgentReview(
            agentID: "menso", runID: "run-2", userID: userID, sessionID: sessionID
        )
        let otherUser = try await ingestor.hasPendingAgentReview(
            agentID: "menso", runID: "run-1", userID: UserID(rawValue: "other"), sessionID: sessionID
        )
        let otherSession = try await ingestor.hasPendingAgentReview(
            agentID: "menso", runID: "run-1", userID: userID,
            sessionID: ProductSessionID(rawValue: "other")
        )
        XCTAssertFalse(otherRun)
        XCTAssertFalse(otherUser)
        XCTAssertFalse(otherSession)

        // This is the same stream the desktop view model uses to show buttons.
        let pendingUpdates = await coordinator.pendingActionUpdates()
        var updates = pendingUpdates.makeAsyncIterator()
        let cards = await updates.next()
        XCTAssertEqual(cards?.count, 1)
        let card = try XCTUnwrap(cards?.first)
        try await coordinator.resolve(actionID: ActionID(rawValue: card.id), resolution: .deny)
        let after = try await ingestor.hasPendingAgentReview(
            agentID: "menso", runID: "run-1", userID: userID, sessionID: sessionID
        )
        XCTAssertFalse(after)
    }

    private func decodeCompleted(_ content: String) throws -> VoiceDelegationResult? {
        try VoiceAgentStreamObserver.decodeCompletedResult(
            event("RunCompleted", body: ",\"content\":\(content)"),
            expectedAgentID: "menso", expectedUserID: userID, expectedSessionID: sessionID
        )
    }

    private func event(_ name: String, body: String) -> ServerSentEvent {
        ServerSentEvent(id: nil, event: name, data: """
        {"run_id":"run-1","agent_id":"menso","user_id":"user-1","session_id":"session-1"\(body)}
        """, retryMilliseconds: nil)
    }

    private func stream(_ events: [ServerSentEvent]) -> AgentOSEventStream {
        AgentOSEventStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private struct NeverExecuteBroker: SemanticActionBroker {
    func execute(_ request: ActionRequest) async throws -> ActionResult {
        XCTFail("An unapproved or declined proposal must not execute")
        throw ActionAuditError.rejected
    }
}

private struct NoopContinuationDispatcher: RunContinuationDispatching {
    func dispatch(_ continuation: AgentRunContinuation) async throws {}
    func dispatch(_ continuation: WorkflowRunContinuation) async throws {}
}
