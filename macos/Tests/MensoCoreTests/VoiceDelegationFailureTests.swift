import Foundation
import XCTest
@testable import MensoCore

final class VoiceDelegationFailureTests: XCTestCase {
    func testTypeSafeAuthenticationErrorUsesFixedActionableMessage() {
        let data = Data(#"{"detail":{"code":"typesafe_authentication_failed","message":"private-provider-response"}}"#.utf8)
        let error = TypeSafeActionError.gatewayFailure(from: data)
        XCTAssertEqual(error, .authenticationFailed)
        let summary = VoiceDelegationFailure.summary(for: error)
        XCTAssertTrue(summary.contains("TYPESAFE_API_KEY"))
        XCTAssertFalse(summary.contains("private-provider-response"))
        XCTAssertFalse(summary.contains("Settings"))
    }

    func testUnknownOrLegacyProviderErrorRemainsGeneric() {
        for body in [#"{"detail":"TypeSafe selection is unavailable"}"#,
                     #"{"detail":{"code":"unknown"}}"#, "invalid json"] {
            XCTAssertEqual(TypeSafeActionError.gatewayFailure(from: Data(body.utf8)), .unavailable)
        }
        XCTAssertEqual(TypeSafeActionError.gatewayFailure(from: Data(repeating: 65, count: 16_385)), .unavailable)
    }

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
