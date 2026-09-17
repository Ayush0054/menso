import Foundation

/// Verifies the account before negotiating GPT-Live through its trusted Menso backend.
/// This is a product bearer token, never an OpenAI project key or provider client secret.
public struct AuthenticatedLiveVoiceClientAccessProvider: LiveVoiceClientAccessProviding {
    private let configuration: AgentOSConnectionConfiguration
    private let tokenProvider: any AgentOSAccessTokenProvider
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        backendBaseURL: URL,
        tokenProvider: any AgentOSAccessTokenProvider,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.configuration = try AgentOSConnectionConfiguration(baseURL: backendBaseURL)
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
        let verified = try await AgentOSVerifiedAuthenticationContextClient(
            configuration: configuration,
            tokenProvider: FixedBearerAccessTokenProvider(token: token),
            session: session,
            now: now
        ).fetchContext()
        guard verified.userID == userID else {
            throw LiveVoiceClientAccessError.authenticatedIdentityMismatch
        }
        guard verified.scopes.contains("live:connect") || verified.scopes.contains("agent_os:admin") else {
            throw LiveVoiceClientAccessError.missingLiveScope
        }
        return try LiveVoiceClientAccess(
            endpoint: configuration.baseURL.appendingPathComponent("menso/live/session"),
            accessToken: token.value,
            expiresAt: token.expiresAt
        )
    }
}

public enum LiveVoiceClientAccessError: Error, Sendable, Equatable {
    case invalidProductIdentity
    case authenticatedIdentityMismatch
    case expiredBackendToken
    case missingLiveScope
}
