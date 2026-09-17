import Foundation
import XCTest
@testable import MensoCore

final class VoiceContinuityApprovalTests: XCTestCase {
    func testOldApprovalClaimIsNotRestoredAsPendingOrSpoken() throws {
        let result = VoiceDelegationResult(
            status: .requiresExternalAction,
            spokenSummary: "Approve the Open Google Chrome action in Menso.",
            runID: "old-run", continuationKind: "agent", continuationResourceID: "menso"
        )
        for state in [PersistedVoiceDelegationState.awaitingOriginalCall, .representedInReplacement] {
            let record = try delegation(result: result, state: state)
            let checkpoint = try checkpoint(delegations: [record])
            let restored = LiveVoiceCoordinator.continuationContext(
                from: checkpoint, delegations: [record], includeTranscript: true
            )
            let task = try XCTUnwrap(restored.delegations.first)
            XCTAssertEqual(task.status, "historical_unconfirmed")
            XCTAssertFalse(task.shouldAnnounce)
            XCTAssertFalse(task.spokenSummary?.contains("Approve the Open Google Chrome") == true)
            XCTAssertTrue(task.spokenSummary?.contains("not proof") == true)
            XCTAssertFalse(restored.transcriptSummary.contains("Please approve"))
            XCTAssertTrue(restored.transcriptSummary.contains("Google Chrome"))
            // Filtering provider context must not erase the saved evidence.
            XCTAssertEqual(checkpoint.delegations.first?.result, result)
            XCTAssertEqual(checkpoint.finalTranscript.count, 2)
        }
    }

    func testUndeliveredTerminalResultCanStillBeAnnounced() throws {
        let result = VoiceDelegationResult(status: .rejected, spokenSummary: "The request was declined.")
        let record = try delegation(result: result, state: .awaitingOriginalCall)
        let restored = LiveVoiceCoordinator.continuationContext(
            from: try checkpoint(delegations: [record]), delegations: [record], includeTranscript: false
        )
        XCTAssertTrue(restored.transcriptSummary.isEmpty)
        XCTAssertEqual(restored.delegations.first?.status, "rejected")
        XCTAssertEqual(restored.delegations.first?.spokenSummary, result.spokenSummary)
        XCTAssertEqual(restored.delegations.first?.shouldAnnounce, true)
    }

    func testInFlightRecordIsNotRestoredAsApprovalOrCompletion() throws {
        let record = try delegation(result: nil, state: .inFlight)
        let restored = LiveVoiceCoordinator.continuationContext(
            from: try checkpoint(delegations: [record]), delegations: [record], includeTranscript: false
        )
        XCTAssertEqual(restored.delegations.first?.status, "may_still_be_running")
        XCTAssertEqual(restored.delegations.first?.shouldAnnounce, false)
    }

    private func delegation(
        result: VoiceDelegationResult?, state: PersistedVoiceDelegationState
    ) throws -> PersistedVoiceDelegation {
        let sessionID = UUID().uuidString
        let callID = "item-example"
        let now = Date()
        return try PersistedVoiceDelegation(
            recordID: PersistedVoiceDelegation.makeRecordID(providerSessionID: sessionID, callID: callID),
            providerSessionID: sessionID, callID: callID,
            request: VoiceDelegationRequest(callID: callID, task: "Open Google Chrome", operationHint: nil),
            state: state, result: result, recordedAt: now, updatedAt: now
        )
    }

    private func checkpoint(delegations: [PersistedVoiceDelegation]) throws -> LiveVoiceContinuityCheckpoint {
        try LiveVoiceContinuityCheckpoint(
            userID: UserID(rawValue: "user-1"),
            productSessionID: ProductSessionID(rawValue: UUID().uuidString),
            finalTranscript: [
                .init(speaker: .user, text: "Open Google Chrome", isFinal: true),
                .init(speaker: .assistant, text: "Please approve the Chrome action.", isFinal: true),
            ],
            delegations: delegations, updatedAt: Date()
        )
    }
}
