import Foundation

public enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude_code"
    case codex
    case cursor
    case windsurf
    case unknown

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .unknown: "Agent"
        }
    }
}

public struct TokenUsage: Codable, Hashable, Sendable {
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var reasoning: Int64
    public var uncategorized: Int64

    public init(
        input: Int64 = 0,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        cacheWrite: Int64 = 0,
        reasoning: Int64 = 0,
        uncategorized: Int64 = 0
    ) {
        self.input = max(0, input)
        self.output = max(0, output)
        self.cacheRead = max(0, cacheRead)
        self.cacheWrite = max(0, cacheWrite)
        self.reasoning = max(0, reasoning)
        self.uncategorized = max(0, uncategorized)
    }

    public var total: Int64 {
        input + output + cacheRead + cacheWrite + reasoning + uncategorized
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reasoning: lhs.reasoning + rhs.reasoning,
            uncategorized: lhs.uncategorized + rhs.uncategorized
        )
    }
}

public struct AgentUsageEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: AgentProvider
    public let sessionID: String
    public let occurredAt: Date
    public let model: String?
    public let requestID: String?
    public let usage: TokenUsage
    public let sourcePath: String

    public init(
        id: String,
        provider: AgentProvider,
        sessionID: String,
        occurredAt: Date,
        model: String?,
        requestID: String?,
        usage: TokenUsage,
        sourcePath: String
    ) {
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.occurredAt = occurredAt
        self.model = model
        self.requestID = requestID
        self.usage = usage
        self.sourcePath = sourcePath
    }
}

public enum RateLimitWindow: String, Codable, Hashable, Sendable {
    case fiveHour = "five_hour"
    case weekly
    case unknown
}

public struct AgentRateLimit: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(provider.rawValue):\(window.rawValue)" }

    public let provider: AgentProvider
    public let window: RateLimitWindow
    public let usedPercent: Double
    public let resetsAt: Date?
    public let isEstimate: Bool
    public let observedAt: Date

    public init(
        provider: AgentProvider,
        window: RateLimitWindow,
        usedPercent: Double,
        resetsAt: Date?,
        isEstimate: Bool,
        observedAt: Date = .now
    ) {
        self.provider = provider
        self.window = window
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.isEstimate = isEstimate
        self.observedAt = observedAt
    }
}

public struct TelemetryParseDiagnostic: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case malformedJSON
        case unsupportedRecord
        case missingIdentity
        case invalidUsage
        case oversizedLine
    }

    public let kind: Kind
    public let sourcePath: String
    public let message: String

    public init(kind: Kind, sourcePath: String, message: String) {
        self.kind = kind
        self.sourcePath = sourcePath
        self.message = message
    }
}

public struct TelemetryParseResult: Sendable {
    public var usageEvents: [AgentUsageEvent]
    public var rateLimits: [AgentRateLimit]
    public var diagnostics: [TelemetryParseDiagnostic]

    public init(
        usageEvents: [AgentUsageEvent] = [],
        rateLimits: [AgentRateLimit] = [],
        diagnostics: [TelemetryParseDiagnostic] = []
    ) {
        self.usageEvents = usageEvents
        self.rateLimits = rateLimits
        self.diagnostics = diagnostics
    }
}

public struct AgentSessionSummary: Identifiable, Hashable, Sendable {
    public var id: String { "\(provider.rawValue):\(sessionID)" }

    public let provider: AgentProvider
    public let sessionID: String
    public let model: String?
    public let usage: TokenUsage
    public let lastActivityAt: Date
    public let isProcessRunning: Bool

    public init(
        provider: AgentProvider,
        sessionID: String,
        model: String?,
        usage: TokenUsage,
        lastActivityAt: Date,
        isProcessRunning: Bool
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.model = model
        self.usage = usage
        self.lastActivityAt = lastActivityAt
        self.isProcessRunning = isProcessRunning
    }
}

public struct AgentMonitorState: Sendable {
    public var sessions: [AgentSessionSummary]
    public var rateLimits: [AgentRateLimit]
    public var recentEvents: [AgentUsageEvent]
    public var diagnostics: [TelemetryParseDiagnostic]
    public var runningProviders: Set<AgentProvider>
    public var lastUpdatedAt: Date?

    public init(
        sessions: [AgentSessionSummary] = [],
        rateLimits: [AgentRateLimit] = [],
        recentEvents: [AgentUsageEvent] = [],
        diagnostics: [TelemetryParseDiagnostic] = [],
        runningProviders: Set<AgentProvider> = [],
        lastUpdatedAt: Date? = nil
    ) {
        self.sessions = sessions
        self.rateLimits = rateLimits
        self.recentEvents = recentEvents
        self.diagnostics = diagnostics
        self.runningProviders = runningProviders
        self.lastUpdatedAt = lastUpdatedAt
    }
}
