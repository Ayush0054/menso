import Foundation

/// App-owned authority prepared before an Agent run crosses the network. A
/// voice run may carry native observations instead of a preselected operation.
/// Its first proposal is matched locally, persisted, and reviewed before use.
/// Runs with neither an exact binding nor native context fail closed.
public struct TrustedAgentRunStart: Codable, Sendable, Hashable {
    public let launchID: String
    public let agentID: String
    public let authenticatedUserID: UserID
    public let authenticatedSessionID: ProductSessionID
    public let expectedTarget: ActionTarget?
    public let expectedOperation: ActionOperation?
    public let expiresAt: Date
    public let voiceActionContext: VoiceActionContext?
    public let resolvedToolCallID: String?

    public init(
        launchID: String,
        agentID: String,
        authenticatedUserID: UserID,
        authenticatedSessionID: ProductSessionID,
        expectedTarget: ActionTarget?,
        expectedOperation: ActionOperation?,
        expiresAt: Date,
        voiceActionContext: VoiceActionContext? = nil,
        resolvedToolCallID: String? = nil
    ) {
        self.launchID = launchID
        self.agentID = agentID
        self.authenticatedUserID = authenticatedUserID
        self.authenticatedSessionID = authenticatedSessionID
        self.expectedTarget = expectedTarget
        self.expectedOperation = expectedOperation
        self.expiresAt = expiresAt
        self.voiceActionContext = voiceActionContext
        self.resolvedToolCallID = resolvedToolCallID
    }
}

/// Generic Workflow identity retained only so Agent and Workflow transports
/// remain distinct. Menso currently does not grant desktop-action authority to
/// a Workflow; a Workflow pause is preserved and rejected as unsupported.
public struct TrustedWorkflowRunStart: Codable, Sendable, Hashable {
    public let launchID: String
    public let workflowID: String
    public let authenticatedUserID: UserID
    public let authenticatedSessionID: ProductSessionID
    public let expiresAt: Date

    public init(
        launchID: String,
        workflowID: String,
        authenticatedUserID: UserID,
        authenticatedSessionID: ProductSessionID,
        expiresAt: Date
    ) {
        self.launchID = launchID
        self.workflowID = workflowID
        self.authenticatedUserID = authenticatedUserID
        self.authenticatedSessionID = authenticatedSessionID
        self.expiresAt = expiresAt
    }
}

public enum AgentOSRunStreamIngestorError: Error, Sendable, Equatable {
    case coordinatorUnavailable
    case malformedEvent(String)
    case unexpectedRun(String)
    case authorityUnavailable
    case macControlPermissionRequired
    case authorityConflict
    case unsupportedPause
    case ambiguousPause
}

private enum AgentOSRunTerminalKey: Sendable, Hashable {
    case agent(agentID: String, runID: String)
    case workflow(workflowID: String, runID: String)
}

private actor AgentOSRunTerminalHub {
    private static let retainedLimit = 256
    private var retained: [AgentOSRunTerminalKey: ServerSentEvent] = [:]
    private var order: [AgentOSRunTerminalKey] = []
    private var subscribers: [
        AgentOSRunTerminalKey: [UUID: AsyncStream<ServerSentEvent>.Continuation]
    ] = [:]

    func events(for key: AgentOSRunTerminalKey) -> AsyncStream<ServerSentEvent> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: ServerSentEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        if let event = retained[key] {
            pair.continuation.yield(event)
            pair.continuation.finish()
        } else {
            subscribers[key, default: [:]][id] = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id: id, key: key) }
            }
        }
        return pair.stream
    }

    func publish(_ event: ServerSentEvent, for key: AgentOSRunTerminalKey) {
        if retained[key] == nil { order.append(key) }
        retained[key] = event
        if let current = subscribers.removeValue(forKey: key) {
            for continuation in current.values {
                continuation.yield(event)
                continuation.finish()
            }
        }
        while order.count > Self.retainedLimit {
            retained.removeValue(forKey: order.removeFirst())
        }
    }

    private func remove(id: UUID, key: AgentOSRunTerminalKey) {
        subscribers[key]?.removeValue(forKey: id)
        if subscribers[key]?.isEmpty == true { subscribers.removeValue(forKey: key) }
    }
}

/// Durable authority registry for direct Agent tools. Only the signed app can
/// prepare/bind authority; streamed tool arguments can only be checked against
/// it, never create it.
public actor TrustedRunAuthorityRegistry {
    private static let supportedTools = ExternalActionRequestFactory.coreToolNames

    private let persistence: (any TrustedRunAuthorityPersisting)?
    private var agentRuns: [String: TrustedAgentRunStart] = [:]
    private var authorizingRuns: Set<String> = []
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(persistence: (any TrustedRunAuthorityPersisting)? = nil) {
        self.persistence = persistence
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func prepareAgentRunStart(_ start: TrustedAgentRunStart) async throws {
        try validate(start)
        let key = launchKey(start.launchID)
        let data = try encoder.encode(start)
        if let persistence {
            try await persistence.saveTrustedRunAuthority(
                StoredTrustedRunAuthority(
                    id: key,
                    kind: .agent,
                    authorityJSON: data,
                    updatedAt: Date(),
                    expiresAt: start.expiresAt
                )
            )
        }
        agentRuns[key] = start
    }

    public func bindAgentRun(_ start: TrustedAgentRunStart, runID: String) async throws {
        guard !runID.isEmpty else {
            throw AgentOSRunStreamIngestorError.unexpectedRun("run_id")
        }
        guard try await authority(for: launchKey(start.launchID)) == start else {
            throw AgentOSRunStreamIngestorError.authorityConflict
        }
        let key = runKey(agentID: start.agentID, runID: runID)
        let data = try encoder.encode(start)
        if let existing = try await authority(for: key), existing != start {
            throw AgentOSRunStreamIngestorError.authorityConflict
        }
        if let persistence {
            try await persistence.saveTrustedRunAuthority(
                StoredTrustedRunAuthority(
                    id: key,
                    kind: .agent,
                    authorityJSON: data,
                    updatedAt: Date(),
                    expiresAt: start.expiresAt
                )
            )
        }
        agentRuns[key] = start
    }

    public func authorize(
        _ continuation: AgentRunContinuation,
        startedWith prepared: TrustedAgentRunStart?
    ) async throws -> AgentExternalExecutionPause {
        let key = runKey(agentID: continuation.agentID, runID: continuation.runID)
        guard authorizingRuns.insert(key).inserted else {
            throw AgentOSRunStreamIngestorError.authorityConflict
        }
        defer { authorizingRuns.remove(key) }
        guard var start = try await authority(for: key) ?? prepared else {
            throw AgentOSRunStreamIngestorError.authorityUnavailable
        }
        if let prepared {
            guard start.launchID == prepared.launchID,
                  try await authority(for: launchKey(prepared.launchID)) == prepared
            else { throw AgentOSRunStreamIngestorError.authorityConflict }
        }
        guard start.expiresAt > Date(),
              continuation.agentID == start.agentID,
              continuation.userID == start.authenticatedUserID,
              continuation.sessionID == start.authenticatedSessionID
        else { throw AgentOSRunStreamIngestorError.unexpectedRun("agent authority") }
        let candidates = continuation.tools.filter(\.isUnresolvedExternalExecution)
        guard candidates.count == 1, let tool = candidates.first,
              let toolCallID = tool.toolCallID,
              let toolName = tool.toolName, Self.supportedTools.contains(toolName)
        else {
            throw candidates.isEmpty
                ? AgentOSRunStreamIngestorError.unsupportedPause
                : AgentOSRunStreamIngestorError.ambiguousPause
        }
        if let resolved = start.resolvedToolCallID, resolved != toolCallID {
            throw AgentOSRunStreamIngestorError.authorityConflict
        }
        if start.expectedTarget == nil, let context = start.voiceActionContext {
            guard context.accessibilityGranted else {
                throw AgentOSRunStreamIngestorError.macControlPermissionRequired
            }
            let proposal = try ExternalActionRequestFactory().proposedVoiceAction(tool)
            guard context.permits(proposal) else {
                throw AgentOSRunStreamIngestorError.authorityUnavailable
            }
            let originalJSON = try encoder.encode(start)
            start = TrustedAgentRunStart(
                launchID: start.launchID,
                agentID: start.agentID,
                authenticatedUserID: start.authenticatedUserID,
                authenticatedSessionID: start.authenticatedSessionID,
                expectedTarget: proposal.target,
                expectedOperation: proposal.operation,
                expiresAt: start.expiresAt,
                resolvedToolCallID: toolCallID
            )
            // Persist the exact binding before publishing any approval. Later
            // pauses may only replay this same tool call, never add an action.
            if let persistence {
                try await persistence.updateTrustedRunAuthority(
                    StoredTrustedRunAuthority(
                        id: key, kind: .agent, authorityJSON: try encoder.encode(start),
                        updatedAt: Date(), expiresAt: start.expiresAt
                    ),
                    replacingAuthorityJSON: originalJSON
                )
            }
            agentRuns[key] = start
        }
        guard let target = start.expectedTarget, let operation = start.expectedOperation,
              toolName == operation.semanticToolName
        else { throw AgentOSRunStreamIngestorError.authorityUnavailable }
        return AgentExternalExecutionPause(
            continuation: continuation,
            toolCallID: toolCallID,
            expectedToolName: toolName,
            authenticatedUserID: start.authenticatedUserID,
            authenticatedSessionID: start.authenticatedSessionID,
            expectedTarget: target,
            expectedOperation: operation,
            expiresAt: start.expiresAt
        )
    }

    public func resolvedAgentAuthority(agentID: String, runID: String) async throws -> TrustedVoiceActionAuthority? {
        guard let start = try await authority(for: runKey(agentID: agentID, runID: runID)),
              let target = start.expectedTarget, let operation = start.expectedOperation else { return nil }
        return try TrustedVoiceActionAuthority(target: target, operation: operation)
    }

    private func authority(for key: String) async throws -> TrustedAgentRunStart? {
        if let current = agentRuns[key], current.expiresAt > Date() { return current }
        guard let persistence,
              let stored = try await persistence.trustedRunAuthority(id: key, at: Date()),
              stored.kind == .agent
        else { return nil }
        let value: TrustedAgentRunStart
        do { value = try decoder.decode(TrustedAgentRunStart.self, from: stored.authorityJSON) }
        catch { throw TrustedRunAuthorityStoreError.corruptAuthority }
        try validate(value)
        agentRuns[key] = value
        return value
    }

    private func validate(_ start: TrustedAgentRunStart) throws {
        let hasValidActionAuthority: Bool
        switch (start.expectedTarget, start.expectedOperation) {
        case (nil, nil):
            hasValidActionAuthority = true
        case let (.some(target), .some(operation)):
            hasValidActionAuthority = operation.hasValidContentBinding
                && target.isStructurallyValid
                && target.matches(operation)
        default:
            hasValidActionAuthority = false
        }
        guard !start.launchID.isEmpty,
              start.launchID.utf8.count <= 256,
              !start.agentID.isEmpty,
              !start.authenticatedUserID.rawValue.isEmpty,
              !start.authenticatedSessionID.rawValue.isEmpty,
              hasValidActionAuthority,
              start.expiresAt > Date()
        else { throw AgentOSRunStreamIngestorError.unexpectedRun("launch authority") }
    }

    private func launchKey(_ launchID: String) -> String { "agent-launch:\(launchID)" }
    private func runKey(agentID: String, runID: String) -> String {
        "agent:\(agentID):\(runID)"
    }
}

/// Decodes only official top-level Agent/Workflow SSE envelopes. Agent pauses
/// pass through app-owned authority and policy. Workflow continuation envelopes
/// remain a distinct transport but are not executable by the generic CUA path.
public final class AgentOSRunStreamIngestor: AgentOSRunStreamHandling, @unchecked Sendable {
    private let authorityRegistry: TrustedRunAuthorityRegistry
    private let terminalHub = AgentOSRunTerminalHub()
    private let coordinatorLock = NSLock()
    private var coordinator: RunPauseCoordinator?

    public init(authorityRegistry: TrustedRunAuthorityRegistry) {
        self.authorityRegistry = authorityRegistry
    }

    public func bind(to coordinator: RunPauseCoordinator) throws {
        coordinatorLock.lock()
        defer { coordinatorLock.unlock() }
        guard self.coordinator == nil else {
            throw AgentOSRunStreamIngestorError.authorityConflict
        }
        self.coordinator = coordinator
    }

    public func prepareAgentRunStart(_ start: TrustedAgentRunStart) async throws {
        try await authorityRegistry.prepareAgentRunStart(start)
    }

    public func resolvedAgentAuthority(agentID: String, runID: String) async throws -> TrustedVoiceActionAuthority? {
        try await authorityRegistry.resolvedAgentAuthority(agentID: agentID, runID: runID)
    }

    public func finalAgentEvents(agentID: String, runID: String) async -> AsyncStream<ServerSentEvent> {
        await terminalHub.events(for: .agent(agentID: agentID, runID: runID))
    }

    public func hasPendingAgentReview(
        agentID: String,
        runID: String,
        userID: UserID,
        sessionID: ProductSessionID
    ) async throws -> Bool {
        let coordinator = try boundCoordinator()
        return await coordinator.hasPendingAgentReview(
            agentID: agentID, runID: runID, userID: userID, sessionID: sessionID
        )
    }

    public func finalWorkflowEvents(
        workflowID: String,
        runID: String
    ) async -> AsyncStream<ServerSentEvent> {
        await terminalHub.events(for: .workflow(workflowID: workflowID, runID: runID))
    }

    public func handle(
        _ stream: AgentOSEventStream,
        origin: AgentOSRunStreamOrigin
    ) async throws {
        let coordinator = try boundCoordinator()
        var boundAgent = false
        for try await event in stream {
            try Task.checkCancellation()
            if let key = try Self.validatedTerminalKey(event, origin: origin) {
                await terminalHub.publish(event, for: key)
            }
            if !boundAgent,
               case let .startedAgent(start) = origin,
               let runID = Self.extractAgentRunID(event, expectedAgentID: start.agentID)
            {
                try await authorityRegistry.bindAgentRun(start, runID: runID)
                boundAgent = true
            }
            guard let continuation = try Self.decodeAgentPause(event, origin: origin) else {
                if Self.isWorkflowPause(event) {
                    throw AgentOSRunStreamIngestorError.unsupportedPause
                }
                continue
            }
            let pause: AgentExternalExecutionPause
            switch origin {
            case let .startedAgent(start):
                pause = try await authorityRegistry.authorize(continuation, startedWith: start)
            case .continuedAgent:
                pause = try await authorityRegistry.authorize(continuation, startedWith: nil)
            case .startedWorkflow, .continuedWorkflow:
                throw AgentOSRunStreamIngestorError.unexpectedRun("stream origin")
            }
            try await coordinator.ingest(pause)
        }
    }

    private func boundCoordinator() throws -> RunPauseCoordinator {
        coordinatorLock.lock()
        defer { coordinatorLock.unlock() }
        guard let coordinator else {
            throw AgentOSRunStreamIngestorError.coordinatorUnavailable
        }
        return coordinator
    }

    private static func decodeAgentPause(
        _ event: ServerSentEvent,
        origin: AgentOSRunStreamOrigin
    ) throws -> AgentRunContinuation? {
        guard let root = try decodedRoot(event) else {
            if event.event == "RunPaused" {
                throw AgentOSRunStreamIngestorError.malformedEvent("pause JSON")
            }
            return nil
        }
        let name = event.event ?? root["event"]?.stringValue ?? root["event_type"]?.stringValue
        guard name == "RunPaused" else { return nil }
        let body = firstEnvelopeBody(root)
        switch origin {
        case let .startedAgent(start):
            return try decodeAgent(
                body: body,
                root: root,
                agentID: start.agentID,
                expectedRunID: nil,
                userID: start.authenticatedUserID,
                sessionID: start.authenticatedSessionID
            )
        case let .continuedAgent(agentID, runID, userID, sessionID):
            return try decodeAgent(
                body: body,
                root: root,
                agentID: agentID,
                expectedRunID: runID,
                userID: userID,
                sessionID: sessionID
            )
        case .startedWorkflow, .continuedWorkflow:
            throw AgentOSRunStreamIngestorError.unexpectedRun("stream origin")
        }
    }

    private static func decodeAgent(
        body: [String: JSONValue],
        root: [String: JSONValue],
        agentID: String,
        expectedRunID: String?,
        userID: UserID,
        sessionID: ProductSessionID
    ) throws -> AgentRunContinuation {
        let runID = try requiredString(["run_id"], body: body, root: root)
        try optionalMatch(["agent_id"], expected: agentID, body: body, root: root)
        try optionalMatch(["user_id"], expected: userID.rawValue, body: body, root: root)
        try optionalMatch(["session_id"], expected: sessionID.rawValue, body: body, root: root)
        if let expectedRunID, expectedRunID != runID {
            throw AgentOSRunStreamIngestorError.unexpectedRun("run_id")
        }
        let values = try requiredArray(["tools"], body: body, root: root)
        let tools = try values.map { value -> AgentToolContinuation in
            guard let fields = value.objectValue else {
                throw AgentOSRunStreamIngestorError.malformedEvent("tools")
            }
            return AgentToolContinuation(fields: fields)
        }
        return AgentRunContinuation(
            agentID: agentID,
            runID: runID,
            sessionID: sessionID,
            userID: userID,
            tools: tools
        )
    }

    private static func validatedTerminalKey(
        _ event: ServerSentEvent,
        origin: AgentOSRunStreamOrigin
    ) throws -> AgentOSRunTerminalKey? {
        guard let root = try decodedRoot(event) else { return nil }
        let name = event.event ?? root["event"]?.stringValue ?? root["event_type"]?.stringValue
        let body = firstEnvelopeBody(root)
        switch origin {
        case let .startedAgent(start):
            guard ["RunCompleted", "RunError", "RunCancelled"].contains(name ?? "") else {
                return nil
            }
            let runID = try requiredString(["run_id"], body: body, root: root)
            try optionalMatch(["agent_id"], expected: start.agentID, body: body, root: root)
            return .agent(agentID: start.agentID, runID: runID)
        case let .continuedAgent(agentID, runID, userID, sessionID):
            guard ["RunCompleted", "RunError", "RunCancelled"].contains(name ?? "") else {
                return nil
            }
            guard try requiredString(["run_id"], body: body, root: root) == runID else {
                throw AgentOSRunStreamIngestorError.unexpectedRun("run_id")
            }
            try optionalMatch(["agent_id"], expected: agentID, body: body, root: root)
            try optionalMatch(["user_id"], expected: userID.rawValue, body: body, root: root)
            try optionalMatch(["session_id"], expected: sessionID.rawValue, body: body, root: root)
            return .agent(agentID: agentID, runID: runID)
        case let .startedWorkflow(start):
            guard ["WorkflowCompleted", "WorkflowError", "WorkflowCancelled"].contains(name ?? "") else {
                return nil
            }
            let runID = try requiredString(["run_id", "workflow_run_id"], body: body, root: root)
            try optionalMatch(["workflow_id"], expected: start.workflowID, body: body, root: root)
            return .workflow(workflowID: start.workflowID, runID: runID)
        case let .continuedWorkflow(workflowID, runID, userID, sessionID):
            guard ["WorkflowCompleted", "WorkflowError", "WorkflowCancelled"].contains(name ?? "") else {
                return nil
            }
            guard try requiredString(["run_id", "workflow_run_id"], body: body, root: root) == runID else {
                throw AgentOSRunStreamIngestorError.unexpectedRun("run_id")
            }
            try optionalMatch(["workflow_id"], expected: workflowID, body: body, root: root)
            try optionalMatch(["user_id"], expected: userID.rawValue, body: body, root: root)
            try optionalMatch(["session_id"], expected: sessionID.rawValue, body: body, root: root)
            return .workflow(workflowID: workflowID, runID: runID)
        }
    }

    private static func extractAgentRunID(
        _ event: ServerSentEvent,
        expectedAgentID: String
    ) -> String? {
        guard let root = try? decodedRoot(event) else { return nil }
        let name = event.event ?? root["event"]?.stringValue ?? root["event_type"]?.stringValue
        guard name == "RunStarted" || name == "RunPaused" else { return nil }
        let body = firstEnvelopeBody(root)
        if let value = body["agent_id"]?.stringValue ?? root["agent_id"]?.stringValue,
           value != expectedAgentID { return nil }
        return body["run_id"]?.stringValue ?? root["run_id"]?.stringValue
    }

    private static func isWorkflowPause(_ event: ServerSentEvent) -> Bool {
        if event.event == "WorkflowPaused" { return true }
        guard let root = try? decodedRoot(event) else { return false }
        return root["event"]?.stringValue == "WorkflowPaused"
            || root["event_type"]?.stringValue == "WorkflowPaused"
    }

    private static func decodedRoot(_ event: ServerSentEvent) throws -> [String: JSONValue]? {
        guard let data = event.data.data(using: .utf8), !data.isEmpty else { return nil }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = value.objectValue
        else {
            if ["RunPaused", "WorkflowPaused"].contains(event.event ?? "") {
                throw AgentOSRunStreamIngestorError.malformedEvent("event JSON")
            }
            return nil
        }
        return root
    }

    private static func firstEnvelopeBody(
        _ root: [String: JSONValue]
    ) -> [String: JSONValue] {
        for key in ["data", "payload", "content"] {
            guard let candidate = root[key]?.objectValue else { continue }
            if candidate["run_id"] != nil
                || candidate["workflow_run_id"] != nil
                || candidate["tools"] != nil
                || candidate["step_requirements"] != nil
            { return candidate }
        }
        return root
    }

    private static func requiredString(
        _ keys: [String],
        body: [String: JSONValue],
        root: [String: JSONValue]
    ) throws -> String {
        for key in keys {
            if let value = body[key]?.stringValue ?? root[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        throw AgentOSRunStreamIngestorError.malformedEvent(keys[0])
    }

    private static func requiredArray(
        _ keys: [String],
        body: [String: JSONValue],
        root: [String: JSONValue]
    ) throws -> [JSONValue] {
        for key in keys {
            if let value = body[key]?.arrayValue ?? root[key]?.arrayValue { return value }
        }
        throw AgentOSRunStreamIngestorError.malformedEvent(keys[0])
    }

    private static func optionalMatch(
        _ keys: [String],
        expected: String,
        body: [String: JSONValue],
        root: [String: JSONValue]
    ) throws {
        for key in keys {
            if let value = body[key]?.stringValue ?? root[key]?.stringValue, value != expected {
                throw AgentOSRunStreamIngestorError.unexpectedRun(key)
            }
        }
    }
}
