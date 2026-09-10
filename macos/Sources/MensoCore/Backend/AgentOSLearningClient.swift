import Foundation

public struct AgentOSLearningRecord: Codable, Identifiable, Sendable, Hashable {
    public let learningID: String
    public let learningType: String
    public let namespace: String?
    public let userID: String?
    public let agentID: String?
    public let sessionID: String?
    public let content: [String: JSONValue]?
    public let metadata: [String: JSONValue]?
    public let createdAt: Int64?
    public let updatedAt: Int64?

    public var id: String { learningID }

    enum CodingKeys: String, CodingKey {
        case learningID = "learning_id"
        case learningType = "learning_type"
        case namespace
        case userID = "user_id"
        case agentID = "agent_id"
        case sessionID = "session_id"
        case content
        case metadata
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public protocol AgentOSLearningManaging: Sendable {
    func userLearnings() async throws -> [AgentOSLearningRecord]
    func updateLearning(id: String, content: [String: JSONValue]) async throws -> AgentOSLearningRecord
    func deleteLearning(id: String) async throws
}

public actor AuthenticatedAgentOSLearningClient: AgentOSLearningManaging {
    private struct Page: Decodable {
        let data: [AgentOSLearningRecord]
    }

    private struct UpdateBody: Encodable {
        let content: [String: JSONValue]
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

    public func userLearnings() async throws -> [AgentOSLearningRecord] {
        let (token, identity) = try await authenticatedSnapshot()
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("learnings"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "sort_by", value: "updated_at"),
            URLQueryItem(name: "sort_order", value: "desc"),
        ]
        guard let url = components?.url else { throw AgentOSClientError.invalidBaseURL }
        let data = try await request(url: url, method: "GET", token: token, body: nil)
        return try JSONDecoder().decode(Page.self, from: data).data.filter {
            $0.userID == identity.userID.rawValue
        }
    }

    public func updateLearning(
        id: String,
        content: [String: JSONValue]
    ) async throws -> AgentOSLearningRecord {
        guard Self.safeIdentifier(id), !content.isEmpty else {
            throw AgentOSClientError.invalidPathIdentifier
        }
        let (token, identity) = try await authenticatedSnapshot()
        let url = configuration.baseURL
            .appendingPathComponent("learnings")
            .appendingPathComponent(id)
        let body = try JSONEncoder().encode(UpdateBody(content: content))
        let data = try await request(url: url, method: "PATCH", token: token, body: body)
        let record = try JSONDecoder().decode(AgentOSLearningRecord.self, from: data)
        guard record.userID == identity.userID.rawValue else {
            throw AgentOSClientError.authenticatedIdentityMismatch
        }
        return record
    }

    public func deleteLearning(id: String) async throws {
        guard Self.safeIdentifier(id) else { throw AgentOSClientError.invalidPathIdentifier }
        let (token, _) = try await authenticatedSnapshot()
        let url = configuration.baseURL
            .appendingPathComponent("learnings")
            .appendingPathComponent(id)
        _ = try await request(url: url, method: "DELETE", token: token, body: nil)
    }

    private func authenticatedSnapshot() async throws -> (
        BearerAccessToken,
        VerifiedAgentOSAuthenticationContext
    ) {
        let token = try await tokenProvider.accessToken()
        guard !token.value.isEmpty, token.expiresAt > now() else {
            throw AgentOSClientError.expiredAccessToken
        }
        let identity = try await AgentOSVerifiedAuthenticationContextClient(
            configuration: configuration,
            tokenProvider: FixedBearerAccessTokenProvider(token: token),
            session: session,
            now: now
        ).fetchContext()
        return (token, identity)
    }

    private func request(
        url: URL,
        method: String,
        token: BearerAccessToken,
        body: Data?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentOSClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentOSClientError.httpStatus(http.statusCode)
        }
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw AgentOSClientError.invalidResponse
        }
        return data
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}
