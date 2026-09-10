import CryptoKit
import Foundation
#if canImport(Network)
import Network
#endif

private func canonicalJSONHash(_ fields: [String: JSONValue]) -> ContentHash {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(JSONValue.object(fields))) ?? Data()
    return .sha256(of: String(decoding: data, as: UTF8.self))
}

public struct ClaudePermissionRequestInput: Codable, Hashable, Sendable {
    public let sessionID: String
    public let transcriptPath: String
    public let workingDirectory: String
    public let permissionMode: String
    public let hookEventName: String
    public let toolName: String
    public let toolInput: [String: JSONValue]
    public let permissionSuggestions: [JSONValue]

    public init(
        sessionID: String,
        transcriptPath: String,
        workingDirectory: String,
        permissionMode: String,
        hookEventName: String,
        toolName: String,
        toolInput: [String: JSONValue],
        permissionSuggestions: [JSONValue] = []
    ) {
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.workingDirectory = workingDirectory
        self.permissionMode = permissionMode
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.toolInput = toolInput
        self.permissionSuggestions = permissionSuggestions
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case workingDirectory = "cwd"
        case permissionMode = "permission_mode"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case permissionSuggestions = "permission_suggestions"
    }
}

public struct ClaudeHookLifecycleInput: Codable, Hashable, Sendable {
    public let sessionID: String
    public let transcriptPath: String
    public let workingDirectory: String
    public let permissionMode: String
    public let hookEventName: String
    public let fields: [String: JSONValue]

    public init(from decoder: Decoder) throws {
        let fields = try [String: JSONValue](from: decoder)
        guard let sessionID = fields["session_id"]?.stringValue,
              let transcriptPath = fields["transcript_path"]?.stringValue,
              let workingDirectory = fields["cwd"]?.stringValue,
              let permissionMode = fields["permission_mode"]?.stringValue,
              let hookEventName = fields["hook_event_name"]?.stringValue
        else {
            throw ClaudeHookReceiverError.malformedHookPayload
        }
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.workingDirectory = workingDirectory
        self.permissionMode = permissionMode
        self.hookEventName = hookEventName
        self.fields = fields
    }

    public func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
    }
}

public enum ClaudePermissionBehavior: String, Codable, Hashable, Sendable {
    case allow
    case deny
}

/// Current Claude Code PermissionRequest decision fields. `updatedPermissions` values are
/// intentionally lossless so a trusted UI may echo one of Claude's provided suggestions exactly.
public struct ClaudePermissionDecision: Encodable, Hashable, Sendable {
    public let behavior: ClaudePermissionBehavior
    public let updatedInput: [String: JSONValue]?
    public let updatedPermissions: [JSONValue]?
    public let message: String?
    public let interrupt: Bool?

    private init(
        behavior: ClaudePermissionBehavior,
        updatedInput: [String: JSONValue]? = nil,
        updatedPermissions: [JSONValue]? = nil,
        message: String? = nil,
        interrupt: Bool? = nil
    ) {
        self.behavior = behavior
        self.updatedInput = behavior == .allow ? updatedInput : nil
        self.updatedPermissions = behavior == .allow ? updatedPermissions : nil
        self.message = behavior == .deny ? message : nil
        self.interrupt = behavior == .deny ? interrupt : nil
    }

    public static func deny(message: String, interrupt: Bool = false) -> ClaudePermissionDecision {
        ClaudePermissionDecision(behavior: .deny, message: message, interrupt: interrupt)
    }

    public static func allowOnce(
        updatedInput: [String: JSONValue]? = nil
    ) -> ClaudePermissionDecision {
        ClaudePermissionDecision(behavior: .allow, updatedInput: updatedInput)
    }

    /// "Always allow" can only echo one exact suggestion supplied with this permission request.
    public static func allowUsingSuggestion(
        at index: Int,
        from request: ClaudePermissionRequestInput,
        updatedInput: [String: JSONValue]? = nil
    ) throws -> ClaudePermissionDecision {
        guard request.permissionSuggestions.indices.contains(index) else {
            throw ClaudeHookReceiverError.invalidPermissionSuggestion
        }
        return ClaudePermissionDecision(
            behavior: .allow,
            updatedInput: updatedInput,
            updatedPermissions: [request.permissionSuggestions[index]]
        )
    }

    enum CodingKeys: String, CodingKey {
        case behavior
        case updatedInput
        case updatedPermissions
        case message
        case interrupt
    }
}

public struct ClaudePermissionHookOutput: Encodable, Hashable, Sendable {
    public struct HookSpecificOutput: Encodable, Hashable, Sendable {
        public let hookEventName: String
        public let decision: ClaudePermissionDecision

        public init(decision: ClaudePermissionDecision) {
            self.hookEventName = "PermissionRequest"
            self.decision = decision
        }
    }

    public let hookSpecificOutput: HookSpecificOutput

    public init(decision: ClaudePermissionDecision) {
        self.hookSpecificOutput = HookSpecificOutput(decision: decision)
    }
}

public protocol ClaudePermissionDecisionProvider: Sendable {
    func decision(for request: ClaudePermissionRequestInput) async throws -> ClaudePermissionDecision
}

public struct ClaudePermissionReviewRequest: Identifiable, Sendable, Hashable {
    public let id: HumanReviewID
    public let actionID: ActionID
    public let input: ClaudePermissionRequestInput
    public let expiresAt: Date

    public init(
        id: HumanReviewID,
        actionID: ActionID,
        input: ClaudePermissionRequestInput,
        expiresAt: Date
    ) {
        self.id = id
        self.actionID = actionID
        self.input = input
        self.expiresAt = expiresAt
    }
}

public enum ClaudePermissionReviewResult: Sendable, Hashable {
    case allowOnce
    case allowSuggestion(Int)
    case deny
}

public protocol ClaudePermissionReviewPresenting: Sendable {
    func review(_ request: ClaudePermissionReviewRequest) async -> ClaudePermissionReviewResult
}

/// Bridges Claude's held HTTP hook to the same app-owned pending-action UI.
/// The receiver's bounded timeout remains authoritative: cancellation removes
/// the review and Claude falls back to its native permission surface.
public actor RunPauseClaudePermissionDecisionProvider: ClaudePermissionDecisionProvider {
    private let presenter: any ClaudePermissionReviewPresenting
    private let now: @Sendable () -> Date
    private let reviewLifetime: TimeInterval

    public init(
        presenter: any ClaudePermissionReviewPresenting,
        reviewLifetime: TimeInterval = 45,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.presenter = presenter
        self.reviewLifetime = min(max(reviewLifetime, 5), 50)
        self.now = now
    }

    public func decision(
        for request: ClaudePermissionRequestInput
    ) async throws -> ClaudePermissionDecision {
        let actionID = ActionID(
            rawValue: "claude-permission:\(request.sessionID):\(request.toolName):\(canonicalJSONHash(request.toolInput).rawValue)"
        )
        let review = ClaudePermissionReviewRequest(
            id: HumanReviewID(),
            actionID: actionID,
            input: request,
            expiresAt: now().addingTimeInterval(reviewLifetime)
        )
        switch await presenter.review(review) {
        case .allowOnce:
            return .allowOnce()
        case let .allowSuggestion(index):
            return try .allowUsingSuggestion(at: index, from: request)
        case .deny:
            return .deny(message: "Menso denied this Claude permission request.")
        }
    }
}

public struct DenyAllClaudePermissionDecisionProvider: ClaudePermissionDecisionProvider {
    public init() {}

    public func decision(for request: ClaudePermissionRequestInput) async throws -> ClaudePermissionDecision {
        .deny(message: "Menso has no approved rule for this permission request.")
    }
}

public protocol ClaudeHookEventHandling: Sendable {
    func resolvePermission(_ request: ClaudePermissionRequestInput) async throws -> ClaudePermissionDecision
    func ingestLifecycle(_ event: ClaudeHookLifecycleInput) async
}

public actor SignalBusClaudeHookHandler: ClaudeHookEventHandling {
    private let signalBus: SignalBus
    private let decisionProvider: any ClaudePermissionDecisionProvider

    public init(signalBus: SignalBus, decisionProvider: any ClaudePermissionDecisionProvider) {
        self.signalBus = signalBus
        self.decisionProvider = decisionProvider
    }

    public func resolvePermission(
        _ request: ClaudePermissionRequestInput
    ) async throws -> ClaudePermissionDecision {
        guard request.hookEventName == "PermissionRequest",
              !request.sessionID.isEmpty,
              !request.toolName.isEmpty
        else {
            return .deny(message: "Malformed Claude permission request.")
        }

        _ = await signalBus.publish(
            SignalEnvelope(
                id: SignalID(
                    rawValue: "claude:permission:\(request.sessionID):\(request.toolName):\(canonicalJSONHash(request.toolInput).rawValue)"
                ),
                source: .claudeHook,
                payload: .claudePermission(
                    ClaudePermissionSignal(
                        sessionID: request.sessionID,
                        workingDirectory: request.workingDirectory,
                        permissionMode: request.permissionMode,
                        toolName: request.toolName,
                        toolInput: request.toolInput,
                        permissionSuggestions: request.permissionSuggestions
                    )
                )
            )
        )
        return try await decisionProvider.decision(for: request)
    }

    public func ingestLifecycle(_ event: ClaudeHookLifecycleInput) async {
        _ = await signalBus.publish(
            SignalEnvelope(
                id: SignalID(
                    rawValue: "claude:lifecycle:\(event.sessionID):\(event.hookEventName):\(canonicalJSONHash(event.fields).rawValue)"
                ),
                source: .claudeHook,
                payload: .claudeLifecycle(
                    ClaudeLifecycleSignal(
                        eventName: event.hookEventName,
                        sessionID: event.sessionID,
                        workingDirectory: event.workingDirectory,
                        payload: event.fields
                    )
                )
            )
        )
    }
}

public enum ClaudeHookReceiverState: String, Codable, Hashable, Sendable {
    case stopped
    case starting
    case listening
    case failed
}

public protocol ClaudeHookReceiving: Sendable {
    func start() async throws
    func stop() async
    func state() async -> ClaudeHookReceiverState
}

public struct ClaudeHookReceiverConfiguration: Sendable {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 49_743
    public static let path = "/hook"
    public static let maximumBodyBytes = 256 * 1_024
    public static let maximumHeaderBytes = 32 * 1_024

    fileprivate let bearerTokenDigest: Data
    public let decisionTimeout: TimeInterval

    public init(bearerToken: String, decisionTimeout: TimeInterval = 50) throws {
        guard bearerToken.utf8.count >= 32,
              decisionTimeout > 0,
              decisionTimeout < 60
        else {
            throw ClaudeHookReceiverError.invalidConfiguration
        }
        self.bearerTokenDigest = Data(SHA256.hash(data: Data(bearerToken.utf8)))
        self.decisionTimeout = decisionTimeout
    }
}

#if canImport(Network)
private struct SendableNWConnection: @unchecked Sendable {
    let value: NWConnection
}

/// Fixed-loopback HTTP receiver for the installed Claude plugin. It accepts one bounded request per connection.
public actor LoopbackClaudeHookReceiver: ClaudeHookReceiving {
    private let configuration: ClaudeHookReceiverConfiguration
    private let handler: any ClaudeHookEventHandling
    private let queue = DispatchQueue(label: "com.menso.claude-hook", qos: .userInitiated)
    private var listener: NWListener?
    private var receiverState: ClaudeHookReceiverState = .stopped

    public init(configuration: ClaudeHookReceiverConfiguration, handler: any ClaudeHookEventHandling) {
        self.configuration = configuration
        self.handler = handler
    }

    public func state() -> ClaudeHookReceiverState {
        receiverState
    }

    public func start() async throws {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(ClaudeHookReceiverConfiguration.host),
            port: NWEndpoint.Port(rawValue: ClaudeHookReceiverConfiguration.port)!
        )
        let listener = try NWListener(using: parameters)
        receiverState = .starting
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.updateState(from: state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            let sendableConnection = SendableNWConnection(value: connection)
            Task { await self?.accept(sendableConnection) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        receiverState = .stopped
    }

    private func updateState(from state: NWListener.State) {
        switch state {
        case .ready: receiverState = .listening
        case .failed: receiverState = .failed
        case .cancelled: receiverState = .stopped
        default: break
        }
    }

    private func accept(_ wrapped: SendableNWConnection) async {
        guard Self.isLoopback(wrapped.value.endpoint) else {
            wrapped.value.cancel()
            return
        }
        wrapped.value.start(queue: queue)

        do {
            let request = try await readRequest(from: wrapped)
            let response = await respond(to: request)
            try await send(response, to: wrapped)
        } catch {
            try? await send(.badRequest, to: wrapped)
        }
        wrapped.value.cancel()
    }

    private func readRequest(from connection: SendableNWConnection) async throws -> HookHTTPRequest {
        var data = Data()
        var expectedTotal: Int?

        while data.count <= ClaudeHookReceiverConfiguration.maximumHeaderBytes
            + ClaudeHookReceiverConfiguration.maximumBodyBytes
        {
            let chunk = try await receiveChunk(from: connection)
            guard !chunk.isEmpty else { throw ClaudeHookReceiverError.truncatedRequest }
            data.append(chunk)

            if expectedTotal == nil,
               let markerRange = data.range(of: Data("\r\n\r\n".utf8))
            {
                let headerLength = markerRange.upperBound
                guard headerLength <= ClaudeHookReceiverConfiguration.maximumHeaderBytes else {
                    throw ClaudeHookReceiverError.requestTooLarge
                }
                let headerData = data[..<markerRange.lowerBound]
                guard let headerText = String(data: headerData, encoding: .utf8) else {
                    throw ClaudeHookReceiverError.malformedHTTPRequest
                }
                let contentLength = try Self.contentLength(in: headerText)
                guard contentLength <= ClaudeHookReceiverConfiguration.maximumBodyBytes else {
                    throw ClaudeHookReceiverError.requestTooLarge
                }
                expectedTotal = headerLength + contentLength
            }

            if let expectedTotal, data.count >= expectedTotal {
                return try Self.parseRequest(data.prefix(expectedTotal))
            }
        }
        throw ClaudeHookReceiverError.requestTooLarge
    }

    private func receiveChunk(from connection: SendableNWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.value.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ClaudeHookReceiverError.truncatedRequest)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func respond(to request: HookHTTPRequest) async -> HookHTTPResponse {
        guard request.method == "POST", request.path == ClaudeHookReceiverConfiguration.path else {
            return .notFound
        }
        guard let authorization = request.headers["authorization"],
              authorization.hasPrefix("Bearer "),
              constantTimeEqual(
                  Data(SHA256.hash(data: Data(authorization.dropFirst("Bearer ".count).utf8))),
                  configuration.bearerTokenDigest
              )
        else {
            return .unauthorized
        }

        let decoder = JSONDecoder()
        let eventName = (try? decoder.decode(JSONObjectEnvelope.self, from: request.body))?
            .fields["hook_event_name"]?.stringValue

        if eventName == "PermissionRequest" {
            do {
                let input = try decoder.decode(ClaudePermissionRequestInput.self, from: request.body)
                guard input.hookEventName == "PermissionRequest",
                      !input.sessionID.isEmpty,
                      !input.toolName.isEmpty
                else {
                    return .badRequest
                }
                let decision: ClaudePermissionDecision
                do {
                    decision = try await withTimeout(seconds: configuration.decisionTimeout) {
                        try await self.handler.resolvePermission(input)
                    }
                } catch ClaudeHookReceiverError.decisionTimedOut {
                    // Non-2xx makes Claude Code fall back to its native permission UI.
                    return .gatewayTimeout
                } catch {
                    return .serviceUnavailable
                }
                return try .json(ClaudePermissionHookOutput(decision: decision))
            } catch {
                return .badRequest
            }
        }

        do {
            let lifecycle = try decoder.decode(ClaudeHookLifecycleInput.self, from: request.body)
            await handler.ingestLifecycle(lifecycle)
            return .noContent
        } catch {
            return .badRequest
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ClaudeHookReceiverError.decisionTimedOut
            }
            guard let first = try await group.next() else {
                throw ClaudeHookReceiverError.decisionTimedOut
            }
            group.cancelAll()
            return first
        }
    }

    private func send(_ response: HookHTTPResponse, to connection: SendableNWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.value.send(content: response.encoded, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "127.0.0.1" || value == "::1" || value == "localhost"
    }

    private static func contentLength(in headerText: String) throws -> Int {
        let headers = parseHeaderLines(headerText)
        guard let value = headers["content-length"],
              let length = Int(value),
              length >= 0
        else {
            throw ClaudeHookReceiverError.missingContentLength
        }
        return length
    }

    private static func parseRequest(_ data: Data.SubSequence) throws -> HookHTTPRequest {
        let fullData = Data(data)
        guard let markerRange = fullData.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: fullData[..<markerRange.lowerBound], encoding: .utf8)
        else {
            throw ClaudeHookReceiverError.malformedHTTPRequest
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw ClaudeHookReceiverError.malformedHTTPRequest }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count == 3, requestParts[2] == "HTTP/1.1" else {
            throw ClaudeHookReceiverError.malformedHTTPRequest
        }
        return HookHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: parseHeaderLines(headerText),
            body: Data(fullData[markerRange.upperBound...])
        )
    }

    private static func parseHeaderLines(_ headerText: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            headers[String(pieces[0]).lowercased()] = String(pieces[1]).trimmingCharacters(in: .whitespaces)
        }
        return headers
    }
}

private struct HookHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct HookHTTPResponse: Sendable {
    let status: Int
    let reason: String
    let contentType: String?
    let body: Data

    static let noContent = HookHTTPResponse(status: 204, reason: "No Content", contentType: nil, body: Data())
    static let badRequest = HookHTTPResponse(status: 400, reason: "Bad Request", contentType: nil, body: Data())
    static let unauthorized = HookHTTPResponse(status: 401, reason: "Unauthorized", contentType: nil, body: Data())
    static let notFound = HookHTTPResponse(status: 404, reason: "Not Found", contentType: nil, body: Data())
    static let internalError = HookHTTPResponse(status: 500, reason: "Internal Server Error", contentType: nil, body: Data())
    static let serviceUnavailable = HookHTTPResponse(status: 503, reason: "Service Unavailable", contentType: nil, body: Data())
    static let gatewayTimeout = HookHTTPResponse(status: 504, reason: "Gateway Timeout", contentType: nil, body: Data())

    static func json<T: Encodable>(_ value: T) throws -> HookHTTPResponse {
        HookHTTPResponse(
            status: 200,
            reason: "OK",
            contentType: "application/json",
            body: try JSONEncoder().encode(value)
        )
    }

    var encoded: Data {
        var headers = "HTTP/1.1 \(status) \(reason)\r\n"
        if let contentType { headers += "Content-Type: \(contentType)\r\n" }
        headers += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        return response
    }
}
#endif

public enum ClaudeHookReceiverError: Error, Sendable, Equatable {
    case invalidConfiguration
    case malformedHTTPRequest
    case malformedHookPayload
    case missingContentLength
    case requestTooLarge
    case truncatedRequest
    case decisionTimedOut
    case invalidPermissionSuggestion
}
