import Foundation

public enum TrustedRuntimeProvisioningState: Sendable, Hashable {
    case unconfigured
    case configured(TrustedRuntimeConfigurationSummary)
}

/// App-owned configuration surface for authenticated AgentOS. Saving verifies the supplied bearer subject against the
/// backend before the credentials can become active on the next app launch.
public actor TrustedRuntimeProvisioningCoordinator {
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

    public func state() async throws -> TrustedRuntimeProvisioningState {
        let loader = TrustedRuntimeConfigurationLoader(
            settingsStore: settingsStore,
            secretStore: secretStore,
            now: now
        )
        if let summary = try await loader.summary() {
            return .configured(summary)
        }
        #if DEBUG
        if let summary = TrustedRuntimeConfigurationLoader.localDevelopmentSummary(now: now()) {
            return .configured(summary)
        }
        #endif
        return .unconfigured
    }

    public func save(_ request: TrustedRuntimeProvisioningRequest) async throws {
        let connection = try AgentOSConnectionConfiguration(baseURL: request.agentOSBaseURL)
        let token = BearerAccessToken(
            value: request.accessToken,
            expiresAt: request.accessTokenExpiresAt
        )
        let verified = try await AgentOSVerifiedAuthenticationContextClient(
            configuration: connection,
            tokenProvider: FixedBearerAccessTokenProvider(token: token),
            now: now
        ).fetchContext()
        guard !verified.userID.rawValue.isEmpty else {
            throw TrustedRuntimeConfigurationLoaderError.invalidSettings
        }
        let loader = TrustedRuntimeConfigurationLoader(
            settingsStore: settingsStore,
            secretStore: secretStore,
            now: now
        )
        try await loader.save(request)
    }

    public func clear() async throws {
        let loader = TrustedRuntimeConfigurationLoader(
            settingsStore: settingsStore,
            secretStore: secretStore,
            now: now
        )
        try await loader.clear()
    }

}
