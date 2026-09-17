import Foundation

/// Frame SSE from bytes so blank event separators are retained explicitly.
/// Only CR/LF delimit lines; Unicode in JSON is decoded after the whole line
/// arrives. In particular, a U+2028 inside a caption must not split an event.
struct AgentOSServerSentEventDecoder {
    private static let maximumEventBytes = 1_048_576
    private var line: [UInt8] = []
    private var eventBytes = 0
    private var previousWasCR = false
    private var firstLine = true
    private var eventID: String?
    private var eventName: String?
    private var dataLines: [String] = []
    private var retry: Int?

    mutating func append(_ byte: UInt8) throws -> ServerSentEvent? {
        if previousWasCR {
            previousWasCR = false
            if byte == 10 { return nil }
        }
        eventBytes += 1
        guard eventBytes <= Self.maximumEventBytes else {
            throw AgentOSClientError.invalidResponse
        }
        if byte == 13 || byte == 10 {
            previousWasCR = byte == 13
            return try consumeLine()
        }
        line.append(byte)
        return nil
    }

    func finish() throws {
        guard line.isEmpty, dataLines.isEmpty, eventName == nil else {
            throw AgentOSClientError.invalidResponse
        }
    }

    private mutating func consumeLine() throws -> ServerSentEvent? {
        guard var text = String(bytes: line, encoding: .utf8) else {
            throw AgentOSClientError.invalidResponse
        }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty {
            let event = dataLines.isEmpty ? nil : ServerSentEvent(
                id: eventID,
                event: eventName,
                data: dataLines.joined(separator: "\n"),
                retryMilliseconds: retry
            )
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
            return event
        }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "id":
            if !value.contains("\0") { eventID = value }
        case "event": eventName = value
        case "data": dataLines.append(value)
        case "retry":
            if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
               let milliseconds = Int(value) { retry = milliseconds }
        default: break
        }
        return nil
    }
}
