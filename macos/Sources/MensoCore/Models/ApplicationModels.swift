import AppKit
import Foundation

public enum ApplicationKind: String, Codable, Sendable {
    case regular
    case accessory
    case background

    public init(activationPolicy: NSApplication.ActivationPolicy) {
        switch activationPolicy {
        case .regular:
            self = .regular
        case .accessory:
            self = .accessory
        case .prohibited:
            self = .background
        @unknown default:
            self = .background
        }
    }
}

public struct MonitoredApplicationSeed: Hashable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let localizedName: String
    public let executableURL: URL?
    public let kind: ApplicationKind
    public let isActive: Bool

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        localizedName: String,
        executableURL: URL?,
        kind: ApplicationKind,
        isActive: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.executableURL = executableURL
        self.kind = kind
        self.isActive = isActive
    }
}

public struct ApplicationSnapshot: Identifiable, Hashable, Sendable {
    public var id: Int32 { processIdentifier }

    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let localizedName: String
    public let executableURL: URL?
    public let kind: ApplicationKind
    public let isActive: Bool
    public let cpuPercent: Double?
    public let physicalFootprintBytes: UInt64?
    public let groupedProcessCount: Int
    public let frontmostWindowTitle: String?
    public let sampledAt: Date

    public init(
        seed: MonitoredApplicationSeed,
        cpuPercent: Double?,
        physicalFootprintBytes: UInt64?,
        groupedProcessCount: Int,
        frontmostWindowTitle: String?,
        sampledAt: Date = .now
    ) {
        processIdentifier = seed.processIdentifier
        bundleIdentifier = seed.bundleIdentifier
        localizedName = seed.localizedName
        executableURL = seed.executableURL
        kind = seed.kind
        isActive = seed.isActive
        self.cpuPercent = cpuPercent
        self.physicalFootprintBytes = physicalFootprintBytes
        self.groupedProcessCount = groupedProcessCount
        self.frontmostWindowTitle = frontmostWindowTitle
        self.sampledAt = sampledAt
    }
}

public struct AppMonitorState: Sendable {
    public var applications: [ApplicationSnapshot]
    public var secondsSinceUserInput: TimeInterval
    public var isSamplingPaused: Bool
    public var lastUpdatedAt: Date?

    public init(
        applications: [ApplicationSnapshot] = [],
        secondsSinceUserInput: TimeInterval = 0,
        isSamplingPaused: Bool = false,
        lastUpdatedAt: Date? = nil
    ) {
        self.applications = applications
        self.secondsSinceUserInput = secondsSinceUserInput
        self.isSamplingPaused = isSamplingPaused
        self.lastUpdatedAt = lastUpdatedAt
    }
}
