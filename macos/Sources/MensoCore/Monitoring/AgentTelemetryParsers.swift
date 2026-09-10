import CryptoKit
import Foundation

public protocol AgentTelemetryParsing: Sendable {
    var provider: AgentProvider { get }
    func parse(line: Data, sourcePath: String) -> TelemetryParseResult
}

public struct ClaudeCodeTelemetryParser: AgentTelemetryParsing {
    public let provider = AgentProvider.claudeCode

    public init() {}

    public func parse(line: Data, sourcePath: String) -> TelemetryParseResult {
        guard let root = TelemetryJSON.object(from: line) else {
            return .init(diagnostics: [
                .init(kind: .malformedJSON, sourcePath: sourcePath, message: "Skipped malformed Claude JSONL record"),
            ])
        }

        let message = TelemetryJSON.dictionary(root["message"])
        let recordType = TelemetryJSON.string(root["type"])
        let role = TelemetryJSON.string(message?["role"])
        guard recordType == "assistant" || role == "assistant" else { return .init() }
        guard let usageObject = TelemetryJSON.dictionary(message?["usage"] ?? root["usage"]) else {
            return .init()
        }

        let messageID = TelemetryJSON.string(message?["id"] ?? root["message_id"])
        let requestID = TelemetryJSON.string(
            root["requestId"] ?? root["request_id"] ?? message?["request_id"]
        )
        guard messageID != nil || requestID != nil else {
            return .init(diagnostics: [
                .init(kind: .missingIdentity, sourcePath: sourcePath, message: "Assistant usage had no message or request identifier"),
            ])
        }

        let usage = TokenUsage(
            input: TelemetryJSON.integer(usageObject["input_tokens"]),
            output: TelemetryJSON.integer(usageObject["output_tokens"]),
            cacheRead: TelemetryJSON.integer(usageObject["cache_read_input_tokens"]),
            cacheWrite: TelemetryJSON.integer(usageObject["cache_creation_input_tokens"])
        )
        guard usage.total > 0 else { return .init() }

        let sessionID = TelemetryJSON.string(
            root["sessionId"] ?? root["session_id"]
        ) ?? URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        let occurredAt = TelemetryJSON.date(
            root["timestamp"] ?? root["created_at"] ?? message?["created_at"]
        ) ?? .now
        let model = TelemetryJSON.string(message?["model"] ?? root["model"])
        let identity = [messageID, requestID].compactMap { $0 }.joined(separator: ":")
        let event = AgentUsageEvent(
            id: TelemetryJSON.digest("claude:\(identity)"),
            provider: provider,
            sessionID: sessionID,
            occurredAt: occurredAt,
            model: model,
            requestID: requestID,
            usage: usage,
            sourcePath: sourcePath
        )
        return .init(usageEvents: [event])
    }
}

public struct CodexTelemetryParser: AgentTelemetryParsing {
    public let provider = AgentProvider.codex

    public init() {}

    public func parse(line: Data, sourcePath: String) -> TelemetryParseResult {
        guard let root = TelemetryJSON.object(from: line) else {
            return .init(diagnostics: [
                .init(kind: .malformedJSON, sourcePath: sourcePath, message: "Skipped malformed Codex JSONL record"),
            ])
        }
        let payload = TelemetryJSON.dictionary(root["payload"]) ?? root
        guard TelemetryJSON.string(payload["type"]) == "token_count" else { return .init() }

        let information = TelemetryJSON.dictionary(payload["info"])
        let delta = TelemetryJSON.dictionary(
            information?["last_token_usage"]
                ?? payload["last_token_usage"]
        )
        let occurredAt = TelemetryJSON.date(root["timestamp"] ?? payload["timestamp"]) ?? .now
        let sessionID = TelemetryJSON.string(
            root["session_id"] ?? payload["session_id"] ?? root["sessionId"]
        ) ?? URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        let model = TelemetryJSON.string(
            payload["model"] ?? information?["model"] ?? root["model"]
        )

        var result = TelemetryParseResult()
        if let delta {
            let input = TelemetryJSON.integer(delta["input_tokens"])
            let output = TelemetryJSON.integer(delta["output_tokens"])
            let cached = TelemetryJSON.integer(
                delta["cached_input_tokens"] ?? delta["cache_read_input_tokens"]
            )
            let reasoning = TelemetryJSON.integer(
                delta["reasoning_output_tokens"] ?? delta["reasoning_tokens"]
            )
            let classifiedTotal = input + output + cached + reasoning
            let reportedTotal = TelemetryJSON.integer(delta["total_tokens"])
            let usage = TokenUsage(
                input: input,
                output: output,
                cacheRead: cached,
                reasoning: reasoning,
                uncategorized: max(0, reportedTotal - classifiedTotal)
            )
            let rawIdentity = TelemetryJSON.digest(data: line)
            if usage.total > 0 {
                result.usageEvents = [
                    AgentUsageEvent(
                        id: TelemetryJSON.digest("codex:\(sessionID):\(rawIdentity)"),
                        provider: provider,
                        sessionID: sessionID,
                        occurredAt: occurredAt,
                        model: model,
                        requestID: nil,
                        usage: usage,
                        sourcePath: sourcePath
                    ),
                ]
            }
        }

        if let rateLimits = TelemetryJSON.dictionary(
            information?["rate_limits"] ?? payload["rate_limits"] ?? root["rate_limits"]
        ) {
            result.rateLimits = parseRateLimits(rateLimits, observedAt: occurredAt)
        }
        return result
    }

    private func parseRateLimits(
        _ rateLimits: [String: Any],
        observedAt: Date
    ) -> [AgentRateLimit] {
        ["primary", "secondary"].compactMap { key in
            guard let value = TelemetryJSON.dictionary(rateLimits[key]) else { return nil }
            let usedPercent = TelemetryJSON.double(value["used_percent"])
            guard usedPercent >= 0 else { return nil }
            let minutes = TelemetryJSON.integer(value["window_minutes"])
            let window: RateLimitWindow
            if key == "primary" || (minutes > 0 && minutes <= 360) {
                window = .fiveHour
            } else if key == "secondary" || minutes > 360 {
                window = .weekly
            } else {
                window = .unknown
            }
            return AgentRateLimit(
                provider: provider,
                window: window,
                usedPercent: usedPercent,
                resetsAt: TelemetryJSON.date(value["resets_at"]),
                isEstimate: false,
                observedAt: observedAt
            )
        }
    }
}

private enum TelemetryJSON {
    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    static func integer(_ value: Any?) -> Int64 {
        switch value {
        case let integer as Int:
            return Int64(integer)
        case let integer as Int64:
            return integer
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string) ?? 0
        default:
            return 0
        }
    }

    static func double(_ value: Any?) -> Double {
        switch value {
        case let double as Double:
            return double
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string) ?? -1
        default:
            return -1
        }
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        guard let string = string(value) else { return nil }
        if let seconds = Double(string) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    static func digest(_ value: String) -> String {
        digest(data: Data(value.utf8))
    }

    static func digest(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
