import CryptoKit
import Foundation

public struct ActionID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    public var description: String { rawValue }
}

public struct IdempotencyKey: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct UserID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ProductSessionID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum AuthenticatedProductContextError: Error, Sendable, Equatable {
    case invalidIdentity
}

/// Product identity obtained from verified authentication, never caller input.
public struct AuthenticatedProductContext: Sendable, Hashable {
    public let userID: UserID
    public let sessionID: ProductSessionID

    public init(userID: UserID, sessionID: ProductSessionID) throws {
        guard !userID.rawValue.isEmpty, !sessionID.rawValue.isEmpty else {
            throw AuthenticatedProductContextError.invalidIdentity
        }
        self.userID = userID
        self.sessionID = sessionID
    }
}

public protocol AuthenticatedProductContextProviding: Sendable {
    func authenticatedProductContext() async throws -> AuthenticatedProductContext
}

public struct ContentHash: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func sha256(of text: String) -> ContentHash {
        let digest = SHA256.hash(data: Data(text.utf8))
        return ContentHash(rawValue: digest.map { String(format: "%02x", $0) }.joined())
    }

    public var isValidSHA256: Bool {
        rawValue.count == 64 && rawValue.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard rawValue.count == 64,
              rawValue.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
              })
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Content hash must be 64 lowercase hexadecimal characters"
            )
        }
        self.rawValue = rawValue
    }

    public func encode(to encoder: Encoder) throws {
        guard isValidSHA256 else {
            throw EncodingError.invalidValue(
                rawValue,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Content hash must be 64 lowercase hexadecimal characters"
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct EvidenceReference: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct FocusedApplicationTarget: Codable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let processIdentifier: Int32?
    public let windowTitle: String?
    public let elementRole: String?
    public let elementLabel: String?

    public init(
        bundleIdentifier: String,
        processIdentifier: Int32? = nil,
        windowTitle: String? = nil,
        elementRole: String? = nil,
        elementLabel: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowTitle = windowTitle
        self.elementRole = elementRole
        self.elementLabel = elementLabel
    }

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier = "bundle_id"
        case processIdentifier = "pid"
        case windowTitle = "window_title"
        case elementRole = "element_role"
        case elementLabel = "element_label"
    }
}

public enum ActionTarget: Codable, Hashable, Sendable {
    case focusedApplication(FocusedApplicationTarget)

    private enum CodingKeys: String, CodingKey {
        case kind
        case focusedApplication = "focused_application"
    }

    private enum Kind: String, Codable {
        case focusedApplication = "focused_application"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .focusedApplication:
            self = .focusedApplication(
                try container.decode(FocusedApplicationTarget.self, forKey: .focusedApplication)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .focusedApplication(target):
            try container.encode(Kind.focusedApplication, forKey: .kind)
            try container.encode(target, forKey: .focusedApplication)
        }
    }
}

public struct DictationInsertionOperation: Codable, Hashable, Sendable {
    public let text: String
    public let contentHash: ContentHash

    public init(text: String, contentHash: ContentHash? = nil) {
        self.text = text
        self.contentHash = contentHash ?? .sha256(of: text)
    }

    enum CodingKeys: String, CodingKey {
        case text
        case contentHash = "content_hash"
    }
}

public enum ApplicationSemanticActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case openApplication = "open_application"
    case focusWindow = "focus_window"
    case insertText = "insert_text"
    case activateControl = "activate_control"
}

/// App-agnostic semantic CUA action. Targets use application/window/AX labels;
/// coordinates, raw key events, screenshots, selectors, and shell commands are
/// deliberately not representable.
public struct ApplicationSemanticOperation: Codable, Hashable, Sendable {
    public let kind: ApplicationSemanticActionKind
    public let text: String?
    public let expectedState: String?
    public let contentHash: ContentHash

    public init(
        kind: ApplicationSemanticActionKind,
        text: String? = nil,
        expectedState: String? = nil,
        contentHash: ContentHash? = nil
    ) {
        self.kind = kind
        self.text = text
        self.expectedState = expectedState
        self.contentHash = contentHash ?? Self.hash(
            kind: kind,
            text: text,
            expectedState: expectedState
        )
    }

    public var isStructurallyValid: Bool {
        switch kind {
        case .openApplication, .focusWindow:
            text == nil && expectedState == nil
        case .insertText:
            text?.isEmpty == false && expectedState == nil
        case .activateControl:
            text == nil && expectedState?.isEmpty == false
        }
    }

    public var hasValidContentBinding: Bool {
        isStructurallyValid && contentHash == Self.hash(
            kind: kind,
            text: text,
            expectedState: expectedState
        )
    }

    private static func hash(
        kind: ApplicationSemanticActionKind,
        text: String?,
        expectedState: String?
    ) -> ContentHash {
        .sha256(of: [kind.rawValue, text ?? "", expectedState ?? ""].joined(separator: "\u{1f}"))
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case text
        case expectedState = "expected_state"
        case contentHash = "content_hash"
    }
}

/// The complete set of local operations that may cross the Swift policy boundary.
/// There is intentionally no click, key, coordinate, selector, screenshot, or shell case.
public enum ActionOperation: Codable, Hashable, Sendable {
    case application(ApplicationSemanticOperation)
    case insertDictationText(DictationInsertionOperation)

    public var semanticToolName: String {
        switch self {
        case let .application(operation): operation.kind.rawValue
        case .insertDictationText: "insert_dictation_text"
        }
    }

    public var contentHash: ContentHash {
        switch self {
        case let .application(operation): operation.contentHash
        case let .insertDictationText(operation): operation.contentHash
        }
    }

    private enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case application
        case insertDictationText = "insert_dictation_text"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let toolName = try container.decode(String.self, forKey: .toolName)
        switch toolName {
        case "open_application", "focus_window", "insert_text", "activate_control":
            let operation = try container.decode(ApplicationSemanticOperation.self, forKey: .application)
            guard operation.kind.rawValue == toolName else {
                throw DecodingError.dataCorruptedError(
                    forKey: .toolName,
                    in: container,
                    debugDescription: "Application action kind does not match tool name"
                )
            }
            self = .application(operation)
        case "insert_dictation_text":
            self = .insertDictationText(
                try container.decode(DictationInsertionOperation.self, forKey: .insertDictationText)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .toolName,
                in: container,
                debugDescription: "Unsupported semantic tool \(toolName)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(semanticToolName, forKey: .toolName)
        switch self {
        case let .application(operation):
            try container.encode(operation, forKey: .application)
        case let .insertDictationText(operation):
            try container.encode(operation, forKey: .insertDictationText)
        }
    }
}

public enum ActionSource: String, Codable, Hashable, Sendable {
    case backendAgent = "backend_agent"
    case backendWorkflow = "backend_workflow"
    case voiceDelegation = "voice_delegation"
    case dictation
    case claudeHook = "claude_hook"
    case userInitiated = "user_initiated"
}

public struct AgentRequirementBinding: Codable, Hashable, Sendable {
    public let agentID: String
    public let runID: String
    public let toolCallID: String

    public init(agentID: String, runID: String, toolCallID: String) {
        self.agentID = agentID
        self.runID = runID
        self.toolCallID = toolCallID
    }

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case runID = "run_id"
        case toolCallID = "tool_call_id"
    }
}

public struct WorkflowRequirementBinding: Codable, Hashable, Sendable {
    public let workflowID: String
    public let runID: String
    public let stepID: String
    public let executorID: String
    public let executorType: String
    public let toolCallID: String

    public init(
        workflowID: String,
        runID: String,
        stepID: String,
        executorID: String,
        executorType: String,
        toolCallID: String
    ) {
        self.workflowID = workflowID
        self.runID = runID
        self.stepID = stepID
        self.executorID = executorID
        self.executorType = executorType
        self.toolCallID = toolCallID
    }

    enum CodingKeys: String, CodingKey {
        case workflowID = "workflow_id"
        case runID = "run_id"
        case stepID = "step_id"
        case executorID = "executor_id"
        case executorType = "executor_type"
        case toolCallID = "tool_call_id"
    }
}

public enum ActionRequirementOrigin: Codable, Hashable, Sendable {
    case agent(AgentRequirementBinding)
    case workflow(WorkflowRequirementBinding)

    private enum CodingKeys: String, CodingKey {
        case runtime
        case agent
        case workflow
    }

    private enum Runtime: String, Codable {
        case agent
        case workflow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Runtime.self, forKey: .runtime) {
        case .agent:
            self = .agent(try container.decode(AgentRequirementBinding.self, forKey: .agent))
        case .workflow:
            self = .workflow(try container.decode(WorkflowRequirementBinding.self, forKey: .workflow))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .agent(binding):
            try container.encode(Runtime.agent, forKey: .runtime)
            try container.encode(binding, forKey: .agent)
        case let .workflow(binding):
            try container.encode(Runtime.workflow, forKey: .runtime)
            try container.encode(binding, forKey: .workflow)
        }
    }
}

public struct ActionCapabilityBinding: Codable, Hashable, Sendable {
    public let expectedToolName: String
    public let origin: ActionRequirementOrigin?

    public init(expectedToolName: String, origin: ActionRequirementOrigin? = nil) {
        self.expectedToolName = expectedToolName
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey {
        case expectedToolName = "expected_tool_name"
        case origin
    }
}

public struct ActionRequest: Codable, Hashable, Sendable {
    public let actionID: ActionID
    public let idempotencyKey: IdempotencyKey
    public let userID: UserID
    public let sessionID: ProductSessionID
    public let source: ActionSource
    public let target: ActionTarget
    public let operation: ActionOperation
    public let capability: ActionCapabilityBinding
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        actionID: ActionID = ActionID(),
        idempotencyKey: IdempotencyKey,
        userID: UserID,
        sessionID: ProductSessionID,
        source: ActionSource,
        target: ActionTarget,
        operation: ActionOperation,
        capability: ActionCapabilityBinding,
        createdAt: Date = Date(),
        expiresAt: Date
    ) {
        self.actionID = actionID
        self.idempotencyKey = idempotencyKey
        self.userID = userID
        self.sessionID = sessionID
        self.source = source
        self.target = target
        self.operation = operation
        self.capability = capability
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public var isStructurallyValid: Bool {
        !actionID.rawValue.isEmpty
            && !idempotencyKey.rawValue.isEmpty
            && !userID.rawValue.isEmpty
            && !sessionID.rawValue.isEmpty
            && createdAt <= expiresAt
            && target.isStructurallyValid
            && operation.contentHash.isValidSHA256
            && operation.hasValidContentBinding
            && capability.isStructurallyValid
            && capability.expectedToolName == operation.semanticToolName
            && target.matches(operation)
    }

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case idempotencyKey = "idempotency_key"
        case userID = "user_id"
        case sessionID = "session_id"
        case source
        case target
        case operation
        case capability
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

public extension ActionOperation {
    var hasValidContentBinding: Bool {
        switch self {
        case let .application(operation):
            operation.hasValidContentBinding
        case let .insertDictationText(operation):
            !operation.text.isEmpty && operation.contentHash == .sha256(of: operation.text)
        }
    }
}

public extension ActionTarget {
    var isStructurallyValid: Bool {
        switch self {
        case let .focusedApplication(target):
            !target.bundleIdentifier.isEmpty
                && (target.processIdentifier.map({ $0 > 0 }) ?? true)
                && (target.windowTitle.map({ !$0.isEmpty }) ?? true)
                && (target.elementRole.map({ !$0.isEmpty }) ?? true)
                && (target.elementLabel.map({ !$0.isEmpty }) ?? true)
        }
    }

    func matches(_ operation: ActionOperation) -> Bool {
        switch (self, operation) {
        case (.focusedApplication, .application): true
        case (.focusedApplication, .insertDictationText): true
        }
    }
}

public extension ActionRequirementOrigin {
    var isStructurallyValid: Bool {
        switch self {
        case let .agent(binding):
            !binding.agentID.isEmpty && !binding.runID.isEmpty && !binding.toolCallID.isEmpty
        case let .workflow(binding):
            !binding.workflowID.isEmpty
                && !binding.runID.isEmpty
                && !binding.stepID.isEmpty
                && !binding.executorID.isEmpty
                && !binding.executorType.isEmpty
                && !binding.toolCallID.isEmpty
        }
    }
}

public extension ActionCapabilityBinding {
    var isStructurallyValid: Bool {
        !expectedToolName.isEmpty && (origin?.isStructurallyValid ?? true)
    }
}

public enum ActionStatus: String, Codable, Hashable, Sendable {
    case opened
    case focused
    case inserted
    case activated
    case denied
    case expired
    case failed
    case cancelled
}

public enum ActionErrorCode: String, Codable, Hashable, Sendable {
    case invalidRequest = "invalid_request"
    case expired
    case policyDenied = "policy_denied"
    case humanReviewDenied = "human_review_denied"
    case secureInputActive = "secure_input_active"
    case capabilityMismatch = "capability_mismatch"
    case auditUnavailable = "audit_unavailable"
    case transportUnavailable = "transport_unavailable"
    case targetMismatch = "target_mismatch"
    case contentMismatch = "content_mismatch"
    case verificationFailed = "verification_failed"
    case idempotencyConflict = "idempotency_conflict"
    case persistenceFailure = "persistence_failure"
    case cancelled
    case unknown
}

public struct ActionResult: Codable, Hashable, Sendable {
    public let actionID: ActionID
    public let status: ActionStatus
    public let target: ActionTarget
    public let contentHash: ContentHash
    public let verified: Bool
    public let evidenceReference: EvidenceReference?
    public let errorCode: ActionErrorCode?
    public let completedAt: Date

    public init(
        actionID: ActionID,
        status: ActionStatus,
        target: ActionTarget,
        contentHash: ContentHash,
        verified: Bool,
        evidenceReference: EvidenceReference? = nil,
        errorCode: ActionErrorCode? = nil,
        completedAt: Date = Date()
    ) {
        self.actionID = actionID
        self.status = status
        self.target = target
        self.contentHash = contentHash
        self.verified = verified
        self.evidenceReference = evidenceReference
        self.errorCode = errorCode
        self.completedAt = completedAt
    }

    public static func failure(
        for request: ActionRequest,
        status: ActionStatus = .failed,
        code: ActionErrorCode
    ) -> ActionResult {
        ActionResult(
            actionID: request.actionID,
            status: status,
            target: request.target,
            contentHash: request.operation.contentHash,
            verified: false,
            errorCode: code
        )
    }

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case status
        case target
        case contentHash = "content_hash"
        case verified
        case evidenceReference = "evidence_ref"
        case errorCode = "error_code"
        case completedAt = "completed_at"
    }
}
