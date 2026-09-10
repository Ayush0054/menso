import Foundation

public enum ExternalActionRequestFactoryError: Error, Sendable, Equatable {
    case unsupportedTool
    case missingField(String)
    case invalidField(String)
    case bindingMismatch(String)
    case expired
}

/// Converts the app-agnostic Menso CUA Toolkit pause into an exact local
/// request. Authentication, target authority, action identity, idempotency,
/// and expiry are app-owned and never accepted from model-visible arguments.
public struct ExternalActionRequestFactory: Sendable {
    public static let coreToolNames: Set<String> = [
        "open_application", "focus_window", "insert_text", "activate_control",
    ]

    public init() {}

    public func makeAgentActionRequest(
        continuation: AgentRunContinuation,
        toolCallID: String,
        expectedToolName: String,
        authenticatedUserID: UserID,
        authenticatedSessionID: ProductSessionID,
        trustedExpectedTarget: ActionTarget,
        trustedExpectedOperation: ActionOperation,
        trustedExpiresAt: Date,
        now: Date = Date()
    ) throws -> ActionRequest {
        guard continuation.userID == authenticatedUserID,
              continuation.sessionID == authenticatedSessionID
        else { throw ExternalActionRequestFactoryError.bindingMismatch("authenticated identity") }
        guard Self.coreToolNames.contains(expectedToolName) else {
            throw ExternalActionRequestFactoryError.unsupportedTool
        }
        guard trustedExpiresAt > now else { throw ExternalActionRequestFactoryError.expired }

        let matches = continuation.tools.filter {
            $0.toolCallID == toolCallID && $0.toolName == expectedToolName
        }
        guard matches.count == 1, let tool = matches.first,
              tool.isUnresolvedExternalExecution
        else { throw ExternalActionRequestFactoryError.bindingMismatch("tool call") }

        let arguments = try toolArguments(from: tool.fields)
        try rejectAuthorityOverrides(in: arguments)
        try validateArgumentKeys(toolName: expectedToolName, arguments: arguments)
        let target = try makeTarget(toolName: expectedToolName, arguments: arguments)
        guard target == trustedExpectedTarget else {
            throw ExternalActionRequestFactoryError.bindingMismatch("target")
        }
        let operation = try makeOperation(toolName: expectedToolName, arguments: arguments)
        guard operation == trustedExpectedOperation else {
            throw ExternalActionRequestFactoryError.bindingMismatch("operation")
        }
        let identity = ContentHash.sha256(
            of: ["agent", continuation.agentID, continuation.runID, toolCallID]
                .joined(separator: "\u{1f}")
        ).rawValue
        let request = ActionRequest(
            actionID: ActionID(rawValue: "agent:\(identity)"),
            idempotencyKey: IdempotencyKey(rawValue: "agent:\(identity)"),
            userID: authenticatedUserID,
            sessionID: authenticatedSessionID,
            source: .backendAgent,
            target: target,
            operation: operation,
            capability: ActionCapabilityBinding(
                expectedToolName: expectedToolName,
                origin: .agent(
                    AgentRequirementBinding(
                        agentID: continuation.agentID,
                        runID: continuation.runID,
                        toolCallID: toolCallID
                    )
                )
            ),
            createdAt: now,
            expiresAt: trustedExpiresAt
        )
        guard request.isStructurallyValid else {
            throw ExternalActionRequestFactoryError.invalidField("request")
        }
        return request
    }

    private func toolArguments(from fields: [String: JSONValue]) throws -> [String: JSONValue] {
        let execution = fields["tool_execution"]?.objectValue ?? fields
        guard let arguments = execution["tool_args"]?.objectValue else {
            throw ExternalActionRequestFactoryError.missingField("tool_args")
        }
        return arguments
    }

    private func makeTarget(
        toolName: String,
        arguments: [String: JSONValue]
    ) throws -> ActionTarget {
        let bundleIdentifier = try requiredString("bundle_id", in: arguments)
        let target: FocusedApplicationTarget
        switch toolName {
        case "open_application":
            target = FocusedApplicationTarget(bundleIdentifier: bundleIdentifier)
        case "focus_window":
            target = FocusedApplicationTarget(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: try requiredInt32("pid", in: arguments),
                windowTitle: try requiredString("window_title", in: arguments)
            )
        case "insert_text":
            target = FocusedApplicationTarget(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: try requiredInt32("pid", in: arguments),
                windowTitle: try requiredString("window_title", in: arguments),
                elementRole: try requiredString("field_role", in: arguments),
                elementLabel: try requiredString("field_label", in: arguments)
            )
        case "activate_control":
            target = FocusedApplicationTarget(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: try requiredInt32("pid", in: arguments),
                windowTitle: try requiredString("window_title", in: arguments),
                elementRole: try requiredString("control_role", in: arguments),
                elementLabel: try requiredString("control_label", in: arguments)
            )
        default:
            throw ExternalActionRequestFactoryError.unsupportedTool
        }
        return .focusedApplication(target)
    }

    private func makeOperation(
        toolName: String,
        arguments: [String: JSONValue]
    ) throws -> ActionOperation {
        switch toolName {
        case "open_application":
            return .application(ApplicationSemanticOperation(kind: .openApplication))
        case "focus_window":
            return .application(ApplicationSemanticOperation(kind: .focusWindow))
        case "insert_text":
            return .application(
                ApplicationSemanticOperation(
                    kind: .insertText,
                    text: try requiredString("text", in: arguments)
                )
            )
        case "activate_control":
            return .application(
                ApplicationSemanticOperation(
                    kind: .activateControl,
                    expectedState: try requiredString("expected_state", in: arguments)
                )
            )
        default:
            throw ExternalActionRequestFactoryError.unsupportedTool
        }
    }

    private func rejectAuthorityOverrides(in arguments: [String: JSONValue]) throws {
        let forbidden = [
            "action_id", "user_id", "session_id", "run_id", "agent_id",
            "workflow_id", "step_id", "executor_id", "tool_call_id",
            "expected_tool_name", "idempotency_key", "expires_at",
        ]
        for key in forbidden where arguments[key] != nil {
            throw ExternalActionRequestFactoryError.invalidField(key)
        }
    }

    private func validateArgumentKeys(
        toolName: String,
        arguments: [String: JSONValue]
    ) throws {
        let allowed: Set<String>
        switch toolName {
        case "open_application": allowed = ["bundle_id"]
        case "focus_window": allowed = ["bundle_id", "pid", "window_title"]
        case "insert_text":
            allowed = ["bundle_id", "pid", "text", "window_title", "field_role", "field_label"]
        case "activate_control":
            allowed = [
                "bundle_id", "pid", "window_title", "control_role", "control_label", "expected_state",
            ]
        default: throw ExternalActionRequestFactoryError.unsupportedTool
        }
        guard Set(arguments.keys).isSubset(of: allowed) else {
            throw ExternalActionRequestFactoryError.invalidField("unexpected tool argument")
        }
        if toolName == "insert_text" {
            let roles = Set(["AXTextField", "AXTextArea", "AXSearchField"])
            guard let role = arguments["field_role"]?.stringValue, roles.contains(role) else {
                throw ExternalActionRequestFactoryError.invalidField("field_role")
            }
        }
        if toolName == "activate_control" {
            let roles = Set(["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton"])
            guard let role = arguments["control_role"]?.stringValue, roles.contains(role) else {
                throw ExternalActionRequestFactoryError.invalidField("control_role")
            }
        }
    }

    private func requiredString(
        _ key: String,
        in arguments: [String: JSONValue]
    ) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw ExternalActionRequestFactoryError.missingField(key)
        }
        return value
    }

    private func optionalString(
        _ key: String,
        in arguments: [String: JSONValue]
    ) -> String? {
        arguments[key]?.stringValue
    }

    private func requiredInt32(
        _ key: String,
        in arguments: [String: JSONValue]
    ) throws -> Int32 {
        guard let number = arguments[key]?.numberValue else {
            throw ExternalActionRequestFactoryError.missingField(key)
        }
        let value: Int32?
        switch number {
        case let .signedInteger(number): value = Int32(exactly: number)
        case let .unsignedInteger(number): value = Int32(exactly: number)
        case .decimal: value = nil
        }
        guard let value, value > 0 else {
            throw ExternalActionRequestFactoryError.invalidField(key)
        }
        return value
    }
}
