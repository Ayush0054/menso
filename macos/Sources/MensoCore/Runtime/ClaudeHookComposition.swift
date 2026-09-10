import Foundation

public struct RunPauseClaudePermissionReviewPresenter: ClaudePermissionReviewPresenting {
    private let coordinator: RunPauseCoordinator

    public init(coordinator: RunPauseCoordinator) {
        self.coordinator = coordinator
    }

    public func review(
        _ request: ClaudePermissionReviewRequest
    ) async -> ClaudePermissionReviewResult {
        await coordinator.reviewClaudePermission(request)
    }
}

public struct ClaudeHookRuntimeFactory: Sendable {
    private let secretStore: any SecureSecretDataStoring

    public init(secretStore: any SecureSecretDataStoring = KeychainSecretStore()) {
        self.secretStore = secretStore
    }

    /// Loads the user-provisioned token before the synchronous trusted-runtime
    /// feature-builder runs. There is no generated-at-start secret that the
    /// plugin could not know.
    public func provisionedConfiguration() async throws -> ClaudeHookReceiverConfiguration? {
        guard let token = try await secretStore.string(
            service: TrustedRuntimeProvisioningCoordinator.claudeHookKeychainService,
            account: TrustedRuntimeProvisioningCoordinator.claudeHookTokenAccount
        ) else { return nil }
        return try ClaudeHookReceiverConfiguration(bearerToken: token)
    }

    public func makeReceiver(
        configuration: ClaudeHookReceiverConfiguration,
        signalBus: SignalBus,
        pauseCoordinator: RunPauseCoordinator
    ) -> any ClaudeHookReceiving {
        let decisionProvider = RunPauseClaudePermissionDecisionProvider(
            presenter: RunPauseClaudePermissionReviewPresenter(
                coordinator: pauseCoordinator
            )
        )
        return LoopbackClaudeHookReceiver(
            configuration: configuration,
            handler: SignalBusClaudeHookHandler(
                signalBus: signalBus,
                decisionProvider: decisionProvider
            )
        )
    }
}
