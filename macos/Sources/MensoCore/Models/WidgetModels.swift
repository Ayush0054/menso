import Foundation
import Observation

public enum ExpandedTab: String, CaseIterable, Codable, Sendable, Identifiable {
    case apps
    case agents
    case actions

    public var id: Self { self }

    public var title: String {
        rawValue.capitalized
    }
}

public enum RobotSpriteState: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case waitingForPermission
    case error
    case autoActing
    case dictating
    case voiceChat
}

public enum WidgetSize: String, Codable, Sendable, CaseIterable, Identifiable {
    case small
    case medium
    case large

    public var id: Self { self }

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    public var dimension: Double {
        switch self {
        case .small: 48
        case .medium: 64
        case .large: 80
        }
    }

    public var pixelScale: Double {
        switch self {
        case .small: 3
        case .medium: 4
        case .large: 5
        }
    }
}

public struct WidgetPreferences: Codable, Equatable, Sendable {
    public var doNotDisturb: Bool
    public var ghostMode: Bool
    public var size: WidgetSize
    public var hideInFullScreen: Bool
    public var excludeFromScreenShare: Bool
    public var launchAtLogin: Bool

    public init(
        doNotDisturb: Bool = false,
        ghostMode: Bool = false,
        size: WidgetSize = .medium,
        hideInFullScreen: Bool = false,
        excludeFromScreenShare: Bool = true,
        launchAtLogin: Bool = false
    ) {
        self.doNotDisturb = doNotDisturb
        self.ghostMode = ghostMode
        self.size = size
        self.hideInFullScreen = hideInFullScreen
        self.excludeFromScreenShare = excludeFromScreenShare
        self.launchAtLogin = launchAtLogin
    }
}

public enum DockEdge: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case top
    case bottom
}

public struct DockedWindowPosition: Codable, Equatable, Sendable {
    public var displayID: String
    public var edge: DockEdge
    public var fractionalOffset: Double
    public var isPeeking: Bool
    public var updatedAt: Date

    public init(
        displayID: String,
        edge: DockEdge,
        fractionalOffset: Double,
        isPeeking: Bool = false,
        updatedAt: Date = .now
    ) {
        self.displayID = displayID
        self.edge = edge
        self.fractionalOffset = min(max(fractionalOffset, 0), 1)
        self.isPeeking = isPeeking
        self.updatedAt = updatedAt
    }
}

public struct AgentFace: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var state: RobotSpriteState
    public var provider: AgentProvider?

    public init(
        id: String,
        name: String,
        state: RobotSpriteState,
        provider: AgentProvider? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.provider = provider
    }
}

@MainActor
@Observable
public final class WidgetPresentationModel {
    public var isExpanded = false
    public var isVisible = true
    public var selectedTab = ExpandedTab.apps
    public var preferences = WidgetPreferences()
    public var currentPosition: DockedWindowPosition?
    public var pendingActions: [PendingActionSummary] = []
    public var collapsedFaceCount = 1
    public var nonfatalMessage: String?

    public init() {}

    public func toggleExpanded() {
        isExpanded.toggle()
    }

    public func show(expanded: Bool? = nil) {
        isVisible = true
        if let expanded {
            isExpanded = expanded
        }
    }

    public func hide() {
        isVisible = false
    }
}
