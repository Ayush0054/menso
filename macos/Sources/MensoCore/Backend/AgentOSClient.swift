import Foundation

public struct BearerAccessToken: Sendable, Hashable {
    public let value: String
    public let expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

public protocol AgentOSAccessTokenProvider: Sendable {
    func accessToken() async throws -> BearerAccessToken
}

public struct VerifiedAgentOSAuthenticationContext: Sendable, Hashable {
    public let userID: UserID
    public let scopes: Set<String>

    public init(userID: UserID, scopes: Set<String>) {
        self.userID = userID
        self.scopes = scopes
    }
}

/// Fetches identity after AgentOS middleware verifies the bearer token. The
/// client never treats locally entered JWT claims or user IDs as authority.
public struct AgentOSVerifiedAuthenticationContextClient: Sendable {
    private struct Response: Decodable {
        let userID: String
        let scopes: [String]

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case scopes
        }
    }

    private let configuration: AgentOSConnectionConfiguration
    private let tokenProvider: any AgentOSAccessTokenProvider
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        configuration: AgentOSConnectionConfiguration,
        tokenProvider: any AgentOSAccessTokenProvider,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.session = session
        self.now = now
    }

    public func fetchContext() async throws -> VerifiedAgentOSAuthenticationContext {
        let token = try await tokenProvider.accessToken()
        guard !token.value.isEmpty, token.expiresAt > now() else {
            throw AgentOSClientError.expiredAccessToken
        }
        let url = configuration.baseURL
            .appendingPathComponent("menso", isDirectory: true)
            .appendingPathComponent("auth", isDirectory: true)
            .appendingPathComponent("context", isDirectory: false)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentOSClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentOSClientError.httpStatus(http.statusCode)
        }
        guard data.count <= 64 * 1_024 else { throw AgentOSClientError.invalidResponse }
        let context = try JSONDecoder().decode(Response.self, from: data)
        guard !context.userID.isEmpty, context.userID.utf8.count <= 512 else {
            throw AgentOSClientError.invalidResponse
        }
        return VerifiedAgentOSAuthenticationContext(
            userID: UserID(rawValue: context.userID),
            scopes: Set(context.scopes.filter { !$0.isEmpty && $0.utf8.count <= 256 })
        )
    }
}

public struct AgentOSConnectionConfiguration: Sendable, Hashable {
    public let baseURL: URL

    public init(baseURL: URL) throws {
        let scheme = baseURL.scheme?.lowercased()
        let host = baseURL.host?.lowercased()
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw AgentOSClientError.insecureBaseURL
        }
        guard baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw AgentOSClientError.invalidBaseURL
        }
        self.baseURL = baseURL
    }
}

public struct ServerSentEvent: Sendable, Hashable {
    public let id: String?
    public let event: String?
    public let data: String
    public let retryMilliseconds: Int?

    public init(id: String?, event: String?, data: String, retryMilliseconds: Int?) {
        self.id = id
        self.event = event
        self.data = data
        self.retryMilliseconds = retryMilliseconds
    }

    public func decodeData<T: Decodable & Sendable>(as type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: Data(data.utf8))
    }
}

public struct AgentRunRequest: Sendable, Hashable {
    public let agentID: String
    public let message: String
    public let sessionID: ProductSessionID
    public let userID: UserID
    public let background: Bool

    public init(
        agentID: String,
        message: String,
        sessionID: ProductSessionID,
        userID: UserID,
        background: Bool = false
    ) {
        self.agentID = agentID
        self.message = message
        self.sessionID = sessionID
        self.userID = userID
        self.background = background
    }
}

public struct WorkflowRunRequest: Sendable, Hashable {
    public let workflowID: String
    public let message: String
    public let sessionID: ProductSessionID
    public let userID: UserID
    public let version: Int?

    public init(
        workflowID: String,
        message: String,
        sessionID: ProductSessionID,
        userID: UserID,
        version: Int? = nil
    ) {
        self.workflowID = workflowID
        self.message = message
        self.sessionID = sessionID
        self.userID = userID
        self.version = version
    }
}

public typealias AgentOSEventStream = AsyncThrowingStream<ServerSentEvent, Error>

public protocol AgentOSRunClient: Sendable {
    func startAgentRun(_ request: AgentRunRequest) async throws -> AgentOSEventStream
    func startWorkflowRun(_ request: WorkflowRunRequest) async throws -> AgentOSEventStream
    func continueAgentRun(_ continuation: AgentRunContinuation) async throws -> AgentOSEventStream
    func continueWorkflowRun(_ continuation: WorkflowRunContinuation) async throws -> AgentOSEventStream
}

public actor AuthenticatedAgentOSRunClient: AgentOSRunClient {
    private let configuration: AgentOSConnectionConfiguration
    private let tokenProvider: any AgentOSAccessTokenProvider
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder

    public init(
        configuration: AgentOSConnectionConfiguration,
        tokenProvider: any AgentOSAccessTokenProvider,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.session = session
        self.now = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func startAgentRun(_ request: AgentRunRequest) async throws -> AgentOSEventStream {
        let url = try endpoint(["agents", request.agentID, "runs"])
        let boundary = "Menso-\(UUID().uuidString)"
        let fields = [
            ("message", request.message),
            ("stream", "true"),
            ("session_id", request.sessionID.rawValue),
            ("user_id", request.userID.rawValue),
            ("background", request.background ? "true" : "false"),
        ]
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = Self.multipartBody(fields: fields, boundary: boundary)
        return try await authenticatedStream(
            for: urlRequest,
            expectedUserID: request.userID
        )
    }

    public func startWorkflowRun(_ request: WorkflowRunRequest) async throws -> AgentOSEventStream {
        var fields = [
            ("message", request.message),
            ("stream", "true"),
            ("session_id", request.sessionID.rawValue),
            ("user_id", request.userID.rawValue),
        ]
        if let version = request.version {
            fields.append(("version", String(version)))
        }
        return try await formStream(
            endpoint: try endpoint(["workflows", request.workflowID, "runs"]),
            fields: fields,
            expectedUserID: request.userID
        )
    }

    public func continueAgentRun(_ continuation: AgentRunContinuation) async throws -> AgentOSEventStream {
        let toolsData = try encoder.encode(continuation.tools)
        guard let tools = String(data: toolsData, encoding: .utf8) else {
            throw AgentOSClientError.encodingFailed
        }
        return try await formStream(
            endpoint: try endpoint(["agents", continuation.agentID, "runs", continuation.runID, "continue"]),
            fields: [
                ("tools", tools),
                ("session_id", continuation.sessionID.rawValue),
                ("user_id", continuation.userID.rawValue),
                ("stream", continuation.stream ? "true" : "false"),
            ],
            expectedUserID: continuation.userID
        )
    }

    public func continueWorkflowRun(_ continuation: WorkflowRunContinuation) async throws -> AgentOSEventStream {
        let requirementsData = try encoder.encode(continuation.stepRequirements)
        guard let requirements = String(data: requirementsData, encoding: .utf8) else {
            throw AgentOSClientError.encodingFailed
        }
        var fields = [
            ("step_requirements", requirements),
            ("session_id", continuation.sessionID.rawValue),
            ("user_id", continuation.userID.rawValue),
            ("stream", continuation.stream ? "true" : "false"),
        ]
        if let factoryInput = continuation.factoryInput {
            let inputData = try encoder.encode(factoryInput)
            guard let input = String(data: inputData, encoding: .utf8) else {
                throw AgentOSClientError.encodingFailed
            }
            fields.append(("factory_input", input))
        }
        return try await formStream(
            endpoint: try endpoint(
                ["workflows", continuation.workflowID, "runs", continuation.runID, "continue"]
            ),
            fields: fields,
            expectedUserID: continuation.userID
        )
    }

    private func formStream(
        endpoint: URL,
        fields: [(String, String)],
        expectedUserID: UserID
    ) async throws -> AgentOSEventStream {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(fields).utf8)
        return try await authenticatedStream(
            for: request,
            expectedUserID: expectedUserID
        )
    }

    private func authenticatedStream(
        for request: URLRequest,
        expectedUserID: UserID
    ) async throws -> AgentOSEventStream {
        let token = try await tokenProvider.accessToken()
        guard !token.value.isEmpty, token.expiresAt > now() else {
            throw AgentOSClientError.expiredAccessToken
        }
        let fixedTokenProvider = FixedBearerAccessTokenProvider(token: token)
        let verified = try await AgentOSVerifiedAuthenticationContextClient(
            configuration: configuration,
            tokenProvider: fixedTokenProvider,
            session: session,
            now: now
        ).fetchContext()
        guard verified.userID == expectedUserID else {
            throw AgentOSClientError.authenticatedIdentityMismatch
        }

        var authenticated = request
        authenticated.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        authenticated.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authenticated.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let session = self.session
        let (bytes, response) = try await session.bytes(for: authenticated)
        guard let http = response as? HTTPURLResponse else {
            throw AgentOSClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentOSClientError.httpStatus(http.statusCode)
        }

        // Returning the stream now means the server accepted the request. This
        // ordering lets durable inbound caches become terminal only after a 2xx.
        return AgentOSEventStream { continuation in
            let task = Task {
                do {
                    try await Self.parseSSE(bytes: bytes, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func endpoint(_ components: [String]) throws -> URL {
        guard components.allSatisfy(Self.isSafePathComponent) else {
            throw AgentOSClientError.invalidPathIdentifier
        }
        return components.reduce(configuration.baseURL) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return component.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func formEncode(_ fields: [(String, String)]) -> String {
        fields.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func multipartBody(fields: [(String, String)], boundary: String) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private static func parseSSE(
        bytes: URLSession.AsyncBytes,
        continuation: AgentOSEventStream.Continuation
    ) async throws {
        var eventID: String?
        var eventName: String?
        var dataLines: [String] = []
        var retry: Int?

        func emit() {
            guard eventID != nil || eventName != nil || !dataLines.isEmpty || retry != nil else { return }
            continuation.yield(
                ServerSentEvent(
                    id: eventID,
                    event: eventName,
                    data: dataLines.joined(separator: "\n"),
                    retryMilliseconds: retry
                )
            )
            eventID = nil
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
            retry = nil
        }

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            if rawLine.isEmpty {
                emit()
                continue
            }
            if rawLine.hasPrefix(":") { continue }

            let pieces = rawLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let field = String(pieces[0])
            var value = pieces.count == 2 ? String(pieces[1]) : ""
            if value.hasPrefix(" ") { value.removeFirst() }

            switch field {
            case "id": eventID = value
            case "event": eventName = value
            case "data": dataLines.append(value)
            case "retry": retry = Int(value)
            default: continue
            }
        }
        emit()
    }
}

public struct FixedBearerAccessTokenProvider: AgentOSAccessTokenProvider {
    let token: BearerAccessToken

    public init(token: BearerAccessToken) {
        self.token = token
    }

    public func accessToken() async throws -> BearerAccessToken { token }
}

public enum AgentOSClientError: Error, Sendable, Equatable {
    case insecureBaseURL
    case invalidBaseURL
    case invalidPathIdentifier
    case expiredAccessToken
    case authenticatedIdentityMismatch
    case encodingFailed
    case invalidResponse
    case httpStatus(Int)
}
