import Foundation

public struct SignalID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum SignalSource: String, Codable, Hashable, Sendable {
    case claudeHook = "claude_hook"
    case codexNotification = "codex_notification"
    case accessibilityDialog = "accessibility_dialog"
}

public struct ClaudeLifecycleSignal: Codable, Hashable, Sendable {
    public let eventName: String
    public let sessionID: String
    public let workingDirectory: String
    public let payload: [String: JSONValue]

    public init(
        eventName: String,
        sessionID: String,
        workingDirectory: String,
        payload: [String: JSONValue]
    ) {
        self.eventName = eventName
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case eventName = "event_name"
        case sessionID = "session_id"
        case workingDirectory = "working_directory"
        case payload
    }
}

public struct ClaudePermissionSignal: Codable, Hashable, Sendable {
    public let sessionID: String
    public let workingDirectory: String
    public let permissionMode: String
    public let toolName: String
    public let toolInput: [String: JSONValue]
    public let permissionSuggestions: [JSONValue]

    public init(
        sessionID: String,
        workingDirectory: String,
        permissionMode: String,
        toolName: String,
        toolInput: [String: JSONValue],
        permissionSuggestions: [JSONValue]
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.permissionMode = permissionMode
        self.toolName = toolName
        self.toolInput = toolInput
        self.permissionSuggestions = permissionSuggestions
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case workingDirectory = "working_directory"
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case permissionSuggestions = "permission_suggestions"
    }
}

public struct AttentionSignal: Codable, Hashable, Sendable {
    public let applicationIdentifier: String
    public let title: String
    public let detail: String?

    public init(applicationIdentifier: String, title: String, detail: String? = nil) {
        self.applicationIdentifier = applicationIdentifier
        self.title = title
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case applicationIdentifier = "application_identifier"
        case title
        case detail
    }
}

/// Payload text is attacker-controlled context. No case contains policy or executable authority.
public enum UntrustedSignalPayload: Codable, Hashable, Sendable {
    case claudeLifecycle(ClaudeLifecycleSignal)
    case claudePermission(ClaudePermissionSignal)
    case attention(AttentionSignal)

    private enum CodingKeys: String, CodingKey {
        case kind
        case claudeLifecycle = "claude_lifecycle"
        case claudePermission = "claude_permission"
        case attention
    }

    private enum Kind: String, Codable {
        case claudeLifecycle = "claude_lifecycle"
        case claudePermission = "claude_permission"
        case attention
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .claudeLifecycle:
            self = .claudeLifecycle(try container.decode(ClaudeLifecycleSignal.self, forKey: .claudeLifecycle))
        case .claudePermission:
            self = .claudePermission(try container.decode(ClaudePermissionSignal.self, forKey: .claudePermission))
        case .attention:
            self = .attention(try container.decode(AttentionSignal.self, forKey: .attention))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .claudeLifecycle(value):
            try container.encode(Kind.claudeLifecycle, forKey: .kind)
            try container.encode(value, forKey: .claudeLifecycle)
        case let .claudePermission(value):
            try container.encode(Kind.claudePermission, forKey: .kind)
            try container.encode(value, forKey: .claudePermission)
        case let .attention(value):
            try container.encode(Kind.attention, forKey: .kind)
            try container.encode(value, forKey: .attention)
        }
    }
}

public struct SignalEnvelope: Codable, Hashable, Sendable {
    public let id: SignalID
    public let source: SignalSource
    public let receivedAt: Date
    public let expiresAt: Date?
    public let payload: UntrustedSignalPayload

    public init(
        id: SignalID,
        source: SignalSource,
        receivedAt: Date = Date(),
        expiresAt: Date? = nil,
        payload: UntrustedSignalPayload
    ) {
        self.id = id
        self.source = source
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case receivedAt = "received_at"
        case expiresAt = "expires_at"
        case payload
    }
}

public actor SignalBus {
    private var subscribers: [UUID: AsyncStream<SignalEnvelope>.Continuation] = [:]
    private var recentlyPublished: [SignalID: Date] = [:]
    private let deduplicationWindow: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        deduplicationWindow: TimeInterval = 3_600,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.deduplicationWindow = deduplicationWindow
        self.now = now
    }

    public func events(bufferLimit: Int = 256) -> AsyncStream<SignalEnvelope> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: SignalEnvelope.self,
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
        )
        subscribers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return pair.stream
    }

    @discardableResult
    public func publish(_ signal: SignalEnvelope) -> Bool {
        let currentDate = now()
        recentlyPublished = recentlyPublished.filter {
            currentDate.timeIntervalSince($0.value) < deduplicationWindow
        }
        guard recentlyPublished[signal.id] == nil,
              signal.expiresAt.map({ $0 > currentDate }) ?? true
        else {
            return false
        }
        recentlyPublished[signal.id] = currentDate
        for continuation in subscribers.values {
            continuation.yield(signal)
        }
        return true
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
