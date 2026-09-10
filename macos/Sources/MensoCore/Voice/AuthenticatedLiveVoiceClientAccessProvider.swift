import Foundation

/// Fetches a short-lived Realtime credential from authenticated AgentOS. The backend derives the
/// user from the bearer JWT; user/session arguments are local product bindings and are never sent as authority.
public struct AuthenticatedLiveVoiceClientAccessProvider: LiveVoiceClientAccessProviding {
    private struct SecretResponse: Decodable {
        let value: String
        let expiresAt: TimeInterval
        let session: JSONValue

        enum CodingKeys: String, CodingKey {
            case value
            case expiresAt = "expires_at"
            case session
        }
    }

    public static let realtimeCallsEndpoint = URL(string: "https://api.openai.com/v1/realtime/calls")!

    private let configuration: AgentOSConnectionConfiguration
    private let clientSecretURL: URL
    private let tokenProvider: any AgentOSAccessTokenProvider
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        backendBaseURL: URL,
        tokenProvider: any AgentOSAccessTokenProvider,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let scheme = backendBaseURL.scheme?.lowercased()
        let host = backendBaseURL.host?.lowercased()
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback),
              backendBaseURL.user == nil,
              backendBaseURL.password == nil,
              backendBaseURL.query == nil,
              backendBaseURL.fragment == nil
        else {
            throw LiveVoiceClientAccessError.invalidBackendURL
        }
        let configuration = try AgentOSConnectionConfiguration(baseURL: backendBaseURL)
        self.configuration = configuration
        self.clientSecretURL = configuration.baseURL
            .appendingPathComponent("menso")
            .appendingPathComponent("realtime")
            .appendingPathComponent("client-secret")
        self.tokenProvider = tokenProvider
        self.session = session
        self.now = now
    }

    public func clientAccess(for userID: UserID, sessionID: ProductSessionID) async throws -> LiveVoiceClientAccess {
        guard !userID.rawValue.isEmpty, !sessionID.rawValue.isEmpty else {
            throw LiveVoiceClientAccessError.invalidProductIdentity
        }
        let token = try await tokenProvider.accessToken()
        guard !token.value.isEmpty, token.expiresAt > now() else {
            throw LiveVoiceClientAccessError.expiredBackendToken
        }
        // Use one token snapshot for both subject verification and secret
        // minting. A Keychain rotation between two independent reads must not
        // open a provider session under a different backend principal.
        let verified = try await AgentOSVerifiedAuthenticationContextClient(
            configuration: configuration,
            tokenProvider: FixedBearerAccessTokenProvider(token: token),
            session: session,
            now: now
        ).fetchContext()
        guard verified.userID == userID else {
            throw LiveVoiceClientAccessError.authenticatedIdentityMismatch
        }

        var request = URLRequest(url: clientSecretURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = Data()

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= 256 * 1_024,
              http.mimeType?.lowercased() == "application/json",
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") == true
        else {
            throw LiveVoiceClientAccessError.invalidResponse
        }
        let secret = try JSONDecoder().decode(SecretResponse.self, from: data)
        let expiresAt = Date(timeIntervalSince1970: secret.expiresAt)
        guard !secret.value.isEmpty, secret.session.objectValue != nil, expiresAt > now() else {
            throw LiveVoiceClientAccessError.expiredClientSecret
        }
        return try LiveVoiceClientAccess(
            endpoint: Self.realtimeCallsEndpoint,
            ephemeralCredential: secret.value,
            expiresAt: expiresAt
        )
    }
}

public enum LiveVoiceClientAccessError: Error, Sendable, Equatable {
    case invalidBackendURL
    case invalidProductIdentity
    case authenticatedIdentityMismatch
    case expiredBackendToken
    case invalidResponse
    case expiredClientSecret
}
