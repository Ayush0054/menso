import XCTest
@testable import MensoCore

final class TypeSafeActionCatalogTests: XCTestCase {
    func testCatalogContainsOnlyObservedApps() {
        let context = VoiceActionContext(
            applications: [.init(name: "Example", bundleIdentifier: "com.example.app")],
            focusedTarget: nil, accessibilityGranted: true
        )
        let catalog = NativeVoiceActionCatalog(context: context, utterance: "Open Example")
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries.first?.candidate.id, "action_0")
        XCTAssertEqual(catalog.entries.first?.authority.target,
                       .focusedApplication(.init(bundleIdentifier: "com.example.app")))
    }

    func testNoAccessibilityProducesNoCandidates() {
        let context = VoiceActionContext(
            applications: [.init(name: "Example", bundleIdentifier: "com.example.app")],
            focusedTarget: nil, accessibilityGranted: false
        )
        XCTAssertTrue(NativeVoiceActionCatalog(context: context, utterance: "Open Example").entries.isEmpty)
    }

    func testLiteralTextIsCopiedNotGenerated() {
        let utterance = "Please type “Hello, world!” into the field"
        let candidates = NativeVoiceActionCatalog.literalTextCandidates(utterance)
        XCTAssertTrue(candidates.contains("Hello, world!"))
        XCTAssertTrue(candidates.allSatisfy { utterance.contains($0) })
        XCTAssertTrue(NativeVoiceActionCatalog.literalTextCandidates("Compose a poem").isEmpty)
    }

    func testOldCommandsAndAssistantPromisesAreNotCurrentInput() {
        let text = VoiceActionTranscript.currentUtterance([
            (.user, "Open Chrome", 1), (.assistant, "Please approve it", 2),
            (.user, "Open ", 3), (.user, "Brave", 4), (.assistant, "I'll check", 5),
        ], afterOffset: 2, throughOffset: 5)
        XCTAssertEqual(text, "Open Brave")
        XCTAssertEqual(VoiceActionTranscript.currentUtterance([(.assistant, "Open Chrome", 1)]), "")
    }

    func testBackchannelCannotDiscardPartOfTheUsersCommand() {
        XCTAssertEqual(VoiceActionTranscript.currentUtterance([
            (.user, "Open Google ", 1), (.assistant, "Sure", 2), (.user, "Chrome", 3),
        ]), "Open Google Chrome")
    }

    func testOversizedUtteranceIsRejectedRatherThanDroppingNegation() {
        XCTAssertEqual(VoiceActionTranscript.currentUtterance([
            (.user, "Do not " + String(repeating: "open Chrome ", count: 400), 1),
        ]), "")
    }
}
