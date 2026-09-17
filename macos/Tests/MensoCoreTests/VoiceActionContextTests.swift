import Foundation
import XCTest
@testable import MensoCore

final class VoiceActionContextTests: XCTestCase {
    private let appID = "com.example.browser"

    func testInstalledAppCanBeProposedWithoutPreparingAnAction() throws {
        let context = snapshot()
        let action = try openAction(appID)
        XCTAssertTrue(context.permits(action))
        XCTAssertFalse(context.permits(try openAction("com.example.unknown")))
    }

    func testMissingAccessibilityCannotAuthorizeProposal() throws {
        XCTAssertFalse(snapshot(permission: false).permits(try openAction(appID)))
    }

    func testTextProposalMustUseExactObservedTarget() throws {
        let field = FocusedApplicationTarget(
            bundleIdentifier: appID, processIdentifier: 42, windowTitle: "Draft",
            elementRole: "AXTextField", elementLabel: "Search"
        )
        let context = snapshot(target: field)
        let operation = ActionOperation.application(ApplicationSemanticOperation(kind: .insertText, text: "hello"))
        XCTAssertTrue(context.permits(try TrustedVoiceActionAuthority(target: .focusedApplication(field), operation: operation)))
        let different = FocusedApplicationTarget(
            bundleIdentifier: appID, processIdentifier: 43, windowTitle: "Draft",
            elementRole: "AXTextField", elementLabel: "Search"
        )
        XCTAssertFalse(context.permits(try TrustedVoiceActionAuthority(target: .focusedApplication(different), operation: operation)))
        XCTAssertFalse(snapshot().permits(try TrustedVoiceActionAuthority(target: .focusedApplication(field), operation: operation)))
    }

    func testFirstProposalBindsOneToolCallAndRejectsSecondAction() async throws {
        let persistence = InMemoryAuthorityStore()
        let registry = TrustedRunAuthorityRegistry(persistence: persistence)
        let start = runStart(context: snapshot())
        try await registry.prepareAgentRunStart(start)
        try await registry.bindAgentRun(start, runID: "run-1")
        let first = continuation(toolID: "tool-1", bundleID: appID)
        let pause = try await registry.authorize(first, startedWith: start)
        XCTAssertEqual(pause.expectedTarget, .focusedApplication(FocusedApplicationTarget(bundleIdentifier: appID)))
        let bound = try await registry.resolvedAgentAuthority(agentID: "menso", runID: "run-1")
        XCTAssertEqual(bound, try openAction(appID))
        // Retrying the same pending call is supported; it does not grant a new action.
        _ = try await registry.authorize(first, startedWith: start)
        // Restore through persisted state, not only the in-memory registry.
        let restored = TrustedRunAuthorityRegistry(persistence: persistence)
        let restoredBinding = try await restored.resolvedAgentAuthority(agentID: "menso", runID: "run-1")
        XCTAssertEqual(restoredBinding, bound)
        do {
            _ = try await restored.authorize(continuation(toolID: "tool-2", bundleID: appID), startedWith: nil)
            XCTFail("A second distinct tool call must not receive authority")
        } catch {
            XCTAssertEqual(error as? AgentOSRunStreamIngestorError, .authorityConflict)
        }
    }

    func testUnknownAppAndWrongIdentityFailClosed() async throws {
        let registry = TrustedRunAuthorityRegistry()
        let start = runStart(context: snapshot())
        try await registry.prepareAgentRunStart(start)
        try await registry.bindAgentRun(start, runID: "run-1")
        do {
            _ = try await registry.authorize(continuation(toolID: "tool-1", bundleID: "unknown"), startedWith: start)
            XCTFail("Unknown installed target must not be bound")
        } catch {
            XCTAssertEqual(error as? AgentOSRunStreamIngestorError, .authorityUnavailable)
        }
        let original = continuation(toolID: "tool-1", bundleID: appID)
        let wrongUser = AgentRunContinuation(
            agentID: "menso", runID: "run-1", sessionID: original.sessionID,
            userID: UserID(rawValue: "different-user"), tools: original.tools
        )
        do {
            _ = try await registry.authorize(wrongUser, startedWith: start)
            XCTFail("Caller identity must match the authenticated run")
        } catch {
            XCTAssertEqual(error as? AgentOSRunStreamIngestorError, .unexpectedRun("agent authority"))
        }
    }

    private func snapshot(target: FocusedApplicationTarget? = nil, permission: Bool = true) -> VoiceActionContext {
        VoiceActionContext(
            applications: [.init(name: "Example Browser", bundleIdentifier: appID)],
            focusedTarget: target, accessibilityGranted: permission
        )
    }

    private func openAction(_ bundleID: String) throws -> TrustedVoiceActionAuthority {
        try TrustedVoiceActionAuthority(
            target: .focusedApplication(FocusedApplicationTarget(bundleIdentifier: bundleID)),
            operation: .application(ApplicationSemanticOperation(kind: .openApplication))
        )
    }

    private func runStart(context: VoiceActionContext) -> TrustedAgentRunStart {
        TrustedAgentRunStart(
            launchID: "launch-1", agentID: "menso", authenticatedUserID: UserID(rawValue: "user-1"),
            authenticatedSessionID: ProductSessionID(rawValue: "session-1"),
            expectedTarget: nil, expectedOperation: nil, expiresAt: Date().addingTimeInterval(300),
            voiceActionContext: context
        )
    }

    private func continuation(toolID: String, bundleID: String) -> AgentRunContinuation {
        AgentRunContinuation(
            agentID: "menso", runID: "run-1", sessionID: ProductSessionID(rawValue: "session-1"),
            userID: UserID(rawValue: "user-1"), tools: [AgentToolContinuation(fields: [
                "tool_call_id": .string(toolID), "tool_name": .string("open_application"),
                "external_execution_required": .bool(true),
                "tool_args": .object(["bundle_id": .string(bundleID)]),
            ])]
        )
    }
}

/// Mirrors the store's immutable insert and compare-and-swap update contract.
private actor InMemoryAuthorityStore: TrustedRunAuthorityPersisting {
    private var records: [String: StoredTrustedRunAuthority] = [:]

    func saveTrustedRunAuthority(_ authority: StoredTrustedRunAuthority) throws {
        if let existing = records[authority.id], existing.authorityJSON != authority.authorityJSON {
            throw TrustedRunAuthorityStoreError.bindingConflict
        }
        records[authority.id] = authority
    }

    func updateTrustedRunAuthority(_ authority: StoredTrustedRunAuthority, replacingAuthorityJSON: Data) throws {
        guard records[authority.id]?.authorityJSON == replacingAuthorityJSON else {
            throw TrustedRunAuthorityStoreError.bindingConflict
        }
        records[authority.id] = authority
    }

    func trustedRunAuthority(id: String, at date: Date) -> StoredTrustedRunAuthority? {
        guard let record = records[id], record.expiresAt > date else { return nil }
        return record
    }

    func deleteTrustedRunAuthority(id: String) {
        records.removeValue(forKey: id)
    }
}
