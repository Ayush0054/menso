import Foundation

public enum ExternalExecutionWireTarget: Codable, Hashable, Sendable {
    case application(FocusedApplicationTarget)

    public var kind: String {
        switch self {
        case .application: "application"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case bundleIdentifier = "bundle_id"
        case windowTitle = "window_title"
        case elementRole = "element_role"
        case elementLabel = "element_label"
    }

    private enum Kind: String, Codable { case application }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .application:
            self = .application(
                FocusedApplicationTarget(
                    bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
                    windowTitle: try container.decodeIfPresent(String.self, forKey: .windowTitle),
                    elementRole: try container.decodeIfPresent(String.self, forKey: .elementRole),
                    elementLabel: try container.decodeIfPresent(String.self, forKey: .elementLabel)
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .application(target):
            try container.encode(Kind.application, forKey: .kind)
            try container.encode(target.bundleIdentifier, forKey: .bundleIdentifier)
            try container.encodeIfPresent(target.windowTitle, forKey: .windowTitle)
            try container.encodeIfPresent(target.elementRole, forKey: .elementRole)
            try container.encodeIfPresent(target.elementLabel, forKey: .elementLabel)
        }
    }
}

public enum ExternalExecutionWireStatus: String, Codable, Hashable, Sendable {
    case opened
    case focused
    case inserted
    case activated
    case rejected
    case expired
    case failed
}

/// Exact backend `ExternalExecutionResult` wire shape. Internal ActionTarget remains strongly typed.
public struct ExternalExecutionWireResult: Codable, Hashable, Sendable {
    public let actionID: String
    public let status: ExternalExecutionWireStatus
    public let target: ExternalExecutionWireTarget
    public let contentHash: String
    public let verified: Bool
    public let evidenceReference: String?
    public let errorCode: String?
    public let occurredAt: String

    public init(actionResult: ActionResult) throws {
        guard actionResult.contentHash.isValidSHA256 else {
            throw RunContinuationError.invalidResult
        }
        self.actionID = actionResult.actionID.rawValue
        switch actionResult.status {
        case .opened: self.status = .opened
        case .focused: self.status = .focused
        case .inserted: self.status = .inserted
        case .activated: self.status = .activated
        case .denied: self.status = .rejected
        case .expired: self.status = .expired
        case .failed, .cancelled: self.status = .failed
        }
        switch actionResult.target {
        case let .focusedApplication(target):
            self.target = .application(target)
        }
        self.contentHash = actionResult.contentHash.rawValue
        self.verified = actionResult.verified
        self.evidenceReference = actionResult.evidenceReference?.rawValue
        self.errorCode = actionResult.errorCode?.rawValue
        self.occurredAt = ISO8601DateFormatter().string(from: actionResult.completedAt)
    }

    init(
        actionID: String,
        status: ExternalExecutionWireStatus,
        target: ExternalExecutionWireTarget,
        contentHash: String,
        verified: Bool,
        evidenceReference: String?,
        errorCode: String?,
        occurredAt: String
    ) {
        self.actionID = actionID
        self.status = status
        self.target = target
        self.contentHash = contentHash
        self.verified = verified
        self.evidenceReference = evidenceReference
        self.errorCode = errorCode
        self.occurredAt = occurredAt
    }

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case status
        case target
        case contentHash = "content_hash"
        case verified
        case evidenceReference = "evidence_ref"
        case errorCode = "error_code"
        case occurredAt = "occurred_at"
    }
}

private func externalExecutionJSONString(for result: ActionResult) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(ExternalExecutionWireResult(actionResult: result))
    guard let string = String(data: data, encoding: .utf8) else {
        throw RunContinuationError.invalidResult
    }
    return .string(string)
}

private func isMissingOrNull(_ value: JSONValue?) -> Bool {
    switch value {
    case nil, .some(.null): true
    default: false
    }
}

public struct AgentToolContinuation: Codable, Hashable, Sendable {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        self.fields = try [String: JSONValue](from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
    }

    public var toolCallID: String? { fields["tool_call_id"]?.stringValue }
    public var toolName: String? { fields["tool_name"]?.stringValue }
    public var requiresExternalExecution: Bool {
        fields["external_execution_required"]?.boolValue == true
    }
    public var isUnresolvedExternalExecution: Bool {
        requiresExternalExecution && isMissingOrNull(fields["result"])
    }

    public func resolvingExternalExecution(with result: ActionResult) throws -> AgentToolContinuation {
        guard isUnresolvedExternalExecution else {
            throw RunContinuationError.requirementNotExternallyExecutable
        }
        var resolved = self
        resolved.fields["result"] = try externalExecutionJSONString(for: result)
        return resolved
    }
}

/// Agent continuation is form-encoded under `tools`; it never accepts Workflow step requirements.
public struct AgentRunContinuation: Codable, Hashable, Sendable {
    public let agentID: String
    public let runID: String
    public let sessionID: ProductSessionID
    public let userID: UserID
    public let tools: [AgentToolContinuation]
    public let stream: Bool

    public init(
        agentID: String,
        runID: String,
        sessionID: ProductSessionID,
        userID: UserID,
        tools: [AgentToolContinuation],
        stream: Bool = true
    ) {
        self.agentID = agentID
        self.runID = runID
        self.sessionID = sessionID
        self.userID = userID
        self.tools = tools
        self.stream = stream
    }

    public func resolving(
        toolCallID: String,
        expectedToolName: String,
        with result: ActionResult
    ) throws -> AgentRunContinuation {
        let matches = tools.indices.filter {
            tools[$0].toolCallID == toolCallID && tools[$0].toolName == expectedToolName
        }
        guard matches.count == 1, let index = matches.first else {
            throw matches.isEmpty ? RunContinuationError.requirementNotFound : .ambiguousRequirement
        }
        guard result.actionID.rawValue.count > 0 else {
            throw RunContinuationError.invalidResult
        }

        var updated = tools
        updated[index] = try updated[index].resolvingExternalExecution(with: result)
        return AgentRunContinuation(
            agentID: agentID,
            runID: runID,
            sessionID: sessionID,
            userID: userID,
            tools: updated,
            stream: stream
        )
    }

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case runID = "run_id"
        case sessionID = "session_id"
        case userID = "user_id"
        case tools
        case stream
    }
}

public struct WorkflowExecutorRequirement: Codable, Hashable, Sendable {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        self.fields = try [String: JSONValue](from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
    }

    public var toolExecution: [String: JSONValue]? {
        fields["tool_execution"]?.objectValue
    }

    public var toolCallID: String? { toolExecution?["tool_call_id"]?.stringValue }
    public var toolName: String? { toolExecution?["tool_name"]?.stringValue }
    public var requiresExternalExecution: Bool {
        toolExecution?["external_execution_required"]?.boolValue == true
    }
    public var isUnresolvedExternalExecution: Bool {
        requiresExternalExecution
            && isMissingOrNull(fields["external_execution_result"])
            && isMissingOrNull(toolExecution?["result"])
    }

    public func resolvingExternalExecution(with result: ActionResult) throws -> WorkflowExecutorRequirement {
        guard isUnresolvedExternalExecution, var toolExecution else {
            throw RunContinuationError.requirementNotExternallyExecutable
        }
        let encodedResult = try externalExecutionJSONString(for: result)
        var resolved = self
        resolved.fields["external_execution_result"] = encodedResult
        toolExecution["result"] = encodedResult
        resolved.fields["tool_execution"] = .object(toolExecution)
        return resolved
    }
}

public struct WorkflowStepRequirement: Codable, Hashable, Sendable {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        self.fields = try [String: JSONValue](from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
    }

    public var stepID: String? { fields["step_id"]?.stringValue }
    public var stepName: String? { fields["step_name"]?.stringValue }
    public var executorID: String? { fields["executor_id"]?.stringValue }
    public var executorType: String? { fields["executor_type"]?.stringValue }
    public var requiresExecutorInput: Bool { fields["requires_executor_input"]?.boolValue == true }
    public var requiresConfirmation: Bool { fields["requires_confirmation"]?.boolValue == true }
    public var confirmed: Bool? { fields["confirmed"]?.boolValue }

    public var executorRequirements: [WorkflowExecutorRequirement] {
        guard case let .array(values)? = fields["executor_requirements"] else { return [] }
        return values.compactMap { value in
            guard case let .object(fields) = value else { return nil }
            return WorkflowExecutorRequirement(fields: fields)
        }
    }

    public func resolvingExternalExecution(
        binding: WorkflowRequirementBinding,
        expectedToolName: String,
        result: ActionResult
    ) throws -> WorkflowStepRequirement {
        guard stepID == binding.stepID,
              executorID == binding.executorID,
              executorType == binding.executorType,
              requiresExecutorInput
        else {
            throw RunContinuationError.bindingMismatch
        }

        guard case let .array(existingValues)? = fields["executor_requirements"] else {
            throw RunContinuationError.requirementNotFound
        }
        var requirementValues = existingValues
        let matches = requirementValues.indices.filter { index in
            guard case let .object(fields) = requirementValues[index] else { return false }
            let requirement = WorkflowExecutorRequirement(fields: fields)
            return requirement.toolCallID == binding.toolCallID
                && requirement.toolName == expectedToolName
        }
        guard matches.count == 1, let index = matches.first else {
            throw matches.isEmpty ? RunContinuationError.requirementNotFound : .ambiguousRequirement
        }
        guard case let .object(requirementFields) = requirementValues[index] else {
            throw RunContinuationError.requirementNotFound
        }
        let resolvedRequirement = try WorkflowExecutorRequirement(fields: requirementFields)
            .resolvingExternalExecution(with: result)
        requirementValues[index] = .object(resolvedRequirement.fields)

        var resolved = self
        resolved.fields["executor_requirements"] = .array(requirementValues)
        return resolved
    }

    public func resolvingHumanReview(
        stepID expectedStepID: String,
        resolution: HumanReviewResolution,
        feedback: String? = nil
    ) throws -> WorkflowStepRequirement {
        guard stepID == expectedStepID, requiresConfirmation, confirmed == nil else {
            throw RunContinuationError.bindingMismatch
        }
        var resolved = self
        switch resolution {
        case .approveOnce, .alwaysAllow:
            resolved.fields["confirmed"] = .bool(true)
        case .deny:
            resolved.fields["confirmed"] = .bool(false)
            if let feedback, !feedback.isEmpty {
                resolved.fields["rejection_feedback"] = .string(feedback)
            }
        }
        return resolved
    }
}

/// Workflow continuation always carries the complete, ordered `step_requirements` history.
/// Only its last entry may be mutated because earlier entries are persisted run history.
public struct WorkflowRunContinuation: Codable, Hashable, Sendable {
    public let workflowID: String
    public let runID: String
    public let sessionID: ProductSessionID
    public let userID: UserID
    public let stepRequirements: [WorkflowStepRequirement]
    public let stream: Bool
    public let factoryInput: JSONValue?

    public init(
        workflowID: String,
        runID: String,
        sessionID: ProductSessionID,
        userID: UserID,
        stepRequirements: [WorkflowStepRequirement],
        stream: Bool = true,
        factoryInput: JSONValue? = nil
    ) {
        self.workflowID = workflowID
        self.runID = runID
        self.sessionID = sessionID
        self.userID = userID
        self.stepRequirements = stepRequirements
        self.stream = stream
        self.factoryInput = factoryInput
    }

    public func resolvingExternalExecution(
        binding: WorkflowRequirementBinding,
        expectedToolName: String,
        result: ActionResult
    ) throws -> WorkflowRunContinuation {
        guard workflowID == binding.workflowID, runID == binding.runID else {
            throw RunContinuationError.bindingMismatch
        }
        guard !stepRequirements.isEmpty else {
            throw RunContinuationError.requirementNotFound
        }

        var updated = stepRequirements
        let lastIndex = updated.index(before: updated.endIndex)
        updated[lastIndex] = try updated[lastIndex].resolvingExternalExecution(
            binding: binding,
            expectedToolName: expectedToolName,
            result: result
        )
        return WorkflowRunContinuation(
            workflowID: workflowID,
            runID: runID,
            sessionID: sessionID,
            userID: userID,
            stepRequirements: updated,
            stream: stream,
            factoryInput: factoryInput
        )
    }

    public func resolvingHumanReview(
        stepID: String,
        resolution: HumanReviewResolution,
        feedback: String? = nil
    ) throws -> WorkflowRunContinuation {
        guard !stepRequirements.isEmpty else {
            throw RunContinuationError.requirementNotFound
        }
        var updated = stepRequirements
        let lastIndex = updated.index(before: updated.endIndex)
        updated[lastIndex] = try updated[lastIndex].resolvingHumanReview(
            stepID: stepID,
            resolution: resolution,
            feedback: feedback
        )
        return WorkflowRunContinuation(
            workflowID: workflowID,
            runID: runID,
            sessionID: sessionID,
            userID: userID,
            stepRequirements: updated,
            stream: stream,
            factoryInput: factoryInput
        )
    }

    enum CodingKeys: String, CodingKey {
        case workflowID = "workflow_id"
        case runID = "run_id"
        case sessionID = "session_id"
        case userID = "user_id"
        case stepRequirements = "step_requirements"
        case stream
        case factoryInput = "factory_input"
    }
}

public enum RunContinuationError: Error, Sendable, Equatable {
    case requirementNotFound
    case ambiguousRequirement
    case requirementNotExternallyExecutable
    case bindingMismatch
    case invalidResult
}
