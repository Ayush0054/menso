import Foundation

public enum TrustedRuntimeConfigurationLoadResult: Sendable {
    case disabled(reason: String)
    case agentOS(
        LoadedTrustedAgentOSConfiguration,
        notice: String?
    )
}

public struct LoadedTrustedAgentOSConfiguration: Sendable {
    public let authenticatedContextProvider: any AuthenticatedProductContextProviding
    public let liveVoiceClientAccessProvider: (any LiveVoiceClientAccessProviding)?
    public let actionSelector: any VoiceActionSelecting

    public init(
        authenticatedContextProvider: any AuthenticatedProductContextProviding,
        liveVoiceClientAccessProvider: (any LiveVoiceClientAccessProviding)?,
        actionSelector: any VoiceActionSelecting
    ) {
        self.authenticatedContextProvider = authenticatedContextProvider
        self.liveVoiceClientAccessProvider = liveVoiceClientAccessProvider
        self.actionSelector = actionSelector
    }
}

public enum TrustedRuntimeConfigurationLoaderError: Error, Sendable, Equatable {
    case invalidSettings
    case invalidSecret
}

public struct TrustedRuntimeProvisioningRequest: Sendable, Hashable {
    public let agentOSBaseURL: URL
    public let sessionID: UUID
    public let accessToken: String
    public let accessTokenExpiresAt: Date

    public init(
        agentOSBaseURL: URL,
        sessionID: UUID = UUID(),
        accessToken: String,
        accessTokenExpiresAt: Date
    ) {
        self.agentOSBaseURL = agentOSBaseURL
        self.sessionID = sessionID
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }
}

public struct TrustedRuntimeConfigurationSummary: Sendable, Hashable {
    public let agentOSBaseURL: URL
    public let sessionID: UUID
    public let accessTokenExpiresAt: Date?

    public init(
        agentOSBaseURL: URL,
        sessionID: UUID,
        accessTokenExpiresAt: Date?
    ) {
        self.agentOSBaseURL = agentOSBaseURL
        self.sessionID = sessionID
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }
}

private struct PersistedTrustedRuntimeSettings: Codable, Sendable {
    let agentOSBaseURL: String
    let authenticatedSessionID: String

    enum CodingKeys: String, CodingKey {
        case agentOSBaseURL = "agentos_base_url"
        case authenticatedSessionID = "authenticated_session_id"
    }
}

/// Reads only app-owned configuration. Identity metadata lives in local SQLite;
/// bearer tokens remain in the Data Protection Keychain. Partial
/// configuration never starts a network client.
public struct TrustedRuntimeConfigurationLoader: Sendable {
    public static let settingsKey = "trusted-runtime.configuration.v1"
    public static let agentOSKeychainService = "com.menso.agentos"
    public static let agentOSAccessTokenAccount = "access-token"
    public static let agentOSAccessTokenExpiryAccount = "access-token-expiry"

    private let settingsStore: any SettingsPersisting
    private let secretStore: any SecureSecretDataStoring
    private let now: @Sendable () -> Date

    public init(
        settingsStore: any SettingsPersisting,
        secretStore: any SecureSecretDataStoring = KeychainSecretStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settingsStore = settingsStore
        self.secretStore = secretStore
        self.now = now
    }

    public func load() async -> TrustedRuntimeConfigurationLoadResult {
        do {
            let baseURL: URL
            let sessionID: String
            let tokenProvider: any AgentOSAccessTokenProvider

            if let data = try await settingsStore.data(forKey: Self.settingsKey), !data.isEmpty {
                let persisted = try JSONDecoder().decode(PersistedTrustedRuntimeSettings.self, from: data)
                guard let persistedBaseURL = URL(string: persisted.agentOSBaseURL),
                      UUID(uuidString: persisted.authenticatedSessionID) != nil
                else { throw TrustedRuntimeConfigurationLoaderError.invalidSettings }
                baseURL = persistedBaseURL
                sessionID = persisted.authenticatedSessionID
                tokenProvider = KeychainAgentOSAccessTokenProvider(
                    store: secretStore,
                    now: now
                )
            } else {
                #if DEBUG
                guard let local = Self.localDevelopmentConfiguration(now: now()) else {
                    return .disabled(reason: "AgentOS is disabled until an authenticated account is configured.")
                }
                baseURL = local.baseURL
                sessionID = local.sessionID
                tokenProvider = FixedBearerAccessTokenProvider(token: local.token)
                #else
                return .disabled(reason: "AgentOS is disabled until an authenticated account is configured.")
                #endif
            }

            let connection = try AgentOSConnectionConfiguration(baseURL: baseURL)
            // Validate presence and expiry before enabling any feature. Signed
            // builds re-read Keychain on every request; debug fallback tokens
            // remain bounded by their generated expiry and the next restart.
            _ = try await tokenProvider.accessToken()
            let contextClient = AgentOSVerifiedAuthenticationContextClient(
                configuration: connection,
                tokenProvider: tokenProvider
            )
            let verifiedContext = try await contextClient.fetchContext()
            let context = VerifiedAgentOSProductContextProvider(
                client: contextClient,
                sessionID: ProductSessionID(rawValue: sessionID)
            )
            // Construction above validates the session. This explicit check
            // ensures load has verified the current token subject before
            // enabling the runtime; the provider re-verifies on every use.
            guard !verifiedContext.userID.rawValue.isEmpty else {
                throw TrustedRuntimeConfigurationLoaderError.invalidSettings
            }
            let liveVoiceClientAccessProvider: (any LiveVoiceClientAccessProviding)?
            let liveVoiceNotice: String?
            if verifiedContext.scopes.contains("agent_os:admin")
                || verifiedContext.scopes.contains("live:connect")
            {
                liveVoiceClientAccessProvider = try AuthenticatedLiveVoiceClientAccessProvider(
                    backendBaseURL: baseURL,
                    tokenProvider: tokenProvider
                )
                liveVoiceNotice = nil
            } else {
                liveVoiceClientAccessProvider = nil
                liveVoiceNotice = "Live voice is disabled because the authenticated account lacks live:connect scope."
            }

            return .agentOS(
                LoadedTrustedAgentOSConfiguration(
                    authenticatedContextProvider: context,
                    liveVoiceClientAccessProvider: liveVoiceClientAccessProvider,
                    actionSelector: TypeSafeActionSelector(configuration: connection, tokenProvider: tokenProvider)
                ),
                notice: liveVoiceNotice
            )
        } catch {
            return .disabled(
                reason: "Trusted integrations are disabled because authenticated configuration is missing, expired, or invalid."
            )
        }
    }

    #if DEBUG
    private static func localDevelopmentConfiguration(
        now: Date
    ) -> (baseURL: URL, sessionID: String, token: BearerAccessToken)? {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let sourceRepositoryRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let candidateDirectories = [
            sourceRepositoryRoot.appendingPathComponent("backend/.local-auth", isDirectory: true),
            workingDirectory.appendingPathComponent("backend/.local-auth", isDirectory: true),
            workingDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("backend/.local-auth", isDirectory: true),
        ]

        for directory in candidateDirectories {
            let tokenURL = directory.appendingPathComponent("menso-local.jwt")
            let expiryURL = directory.appendingPathComponent("token-expiry.txt")
            guard let tokenValue = try? String(contentsOf: tokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !tokenValue.isEmpty,
                tokenValue.utf8.count <= 16 * 1_024,
                let expiryText = try? String(contentsOf: expiryURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                let expiry = KeychainAgentOSAccessTokenProvider.parseDate(expiryText),
                expiry > now.addingTimeInterval(30),
                let baseURL = URL(string: "http://127.0.0.1:8000")
            else { continue }

            return (
                baseURL,
                "00000000-0000-4000-8000-000000000001",
                BearerAccessToken(value: tokenValue, expiresAt: expiry)
            )
        }
        return nil
    }

    static func localDevelopmentSummary(now: Date) -> TrustedRuntimeConfigurationSummary? {
        guard let local = localDevelopmentConfiguration(now: now),
              let sessionID = UUID(uuidString: local.sessionID)
        else { return nil }
        return TrustedRuntimeConfigurationSummary(
            agentOSBaseURL: local.baseURL,
            sessionID: sessionID,
            accessTokenExpiresAt: local.token.expiresAt
        )
    }
    #endif

    /// Persists a complete configuration without ever storing or logging token
    /// contents outside the Keychain. The authenticated user ID is deliberately
    /// absent: load() always obtains it from AgentOS's verified context endpoint.
    public func save(_ request: TrustedRuntimeProvisioningRequest) async throws {
        _ = try AgentOSConnectionConfiguration(baseURL: request.agentOSBaseURL)
        guard !request.accessToken.isEmpty,
              request.accessToken.utf8.count <= 16 * 1_024,
              request.accessTokenExpiresAt > now().addingTimeInterval(30)
        else { throw TrustedRuntimeConfigurationLoaderError.invalidSecret }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try await secretStore.setString(
            request.accessToken,
            service: Self.agentOSKeychainService,
            account: Self.agentOSAccessTokenAccount
        )
        do {
            try await secretStore.setString(
                formatter.string(from: request.accessTokenExpiresAt),
                service: Self.agentOSKeychainService,
                account: Self.agentOSAccessTokenExpiryAccount
            )
            let persisted = PersistedTrustedRuntimeSettings(
                agentOSBaseURL: request.agentOSBaseURL.absoluteString,
                authenticatedSessionID: request.sessionID.uuidString.lowercased()
            )
            try await settingsStore.saveData(
                JSONEncoder().encode(persisted),
                forKey: Self.settingsKey
            )
        } catch {
            try? await clear()
            throw error
        }
    }

    /// Returns only non-secret configuration plus secret presence/expiry. Raw
    /// bearer tokens never leave the Keychain boundary for display.
    public func summary() async throws -> TrustedRuntimeConfigurationSummary? {
        guard let data = try await settingsStore.data(forKey: Self.settingsKey), !data.isEmpty else {
            return nil
        }
        let persisted = try JSONDecoder().decode(PersistedTrustedRuntimeSettings.self, from: data)
        guard let baseURL = URL(string: persisted.agentOSBaseURL),
              let sessionID = UUID(uuidString: persisted.authenticatedSessionID)
        else { throw TrustedRuntimeConfigurationLoaderError.invalidSettings }
        let expiry = try await secretStore.string(
            service: Self.agentOSKeychainService,
            account: Self.agentOSAccessTokenExpiryAccount
        ).flatMap(KeychainAgentOSAccessTokenProvider.parseDate)
        return TrustedRuntimeConfigurationSummary(
            agentOSBaseURL: baseURL,
            sessionID: sessionID,
            accessTokenExpiresAt: expiry
        )
    }

    public func clear() async throws {
        var firstError: Error?
        do { try await settingsStore.saveData(Data(), forKey: Self.settingsKey) }
        catch { firstError = firstError ?? error }
        for item in [
            (Self.agentOSKeychainService, Self.agentOSAccessTokenAccount),
            (Self.agentOSKeychainService, Self.agentOSAccessTokenExpiryAccount),
        ] {
            do { try await secretStore.delete(service: item.0, account: item.1) }
            catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }
}

public struct KeychainAgentOSAccessTokenProvider: AgentOSAccessTokenProvider {
    private let store: any SecureSecretDataStoring
    private let now: @Sendable () -> Date

    public init(
        store: any SecureSecretDataStoring,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
    }

    public func accessToken() async throws -> BearerAccessToken {
        guard let value = try await store.string(
            service: TrustedRuntimeConfigurationLoader.agentOSKeychainService,
            account: TrustedRuntimeConfigurationLoader.agentOSAccessTokenAccount
        ),
        !value.isEmpty,
        value.utf8.count <= 16 * 1_024,
        let expiryValue = try await store.string(
            service: TrustedRuntimeConfigurationLoader.agentOSKeychainService,
            account: TrustedRuntimeConfigurationLoader.agentOSAccessTokenExpiryAccount
        ),
        let expiry = Self.parseDate(expiryValue),
        expiry > now()
        else { throw TrustedRuntimeConfigurationLoaderError.invalidSecret }
        return BearerAccessToken(value: value, expiresAt: expiry)
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

public struct VerifiedAgentOSProductContextProvider: AuthenticatedProductContextProviding {
    private let client: AgentOSVerifiedAuthenticationContextClient
    private let sessionID: ProductSessionID

    public init(
        client: AgentOSVerifiedAuthenticationContextClient,
        sessionID: ProductSessionID
    ) {
        self.client = client
        self.sessionID = sessionID
    }

    public func authenticatedProductContext() async throws -> AuthenticatedProductContext {
        let verified = try await client.fetchContext()
        return try AuthenticatedProductContext(
            userID: verified.userID,
            sessionID: sessionID
        )
    }
}
