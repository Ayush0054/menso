import Foundation

/// A read-only UI projection. The security slice remains the owner of action,
/// policy, idempotency, execution, and audit domain models.
public struct PendingActionSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let sourceLabel: String
    public let targetLabel: String?
    public let expiresAt: Date?
    public let canCreateAlwaysRule: Bool

    public init(
        id: String,
        title: String,
        detail: String,
        sourceLabel: String,
        targetLabel: String? = nil,
        expiresAt: Date? = nil,
        canCreateAlwaysRule: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.sourceLabel = sourceLabel
        self.targetLabel = targetLabel
        self.expiresAt = expiresAt
        self.canCreateAlwaysRule = canCreateAlwaysRule
    }
}

public enum ActionPresentationDecision: Sendable {
    case allowOnce
    case deny
    case alwaysAllow
}
