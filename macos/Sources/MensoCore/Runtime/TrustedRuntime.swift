import Foundation

public struct TrustedRuntimeCapabilities: Sendable, Hashable {
    public let backendContinuationConfigured: Bool
    public let liveVoiceConfigured: Bool

    public init(
        backendContinuationConfigured: Bool,
        liveVoiceConfigured: Bool
    ) {
        self.backendContinuationConfigured = backendContinuationConfigured
        self.liveVoiceConfigured = liveVoiceConfigured
    }
}

public protocol LiveVoiceRuntimeControlling: Sendable {
    func toggle() async throws
    func stop() async
    func updates() async -> AsyncStream<LiveVoiceUpdate>
}

public struct TrustedAgentOSRuntimeConfiguration: Sendable {
    public let client: any AgentOSRunClient
    public let authenticatedContextProvider: any AuthenticatedProductContextProviding

    public init(
        client: any AgentOSRunClient,
        authenticatedContextProvider: any AuthenticatedProductContextProviding
    ) {
        self.client = client
        self.authenticatedContextProvider = authenticatedContextProvider
    }
}

public struct TrustedRuntimeFeatureContext: Sendable {
    public let database: LocalDatabase
    public let policyEngine: PolicyEngine
    public let actionExecutor: ActionExecutor
    public let pauseCoordinator: RunPauseCoordinator
    public let runClient: any AgentOSRunClient
    public let streamHandler: AgentOSRunStreamIngestor
    public let authorityRegistry: TrustedRunAuthorityRegistry
    public let authenticatedContextProvider: any AuthenticatedProductContextProviding
}

public struct TrustedRuntimeFeatures: Sendable {
    public let liveVoiceRuntime: (any LiveVoiceRuntimeControlling)?
    public let voiceActionAuthorityStore: UserStagedVoiceActionAuthorityStore?

    public init(
        liveVoiceRuntime: (any LiveVoiceRuntimeControlling)? = nil,
        voiceActionAuthorityStore: UserStagedVoiceActionAuthorityStore? = nil
    ) {
        self.liveVoiceRuntime = liveVoiceRuntime
        self.voiceActionAuthorityStore = voiceActionAuthorityStore
    }
}

/// Composition root for the signed-client trust domain. AgentOS can propose a
/// Toolkit action, but target authority, review, CUA execution, and evidence
/// remain local to this graph.
public final class TrustedRuntime: @unchecked Sendable {
    public let database: LocalDatabase
    public let policyEngine: PolicyEngine
    public let actionExecutor: ActionExecutor
    public let pauseCoordinator: RunPauseCoordinator
    public let permissionHealthMonitor: PermissionHealthMonitor
    public let permissionRequestCoordinator: PermissionRequestCoordinator
    public let capabilities: TrustedRuntimeCapabilities
    public let runStreamHandler: AgentOSRunStreamIngestor?
    public let runAuthorityRegistry: TrustedRunAuthorityRegistry?
    public let liveVoiceRuntime: (any LiveVoiceRuntimeControlling)?
    public let voiceActionAuthorityStore: UserStagedVoiceActionAuthorityStore?

    private let cuaDriverHost: any CuaDriverHost
    private let durableContinuationDispatcher: DurableAgentOSRunContinuationDispatcher?
    private let agentOSRunClient: (any AgentOSRunClient)?
    private let authenticatedContextProvider: (any AuthenticatedProductContextProviding)?

    public init(
        database: LocalDatabase,
        policyConfiguration: ActionPolicyConfiguration = .denyAll,
        cuaDriverHost: any CuaDriverHost = UnavailableCuaDriverHost(),
        permissionAdapter: MacOSPermissionAdapter = MacOSPermissionAdapter(),
        featureBuilder: @Sendable (
            _ database: LocalDatabase,
            _ policyEngine: PolicyEngine,
            _ actionExecutor: ActionExecutor,
            _ pauseCoordinator: RunPauseCoordinator
        ) -> TrustedRuntimeFeatures = { _, _, _, _ in TrustedRuntimeFeatures() }
    ) {
        let actionStore = database.actionStore
        let policyEngine = PolicyEngine(configuration: policyConfiguration, auditSink: actionStore)
        let actionExecutor = ActionExecutor(
            policyEngine: policyEngine,
            broker: LocalToolBroker(host: cuaDriverHost),
            auditSink: actionStore,
            resultStore: actionStore,
            secureInput: MacOSSecureInputStateProvider()
        )
        let pauseCoordinator = RunPauseCoordinator(
            policyEngine: policyEngine,
            actionExecutor: actionExecutor,
            auditSink: actionStore
        )
        let features = featureBuilder(
            database,
            policyEngine,
            actionExecutor,
            pauseCoordinator
        )

        self.database = database
        self.policyEngine = policyEngine
        self.actionExecutor = actionExecutor
        self.pauseCoordinator = pauseCoordinator
        self.permissionHealthMonitor = PermissionHealthMonitor(checker: permissionAdapter)
        self.permissionRequestCoordinator = PermissionRequestCoordinator(
            checker: permissionAdapter,
            prompter: permissionAdapter
        )
        self.capabilities = TrustedRuntimeCapabilities(
            backendContinuationConfigured: false,
            liveVoiceConfigured: features.liveVoiceRuntime != nil
        )
        self.runStreamHandler = nil
        self.runAuthorityRegistry = nil
        self.liveVoiceRuntime = features.liveVoiceRuntime
        self.voiceActionAuthorityStore = features.voiceActionAuthorityStore
        self.cuaDriverHost = cuaDriverHost
        self.durableContinuationDispatcher = nil
        self.agentOSRunClient = nil
        self.authenticatedContextProvider = nil
    }

    public init(
        database: LocalDatabase,
        agentOS: TrustedAgentOSRuntimeConfiguration,
        policyConfiguration: ActionPolicyConfiguration = .denyAll,
        cuaDriverHost: any CuaDriverHost = UnavailableCuaDriverHost(),
        permissionAdapter: MacOSPermissionAdapter = MacOSPermissionAdapter(),
        featureBuilder: @Sendable (TrustedRuntimeFeatureContext) -> TrustedRuntimeFeatures
    ) throws {
        let actionStore = database.actionStore
        let policyEngine = PolicyEngine(configuration: policyConfiguration, auditSink: actionStore)
        let actionExecutor = ActionExecutor(
            policyEngine: policyEngine,
            broker: LocalToolBroker(host: cuaDriverHost),
            auditSink: actionStore,
            resultStore: actionStore,
            secureInput: MacOSSecureInputStateProvider()
        )
        let registry = TrustedRunAuthorityRegistry(persistence: database.trustedRunAuthorityStore)
        let streamHandler = AgentOSRunStreamIngestor(authorityRegistry: registry)
        let dispatcher = DurableAgentOSRunContinuationDispatcher(
            client: agentOS.client,
            streamHandler: streamHandler,
            outbox: database.runContinuationOutbox
        )
        let pauseCoordinator = RunPauseCoordinator(
            policyEngine: policyEngine,
            actionExecutor: actionExecutor,
            auditSink: actionStore,
            pendingReviewStore: database.pendingRunReviewStore,
            continuationDispatcher: dispatcher
        )
        try streamHandler.bind(to: pauseCoordinator)
        let context = TrustedRuntimeFeatureContext(
            database: database,
            policyEngine: policyEngine,
            actionExecutor: actionExecutor,
            pauseCoordinator: pauseCoordinator,
            runClient: agentOS.client,
            streamHandler: streamHandler,
            authorityRegistry: registry,
            authenticatedContextProvider: agentOS.authenticatedContextProvider
        )
        let features = featureBuilder(context)

        self.database = database
        self.policyEngine = policyEngine
        self.actionExecutor = actionExecutor
        self.pauseCoordinator = pauseCoordinator
        self.permissionHealthMonitor = PermissionHealthMonitor(checker: permissionAdapter)
        self.permissionRequestCoordinator = PermissionRequestCoordinator(
            checker: permissionAdapter,
            prompter: permissionAdapter
        )
        self.capabilities = TrustedRuntimeCapabilities(
            backendContinuationConfigured: true,
            liveVoiceConfigured: features.liveVoiceRuntime != nil
        )
        self.runStreamHandler = streamHandler
        self.runAuthorityRegistry = registry
        self.liveVoiceRuntime = features.liveVoiceRuntime
        self.voiceActionAuthorityStore = features.voiceActionAuthorityStore
        self.cuaDriverHost = cuaDriverHost
        self.durableContinuationDispatcher = dispatcher
        self.agentOSRunClient = agentOS.client
        self.authenticatedContextProvider = agentOS.authenticatedContextProvider
    }

    /// Starts the reusable Menso Agent. Open-ended chat has no local action
    /// authority. A desktop action must provide one exact semantic tool and one
    /// exact locally recognized target before the request is sent.
    public func startAgentRun(
        agentID: String,
        message: String,
        expectedTarget: ActionTarget? = nil,
        expectedOperation: ActionOperation? = nil,
        expiresAt: Date,
        background: Bool = false
    ) async throws {
        guard let agentOSRunClient, let authenticatedContextProvider,
              let runStreamHandler
        else { throw AgentOSRunStreamIngestorError.coordinatorUnavailable }
        switch (expectedTarget, expectedOperation) {
        case (nil, nil):
            break
        case let (.some(target), .some(operation))
            where operation.hasValidContentBinding
                && target.isStructurallyValid
                && target.matches(operation):
            break
        default:
            throw AgentOSRunStreamIngestorError.authorityConflict
        }

        let context = try await authenticatedContextProvider.authenticatedProductContext()
        let start = TrustedAgentRunStart(
            launchID: UUID().uuidString.lowercased(),
            agentID: agentID,
            authenticatedUserID: context.userID,
            authenticatedSessionID: context.sessionID,
            expectedTarget: expectedTarget,
            expectedOperation: expectedOperation,
            expiresAt: expiresAt
        )
        try await runStreamHandler.prepareAgentRunStart(start)
        let stream = try await agentOSRunClient.startAgentRun(
            AgentRunRequest(
                agentID: agentID,
                message: message,
                sessionID: context.sessionID,
                userID: context.userID,
                background: background
            )
        )
        try await runStreamHandler.handle(stream, origin: .startedAgent(start))
    }

    public func continuationDeliveryUpdates(
        bufferLimit: Int = 32
    ) async -> AsyncStream<RunContinuationDeliveryUpdate>? {
        guard let durableContinuationDispatcher else { return nil }
        return await durableContinuationDispatcher.deliveryUpdates(bufferLimit: bufferLimit)
    }

    public func retryContinuation(id: String) async throws {
        guard let durableContinuationDispatcher else {
            throw RunPauseCoordinatorError.continuationDispatcherUnavailable
        }
        try await durableContinuationDispatcher.retryContinuation(id: id)
    }

    public func start() async {
        _ = await permissionHealthMonitor.refresh()
        await pauseCoordinator.restorePendingReviews()
        await durableContinuationDispatcher?.startRetrying()
    }

    public func stop() async {
        await durableContinuationDispatcher?.stop()
        await liveVoiceRuntime?.stop()
        await cuaDriverHost.stop()
    }
}
