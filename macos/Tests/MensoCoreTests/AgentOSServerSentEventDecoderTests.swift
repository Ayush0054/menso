import XCTest
@testable import MensoCore

final class AgentOSServerSentEventDecoderTests: XCTestCase {
    func testSeparatesConsecutiveEventsWithEverySSELineEnding() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let source = [
                "event: RunStarted", "data: {\"run_id\":\"one\"}", "",
                "event: RunPaused", "data: {\"run_id\":\"one\",\"tools\":[]}", "", "",
            ].joined(separator: newline)
            let events = try decode(source)
            XCTAssertEqual(events.map(\.event), ["RunStarted", "RunPaused"])
            XCTAssertEqual(events.first?.data, "{\"run_id\":\"one\"}")
            XCTAssertEqual(events.last?.data, "{\"run_id\":\"one\",\"tools\":[]}")
        }
    }

    func testPreservesMultilineDataAndUnicodeAcrossIndividualBytes() throws {
        let events = try decode(
            "\u{FEFF}: heartbeat\r\nid: task-1\r\nretry: 1500\r\nevent: RunCompleted\r\n"
                + "data: {\"text\":\"नमस्ते 👋\u{2028}world\",\r\n"
                + "data: \"done\":true}\r\n\r\n"
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, "task-1")
        XCTAssertEqual(events[0].retryMilliseconds, 1500)
        XCTAssertEqual(events[0].data, "{\"text\":\"नमस्ते 👋\u{2028}world\",\n\"done\":true}")
    }

    func testCommentsDoNotProduceTaskEvents() throws {
        XCTAssertTrue(try decode(": keepalive\n\n\n").isEmpty)
    }

    func testIncompleteResultIsNotDelivered() throws {
        var decoder = AgentOSServerSentEventDecoder()
        for byte in "event: RunCompleted\ndata: {}\n".utf8 {
            XCTAssertNil(try decoder.append(byte))
        }
        XCTAssertThrowsError(try decoder.finish())
    }

    func testRejectsOversizedEvent() throws {
        var decoder = AgentOSServerSentEventDecoder()
        for _ in 0..<1_048_576 { _ = try decoder.append(97) }
        XCTAssertThrowsError(try decoder.append(97))
    }

    private func decode(_ source: String) throws -> [ServerSentEvent] {
        var decoder = AgentOSServerSentEventDecoder()
        var events: [ServerSentEvent] = []
        for byte in source.utf8 {
            if let event = try decoder.append(byte) { events.append(event) }
        }
        try decoder.finish()
        return events
    }
}
