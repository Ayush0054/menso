import Foundation
import XCTest
@testable import MensoCore

final class VoiceDelegationFailureTests: XCTestCase {
    func testMissingAuthorityAsksForTargetWithoutPreparationForm() {
        XCTAssertTrue(VoiceDelegationFailure.summary(
            for: AgentOSRunStreamIngestorError.authorityUnavailable
        ).contains("Name the app"))
    }

    func testAuthenticationFailureDoesNotLookLikeSafetyDenial() {
        XCTAssertTrue(VoiceDelegationFailure.summary(
            for: AgentOSClientError.httpStatus(401)
        ).contains("authentication"))
    }

    func testUnknownFailureDoesNotDiscloseRawErrorOrClaimNoExecution() {
        struct ProviderError: LocalizedError {
            var errorDescription: String? { "private-provider-response" }
        }
        let summary = VoiceDelegationFailure.summary(for: ProviderError())
        XCTAssertFalse(summary.contains("private-provider-response"))
        XCTAssertTrue(summary.contains("couldn't confirm"))
        XCTAssertTrue(summary.contains("Check the target app"))
    }
}
