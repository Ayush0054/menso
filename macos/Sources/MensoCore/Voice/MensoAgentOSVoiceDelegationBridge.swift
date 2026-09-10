import Foundation

/// Authenticated voice bridge for the reusable Menso Agent. Voice text never
/// creates target authority: a desktop action is admitted only when the signed
/// app supplies an exact target plus exact semantic operation.
public struct MensoAgentOSVoiceDelegationBridge: MensoVoiceDelegating {
    public static let agentID = "menso"

    private let client: any AgentOSRunClient
    private let streamHandler: AgentOSRunStreamIngestor
    private let authenticatedContextProvider: any AuthenticatedProductContextProviding
    private let actionResultStore: any ActionResultStore
    private let terminalWait: Duration

    public init(
        client: any AgentOSRunClient,
        streamHandler: AgentOSRunStreamIngestor,
        authenticatedContextProvider: any AuthenticatedProductContextProviding,
        actionResultStore: any ActionResultStore,
        terminalWait: Duration = .seconds(180)
    ) {
        self.client = client
        self.streamHandler = streamHandler
        self.authenticatedContextProvider = authenticatedContextProvider
        self.actionResultStore = actionResultStore
        self.terminalWait = terminalWait
    }

    public func delegate(
        _ delegation: AuthenticatedVoiceDelegation
    ) async throws -> VoiceDelegationResult {
        let verified = try await authenticatedContextProvider.authenticatedProductContext()
        guard verified.userID == delegation.userID,
              verified.sessionID == delegation.sessionID
        else { throw AgentOSClientError.authenticatedIdentityMismatch }
        guard case let .agent(agentID) = delegation.route,
              agentID == Self.agentID
        else { throw LiveVoiceError.invalidDelegation }

        let authority: TrustedVoiceActionAuthority?
        switch delegation.request.operationHint {
        case .desktopAction:
            guard let local = delegation.actionAuthority else {
                return VoiceDelegationResult(
                    status: .rejected,
                    spokenSummary: "Select one exact app target and action in Menso first."
                )
            }
            authority = local
        case .openEnded, .none:
            authority = nil
        }

        let start = TrustedAgentRunStart(
            launchID: UUID().uuidString.lowercased(),
            agentID: agentID,
            authenticatedUserID: verified.userID,
            authenticatedSessionID: verified.sessionID,
            expectedTarget: authority?.target,
            expectedOperation: authority?.operation,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        try await streamHandler.prepareAgentRunStart(start)

        let observer = VoiceAgentStreamObserver(
            expectedAgentID: agentID,
            expectedUserID: verified.userID,
            expectedSessionID: verified.sessionID
        )
        let upstream = try await client.startAgentRun(
            AgentRunRequest(
                agentID: agentID,
                message: Self.boundMessage(
                    task: delegation.request.task,
                    contextReferences: delegation.request.contextReferences,
                    authority: authority
                ),
                sessionID: verified.sessionID,
                userID: verified.userID,
                background: false
            )
        )
        try await streamHandler.handle(
            observer.observe(upstream),
            origin: .startedAgent(start)
        )

        if let result = try await observer.completedResult() {
            return try await verifiedResult(result)
        }
        guard let runID = await observer.runID() else {
            throw LiveVoiceError.invalidDelegation
        }
        let terminal = await firstTerminalEvent(agentID: agentID, runID: runID)
        guard let terminal else {
            return VoiceDelegationResult(
                status: .requiresExternalAction,
                spokenSummary: "That desktop action is waiting for review.",
                runID: runID,
                continuationKind: "agent",
                continuationResourceID: agentID
            )
        }
        guard let result = try VoiceAgentStreamObserver.decodeCompletedResult(
            terminal,
            expectedAgentID: agentID,
            expectedUserID: verified.userID,
            expectedSessionID: verified.sessionID
        ) else { throw LiveVoiceError.invalidDelegation }
        return try await verifiedResult(result)
    }

    private func firstTerminalEvent(agentID: String, runID: String) async -> ServerSentEvent? {
        let events = await streamHandler.finalAgentEvents(agentID: agentID, runID: runID)
        return await withTaskGroup(of: ServerSentEvent?.self) { group in
            group.addTask {
                for await event in events { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: terminalWait)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func verifiedResult(
        _ result: VoiceDelegationResult
    ) async throws -> VoiceDelegationResult {
        for receipt in result.actionReceipts {
            guard let stored = try await actionResultStore.execution(
                for: ActionID(rawValue: receipt.actionID)
            ),
            try ExternalExecutionWireResult(actionResult: stored.result) == receipt
            else { throw LiveVoiceError.invalidDelegation }
        }
        return result
    }

    private static func boundMessage(
        task: String,
        contextReferences: [String],
        authority: TrustedVoiceActionAuthority?
    ) -> String {
        var sections = [task]
        if !contextReferences.isEmpty {
            sections.append("Opaque context references: \(contextReferences.joined(separator: ", "))")
        }
        if let authority {
            guard case let .focusedApplication(target) = authority.target else { return task }
            sections.append(
                "Trusted local action binding: tool=\(authority.operation.semanticToolName), "
                    + "bundle_id=\(target.bundleIdentifier), "
                    + "window_title=\(target.windowTitle ?? "none"), "
                    + "element_role=\(target.elementRole ?? "none"), "
                    + "element_label=\(target.elementLabel ?? "none"). "
                    + "Use exactly this binding; ask for clarification rather than changing it."
            )
        }
        return sections.joined(separator: "\n\n")
    }
}

private actor VoiceAgentStreamObserver {
    private let expectedAgentID: String
    private let expectedUserID: UserID
    private let expectedSessionID: ProductSessionID
    private var observedRunID: String?
    private var result: VoiceDelegationResult?

    init(
        expectedAgentID: String,
        expectedUserID: UserID,
        expectedSessionID: ProductSessionID
    ) {
        self.expectedAgentID = expectedAgentID
        self.expectedUserID = expectedUserID
        self.expectedSessionID = expectedSessionID
    }

    nonisolated func observe(_ upstream: AgentOSEventStream) -> AgentOSEventStream {
        AgentOSEventStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        try await self.record(event)
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func runID() -> String? { observedRunID }
    func completedResult() throws -> VoiceDelegationResult? { result }

    private func record(_ event: ServerSentEvent) throws {
        if let root = try Self.root(event) {
            let body = Self.body(root)
            if let runID = body["run_id"]?.stringValue ?? root["run_id"]?.stringValue {
                if let observedRunID, observedRunID != runID {
                    throw AgentOSRunStreamIngestorError.unexpectedRun("run_id")
                }
                observedRunID = runID
            }
        }
        if let completed = try Self.decodeCompletedResult(
            event,
            expectedAgentID: expectedAgentID,
            expectedUserID: expectedUserID,
            expectedSessionID: expectedSessionID
        ) {
            result = completed
        }
    }

    static func decodeCompletedResult(
        _ event: ServerSentEvent,
        expectedAgentID: String,
        expectedUserID: UserID,
        expectedSessionID: ProductSessionID
    ) throws -> VoiceDelegationResult? {
        guard let root = try root(event) else { return nil }
        let name = event.event ?? root["event"]?.stringValue ?? root["event_type"]?.stringValue
        guard name == "RunCompleted" else {
            if name == "RunError" || name == "RunCancelled" {
                return VoiceDelegationResult(
                    status: .rejected,
                    spokenSummary: "The AgentOS run did not complete."
                )
            }
            return nil
        }
        let body = body(root)
        try optionalMatch("agent_id", expected: expectedAgentID, body: body, root: root)
        try optionalMatch("user_id", expected: expectedUserID.rawValue, body: body, root: root)
        try optionalMatch("session_id", expected: expectedSessionID.rawValue, body: body, root: root)
        guard let value = resultValue(body: body, root: root) else {
            throw LiveVoiceError.invalidDelegation
        }
        let data: Data
        if let string = value.stringValue {
            data = Data(string.utf8)
        } else {
            data = try JSONEncoder().encode(value)
        }
        return try JSONDecoder().decode(VoiceDelegationResult.self, from: data)
    }

    private static func resultValue(
        body: [String: JSONValue],
        root: [String: JSONValue]
    ) -> JSONValue? {
        for key in ["content", "output", "result"] {
            if let value = body[key] ?? root[key] {
                if let object = value.objectValue,
                   object["spoken_summary"] != nil,
                   object["status"] != nil { return value }
                if value.stringValue != nil { return value }
            }
        }
        if body["spoken_summary"] != nil, body["status"] != nil { return .object(body) }
        if root["spoken_summary"] != nil, root["status"] != nil { return .object(root) }
        return nil
    }

    private static func root(_ event: ServerSentEvent) throws -> [String: JSONValue]? {
        guard let data = event.data.data(using: .utf8), !data.isEmpty else { return nil }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = value.objectValue
        else { throw LiveVoiceError.invalidDelegation }
        return root
    }

    private static func body(_ root: [String: JSONValue]) -> [String: JSONValue] {
        for key in ["data", "payload", "content"] {
            if let object = root[key]?.objectValue,
               object["run_id"] != nil || object["status"] != nil { return object }
        }
        return root
    }

    private static func optionalMatch(
        _ key: String,
        expected: String,
        body: [String: JSONValue],
        root: [String: JSONValue]
    ) throws {
        if let value = body[key]?.stringValue ?? root[key]?.stringValue, value != expected {
            throw AgentOSRunStreamIngestorError.unexpectedRun(key)
        }
    }
}
