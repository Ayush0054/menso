import Foundation

public struct PolicyRuleID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct HumanReviewID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }
}

public enum PolicyRuleDisposition: String, Codable, Hashable, Sendable {
    case automatic
    case humanReview = "human_review"
}

public enum PolicyTargetConstraint: Codable, Hashable, Sendable {
    case focusedApplication(
        bundleIdentifier: String,
        processIdentifier: Int32? = nil,
        windowTitle: String? = nil,
        elementRole: String? = nil,
        elementLabel: String? = nil
    )

    public func matches(_ target: ActionTarget) -> Bool {
        switch (self, target) {
        case let (
            .focusedApplication(
                bundleIdentifier,
                processIdentifier,
                windowTitle,
                elementRole,
                elementLabel
            ),
            .focusedApplication(target)
        ):
            bundleIdentifier == target.bundleIdentifier
                && processIdentifier == target.processIdentifier
                && windowTitle == target.windowTitle
                && elementRole == target.elementRole
                && elementLabel == target.elementLabel
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case bundleIdentifier = "bundle_id"
        case processIdentifier = "pid"
        case windowTitle = "window_title"
        case elementRole = "element_role"
        case elementLabel = "element_label"
    }

    private enum Kind: String, Codable {
        case focusedApplication = "focused_application"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .focusedApplication:
            self = .focusedApplication(
                bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
                processIdentifier: try container.decodeIfPresent(Int32.self, forKey: .processIdentifier),
                windowTitle: try container.decodeIfPresent(String.self, forKey: .windowTitle),
                elementRole: try container.decodeIfPresent(String.self, forKey: .elementRole),
                elementLabel: try container.decodeIfPresent(String.self, forKey: .elementLabel)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .focusedApplication(
            bundleIdentifier,
            processIdentifier,
            windowTitle,
            elementRole,
            elementLabel
        ):
            try container.encode(Kind.focusedApplication, forKey: .kind)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
            try container.encodeIfPresent(processIdentifier, forKey: .processIdentifier)
            try container.encodeIfPresent(windowTitle, forKey: .windowTitle)
            try container.encodeIfPresent(elementRole, forKey: .elementRole)
            try container.encodeIfPresent(elementLabel, forKey: .elementLabel)
        }
    }
}

public struct PolicyRule: Codable, Hashable, Sendable {
    public let id: PolicyRuleID
    public let semanticToolName: String
    public let allowedSources: Set<ActionSource>
    public let target: PolicyTargetConstraint
    public let disposition: PolicyRuleDisposition
    public let requiredActionID: ActionID?
    public let requiredContentHash: ContentHash?
    public let expiresAt: Date?

    public init(
        id: PolicyRuleID,
        semanticToolName: String,
        allowedSources: Set<ActionSource>,
        target: PolicyTargetConstraint,
        disposition: PolicyRuleDisposition,
        requiredActionID: ActionID? = nil,
        requiredContentHash: ContentHash? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.semanticToolName = semanticToolName
        self.allowedSources = allowedSources
        self.target = target
        self.disposition = disposition
        self.requiredActionID = requiredActionID
        self.requiredContentHash = requiredContentHash
        self.expiresAt = expiresAt
    }

    fileprivate func matches(_ request: ActionRequest, at date: Date) -> Bool {
        guard semanticToolName == request.operation.semanticToolName,
              allowedSources.contains(request.source),
              target.matches(request.target),
              expiresAt.map({ $0 > date }) ?? true,
              requiredActionID.map({ $0 == request.actionID }) ?? true,
              requiredContentHash.map({ $0 == request.operation.contentHash }) ?? true
        else {
            return false
        }

        return true
    }

    enum CodingKeys: String, CodingKey {
        case id
        case semanticToolName = "semantic_tool_name"
        case allowedSources = "allowed_sources"
        case target
        case disposition
        case requiredActionID = "required_action_id"
        case requiredContentHash = "required_content_hash"
        case expiresAt = "expires_at"
    }
}

public struct ActionPolicyConfiguration: Codable, Hashable, Sendable {
    public let rules: [PolicyRule]

    public init(rules: [PolicyRule] = []) {
        self.rules = rules
    }

    public static let denyAll = ActionPolicyConfiguration()
}

public enum PolicyDenyReason: String, Codable, Hashable, Sendable {
    case malformedRequest = "malformed_request"
    case expired
    case capabilityMismatch = "capability_mismatch"
    case runtimeOriginMismatch = "runtime_origin_mismatch"
    case notAllowlisted = "not_allowlisted"
    case reviewDenied = "review_denied"
    case reviewExpired = "review_expired"
    case reviewBindingMismatch = "review_binding_mismatch"
    case auditUnavailable = "audit_unavailable"
}

public struct PolicyAuthorization: Hashable, Sendable {
    public let actionID: ActionID
    public let authorizationNonce: UUID
    public let ruleID: PolicyRuleID?
    public let reviewID: HumanReviewID?

    fileprivate init(actionID: ActionID, ruleID: PolicyRuleID?, reviewID: HumanReviewID?) {
        self.actionID = actionID
        self.authorizationNonce = UUID()
        self.ruleID = ruleID
        self.reviewID = reviewID
    }
}

public struct HumanReviewRequirement: Codable, Hashable, Sendable {
    public let id: HumanReviewID
    public let actionID: ActionID
    public let semanticToolName: String
    public let target: ActionTarget
    public let contentHash: ContentHash
    public let expiresAt: Date
    public let authority: ActionExecutionBinding

    public init(
        id: HumanReviewID,
        actionID: ActionID,
        semanticToolName: String,
        target: ActionTarget,
        contentHash: ContentHash,
        expiresAt: Date,
        authority: ActionExecutionBinding
    ) {
        self.id = id
        self.actionID = actionID
        self.semanticToolName = semanticToolName
        self.target = target
        self.contentHash = contentHash
        self.expiresAt = expiresAt
        self.authority = authority
    }

    enum CodingKeys: String, CodingKey {
        case id
        case actionID = "action_id"
        case semanticToolName = "semantic_tool_name"
        case target
        case contentHash = "content_hash"
        case expiresAt = "expires_at"
        case authority
    }
}

public enum HumanReviewResolution: String, Codable, Hashable, Sendable {
    case approveOnce = "approve_once"
    case alwaysAllow = "always_allow"
    case deny
}

public enum PolicyDecision: Hashable, Sendable {
    case allow(PolicyAuthorization)
    case requireHumanReview(HumanReviewRequirement)
    case deny(PolicyDenyReason)

    public var summary: PolicyDecisionSummary {
        switch self {
        case let .allow(authorization):
            .allowed(ruleID: authorization.ruleID, reviewID: authorization.reviewID)
        case let .requireHumanReview(requirement):
            .humanReviewRequired(reviewID: requirement.id)
        case let .deny(reason):
            .denied(reason: reason)
        }
    }
}

public enum PolicyDecisionSummary: Hashable, Sendable {
    case allowed(ruleID: PolicyRuleID?, reviewID: HumanReviewID?)
    case humanReviewRequired(reviewID: HumanReviewID)
    case denied(reason: PolicyDenyReason)
}

private struct PendingReview: Sendable {
    let request: ActionRequest
    let requirement: HumanReviewRequirement
}

private struct ApprovedReview: Sendable {
    let requirement: HumanReviewRequirement
}

/// The model can submit an `ActionRequest`, but only this actor can authorize it.
/// Missing rules, malformed bindings, and missing review state all deny by default.
public actor PolicyEngine {
    private var configuration: ActionPolicyConfiguration
    private var pendingReviews: [HumanReviewID: PendingReview] = [:]
    private var reviewByAction: [ActionID: HumanReviewID] = [:]
    private var approvedReviews: [ActionID: ApprovedReview] = [:]
    private var deniedActions: Set<ActionID> = []
    private let auditSink: any ActionAuditSink
    private let now: @Sendable () -> Date
    private let alwaysRuleLifetime: TimeInterval

    public init(
        configuration: ActionPolicyConfiguration = .denyAll,
        auditSink: any ActionAuditSink,
        alwaysRuleLifetime: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.auditSink = auditSink
        // Always rules remain intentionally bounded even if composition passes an unsafe value.
        self.alwaysRuleLifetime = min(max(alwaysRuleLifetime, 60), 7 * 24 * 60 * 60)
        self.now = now
    }

    /// Configuration changes are a trusted-client UI/settings operation, never an action-request field.
    public func replaceConfiguration(_ configuration: ActionPolicyConfiguration) {
        self.configuration = configuration
    }

    public func configurationSnapshot() -> ActionPolicyConfiguration {
        configuration
    }

    /// Adds one review-only rule for an already authenticated and target-bound
    /// runtime request. The action id and content hash make this authority
    /// unusable by another run, tool call, or model-proposed payload.
    public func requireReviewForBoundRequest(_ request: ActionRequest) {
        registerBoundRequest(request, disposition: .humanReview)
    }

    /// Only routine navigation from the native task runner may skip review.
    /// Writes and controls retain review; no model-supplied risk label is used.
    func authorizeTaskNavigation(_ request: ActionRequest) {
        guard request.source == .nativeVoice,
              case let .application(operation) = request.operation,
              [.openApplication, .focusWindow].contains(operation.kind) else { return }
        registerBoundRequest(request, disposition: .automatic)
    }

    func removeTaskRule(for request: ActionRequest) {
        let id = PolicyRuleID(rawValue: "bound-review:\(request.actionID.rawValue)")
        configuration = ActionPolicyConfiguration(rules: configuration.rules.filter { $0.id != id })
    }

    private func registerBoundRequest(_ request: ActionRequest, disposition: PolicyRuleDisposition) {
        guard request.isStructurallyValid, request.expiresAt > now() else { return }
        let target: PolicyTargetConstraint
        switch request.target {
        case let .focusedApplication(value):
            target = .focusedApplication(
                bundleIdentifier: value.bundleIdentifier,
                processIdentifier: value.processIdentifier,
                windowTitle: value.windowTitle,
                elementRole: value.elementRole,
                elementLabel: value.elementLabel
            )
        }
        let rule = PolicyRule(
            id: PolicyRuleID(rawValue: "bound-review:\(request.actionID.rawValue)"),
            semanticToolName: request.operation.semanticToolName,
            allowedSources: [request.source],
            target: target,
            disposition: disposition,
            requiredActionID: request.actionID,
            requiredContentHash: request.operation.contentHash,
            expiresAt: request.expiresAt
        )
        let retained = configuration.rules.filter { $0.id != rule.id }
        configuration = ActionPolicyConfiguration(rules: retained + [rule])
    }

    /// Rehydrates only an exact app-persisted review tuple. This does not infer
    /// policy from the request and does not create new executable authority.
    @discardableResult
    public func restoreHumanReview(
        request: ActionRequest,
        requirement: HumanReviewRequirement
    ) -> Bool {
        let currentDate = now()
        guard request.isStructurallyValid,
              request.expiresAt > currentDate,
              requirement.expiresAt > currentDate,
              requirement.matches(request)
        else { return false }

        if let existing = pendingReviews[requirement.id] {
            return existing.request == request && existing.requirement == requirement
        }
        if let existingID = reviewByAction[request.actionID], existingID != requirement.id {
            return false
        }
        pendingReviews[requirement.id] = PendingReview(
            request: request,
            requirement: requirement
        )
        reviewByAction[request.actionID] = requirement.id
        return true
    }

    public func evaluate(_ request: ActionRequest) -> PolicyDecision {
        let currentDate = now()

        guard request.isStructurallyValid else {
            return .deny(.malformedRequest)
        }
        guard request.expiresAt > currentDate else {
            return .deny(.expired)
        }
        guard request.capability.expectedToolName == request.operation.semanticToolName else {
            return .deny(.capabilityMismatch)
        }
        guard Self.originMatchesSource(request) else {
            return .deny(.runtimeOriginMismatch)
        }
        guard !deniedActions.contains(request.actionID) else {
            return .deny(.reviewDenied)
        }

        if let approved = approvedReviews[request.actionID] {
            guard approved.requirement.matches(request), approved.requirement.expiresAt > currentDate else {
                return .deny(.reviewBindingMismatch)
            }
            return .allow(
                PolicyAuthorization(actionID: request.actionID, ruleID: nil, reviewID: approved.requirement.id)
            )
        }

        let matchingRules = configuration.rules.filter { $0.matches(request, at: currentDate) }
        guard !matchingRules.isEmpty else {
            return .deny(.notAllowlisted)
        }

        // A one-shot approval coordinator may install a rule for only this
        // already-bound action after consuming an exact durable approval
        // intent. It can supersede a broader review rule, but no target-only or
        // draft-only automatic rule can bypass review this way.
        if let exactAutomaticRule = matchingRules.first(where: {
            $0.disposition == .automatic && $0.requiredActionID == request.actionID
        }) {
            return .allow(
                PolicyAuthorization(
                    actionID: request.actionID,
                    ruleID: exactAutomaticRule.id,
                    reviewID: nil
                )
            )
        }

        // If any matching rule asks for review, review wins over a broader automatic rule.
        if let reviewRule = matchingRules.first(where: { $0.disposition == .humanReview }) {
            if let existingID = reviewByAction[request.actionID],
               let existing = pendingReviews[existingID],
               existing.requirement.expiresAt > currentDate,
               existing.requirement.matches(request)
            {
                return .requireHumanReview(existing.requirement)
            }

            let requirement = HumanReviewRequirement(
                id: HumanReviewID(),
                actionID: request.actionID,
                semanticToolName: request.operation.semanticToolName,
                target: request.target,
                contentHash: request.operation.contentHash,
                expiresAt: min(request.expiresAt, reviewRule.expiresAt ?? request.expiresAt),
                authority: ActionExecutionBinding(request: request)
            )
            pendingReviews[requirement.id] = PendingReview(request: request, requirement: requirement)
            reviewByAction[request.actionID] = requirement.id
            return .requireHumanReview(requirement)
        }

        guard let automaticRule = matchingRules.first(where: { $0.disposition == .automatic }) else {
            return .deny(.notAllowlisted)
        }
        return .allow(
            PolicyAuthorization(actionID: request.actionID, ruleID: automaticRule.id, reviewID: nil)
        )
    }

    /// Human review is deliberately separate from `ActionRequest`; untrusted content cannot set this value.
    public func resolveHumanReview(
        id: HumanReviewID,
        resolution: HumanReviewResolution
    ) async -> PolicyDecision {
        guard let pending = pendingReviews.removeValue(forKey: id) else {
            return .deny(.reviewBindingMismatch)
        }
        reviewByAction.removeValue(forKey: pending.request.actionID)

        guard pending.requirement.expiresAt > now() else {
            return .deny(.reviewExpired)
        }

        do {
            try await auditSink.record(
                .humanReviewResolved(
                    actionID: pending.request.actionID,
                    reviewID: id,
                    resolution: resolution,
                    recordedAt: now()
                )
            )
        } catch {
            return .deny(.auditUnavailable)
        }

        switch resolution {
        case .approveOnce:
            approvedReviews[pending.request.actionID] = ApprovedReview(requirement: pending.requirement)
            return .allow(
                PolicyAuthorization(actionID: pending.request.actionID, ruleID: nil, reviewID: id)
            )
        case .alwaysAllow:
            let rule = Self.makeAlwaysRule(
                from: pending.request,
                expiresAt: min(
                    pending.request.expiresAt,
                    now().addingTimeInterval(alwaysRuleLifetime)
                )
            )
            configuration = ActionPolicyConfiguration(rules: configuration.rules + [rule])
            return .allow(
                PolicyAuthorization(actionID: pending.request.actionID, ruleID: rule.id, reviewID: id)
            )
        case .deny:
            deniedActions.insert(pending.request.actionID)
            return .deny(.reviewDenied)
        }
    }

    private static func originMatchesSource(_ request: ActionRequest) -> Bool {
        switch (request.source, request.capability.origin) {
        case (.backendAgent, .agent): true
        case (.backendWorkflow, .workflow): true
        case (.backendAgent, _), (.backendWorkflow, _): false
        case (.voiceDelegation, .agent), (.voiceDelegation, .workflow): true
        case (.voiceDelegation, nil): false
        case (.nativeVoice, nil): true
        case (.nativeVoice, _): false
        case (.dictation, nil), (.claudeHook, nil), (.userInitiated, nil): true
        case (.dictation, _), (.claudeHook, _), (.userInitiated, _): false
        }
    }

    /// Constructs a client-owned narrow rule exclusively from the already-bound reviewed request.
    /// No rule fields are accepted from model content or the action request as free-form policy input.
    private static func makeAlwaysRule(from request: ActionRequest, expiresAt: Date) -> PolicyRule {
        let target: PolicyTargetConstraint
        switch request.target {
        case let .focusedApplication(value):
            target = .focusedApplication(
                bundleIdentifier: value.bundleIdentifier,
                processIdentifier: value.processIdentifier,
                windowTitle: value.windowTitle,
                elementRole: value.elementRole,
                elementLabel: value.elementLabel
            )
        }

        return PolicyRule(
            id: PolicyRuleID(rawValue: "client-always:\(UUID().uuidString.lowercased())"),
            semanticToolName: request.operation.semanticToolName,
            allowedSources: [request.source],
            target: target,
            disposition: .automatic,
            requiredContentHash: request.operation.contentHash,
            expiresAt: expiresAt
        )
    }
}

extension HumanReviewRequirement {
    func matches(_ request: ActionRequest) -> Bool {
        guard authority == ActionExecutionBinding(request: request),
              actionID == request.actionID,
              semanticToolName == request.operation.semanticToolName,
              target == request.target,
              contentHash == request.operation.contentHash
        else {
            return false
        }

        return true
    }
}
