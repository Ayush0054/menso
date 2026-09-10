import Foundation

public enum MensoPermission: String, CaseIterable, Codable, Hashable, Sendable {
    case accessibility
    case microphone
    case notifications
    case automation
    case speechRecognition = "speech_recognition"
    case screenRecording = "screen_recording"
    case inputMonitoring = "input_monitoring"
    case fullDiskAccess = "full_disk_access"
}

public enum PermissionAuthorizationStatus: String, Codable, Hashable, Sendable {
    case notDetermined = "not_determined"
    case authorized
    case denied
    case restricted
    case unavailable
    case unknown
}

public struct PermissionHealth: Identifiable, Codable, Hashable, Sendable {
    public var id: MensoPermission { permission }
    public let permission: MensoPermission
    public let status: PermissionAuthorizationStatus
    public let lastCheckedAt: Date
    public let settingsDeepLink: URL?
    public let detail: String?

    public init(
        permission: MensoPermission,
        status: PermissionAuthorizationStatus,
        lastCheckedAt: Date = Date(),
        settingsDeepLink: URL? = nil,
        detail: String? = nil
    ) {
        self.permission = permission
        self.status = status
        self.lastCheckedAt = lastCheckedAt
        self.settingsDeepLink = settingsDeepLink
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case permission
        case status
        case lastCheckedAt = "last_checked_at"
        case settingsDeepLink = "settings_deep_link"
        case detail
    }
}

public enum MensoCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case appMonitoring = "app_monitoring"
    case windowTitleMonitoring = "window_title_monitoring"
    case dictation
    case localParakeetDictation = "local_parakeet_dictation"
    case appleSpeechDictation = "apple_speech_dictation"
    case liveVoice = "live_voice"
    case semanticComputerUse = "semantic_computer_use"
    case terminalAppleScript = "terminal_applescript"
}

public enum CapabilityReadiness: String, Codable, Hashable, Sendable {
    case ready
    case missingRequiredPermission = "missing_required_permission"
    case unavailable
}

public struct CapabilityPermissionHealth: Codable, Hashable, Sendable {
    public let capability: MensoCapability
    public let readiness: CapabilityReadiness
    public let requiredPermissions: Set<MensoPermission>
    public let missingPermissions: Set<MensoPermission>

    public init(
        capability: MensoCapability,
        readiness: CapabilityReadiness,
        requiredPermissions: Set<MensoPermission>,
        missingPermissions: Set<MensoPermission>
    ) {
        self.capability = capability
        self.readiness = readiness
        self.requiredPermissions = requiredPermissions
        self.missingPermissions = missingPermissions
    }

    enum CodingKeys: String, CodingKey {
        case capability
        case readiness
        case requiredPermissions = "required_permissions"
        case missingPermissions = "missing_permissions"
    }
}

public struct PermissionHealthSnapshot: Codable, Hashable, Sendable {
    public let checkedAt: Date
    public let permissions: [MensoPermission: PermissionHealth]

    public init(checkedAt: Date = Date(), permissions: [MensoPermission: PermissionHealth]) {
        self.checkedAt = checkedAt
        self.permissions = permissions
    }

    public func health(for capability: MensoCapability) -> CapabilityPermissionHealth {
        let required = PermissionPolicy.requiredPermissions(for: capability)
        let missing = Set(required.filter { permissions[$0]?.status != .authorized })
        let unavailable = missing.contains { permissions[$0]?.status == .unavailable }
        return CapabilityPermissionHealth(
            capability: capability,
            readiness: unavailable ? .unavailable : (missing.isEmpty ? .ready : .missingRequiredPermission),
            requiredPermissions: required,
            missingPermissions: missing
        )
    }
}

public enum PermissionPolicy {
    /// Input Monitoring and Full Disk Access intentionally never appear in a capability requirement.
    public static func requiredPermissions(for capability: MensoCapability) -> Set<MensoPermission> {
        switch capability {
        case .appMonitoring:
            []
        case .windowTitleMonitoring:
            [.accessibility]
        case .dictation, .localParakeetDictation:
            [.microphone, .accessibility]
        case .appleSpeechDictation:
            [.microphone, .accessibility, .speechRecognition]
        case .liveVoice:
            [.microphone]
        case .semanticComputerUse:
            [.accessibility]
        case .terminalAppleScript:
            [.automation]
        }
    }

    public static func mayPrompt(_ permission: MensoPermission, for capability: MensoCapability) -> Bool {
        guard permission != .inputMonitoring, permission != .fullDiskAccess else { return false }
        guard requiredPermissions(for: capability).contains(permission) else { return false }
        // The current semantic CUA adapter is AX-only. Screen Recording is not
        // a requirement until a separately typed visual capability exists.
        if permission == .screenRecording { return false }
        return true
    }
}

public protocol PermissionStatusChecking: Sendable {
    func authorizationStatus(for permission: MensoPermission) async -> PermissionAuthorizationStatus
    func settingsDeepLink(for permission: MensoPermission) async -> URL?
}

public protocol PermissionPrompting: Sendable {
    func request(_ permission: MensoPermission) async throws -> PermissionAuthorizationStatus
}

public actor PermissionHealthMonitor {
    private let checker: any PermissionStatusChecking
    private let now: @Sendable () -> Date
    private var continuations: [UUID: AsyncStream<PermissionHealthSnapshot>.Continuation] = [:]
    private var latestSnapshot: PermissionHealthSnapshot?

    public init(
        checker: any PermissionStatusChecking,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.checker = checker
        self.now = now
    }

    public func updates(bufferLimit: Int = 8) -> AsyncStream<PermissionHealthSnapshot> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: PermissionHealthSnapshot.self,
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
        )
        continuations[id] = pair.continuation
        if let latestSnapshot { pair.continuation.yield(latestSnapshot) }
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return pair.stream
    }

    /// Call on foregrounding and after returning from System Settings to detect silent TCC revocation.
    @discardableResult
    public func refresh() async -> PermissionHealthSnapshot {
        let checkedAt = now()
        var health: [MensoPermission: PermissionHealth] = [:]
        for permission in MensoPermission.allCases {
            let status = await checker.authorizationStatus(for: permission)
            health[permission] = PermissionHealth(
                permission: permission,
                status: status,
                lastCheckedAt: checkedAt,
                settingsDeepLink: await checker.settingsDeepLink(for: permission)
            )
        }
        let snapshot = PermissionHealthSnapshot(checkedAt: checkedAt, permissions: health)
        latestSnapshot = snapshot
        for continuation in continuations.values { continuation.yield(snapshot) }
        return snapshot
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

public actor PermissionRequestCoordinator {
    private let checker: any PermissionStatusChecking
    private let prompter: any PermissionPrompting

    public init(checker: any PermissionStatusChecking, prompter: any PermissionPrompting) {
        self.checker = checker
        self.prompter = prompter
    }

    public func request(
        _ permission: MensoPermission,
        for capability: MensoCapability
    ) async throws -> PermissionAuthorizationStatus {
        guard PermissionPolicy.mayPrompt(permission, for: capability) else {
            throw PermissionHealthError.prohibitedPrompt
        }
        let current = await checker.authorizationStatus(for: permission)
        // Accessibility and Screen Recording do not expose a public
        // not-determined state. Their preflight APIs return false for both
        // never-requested and denied, while their explicit request APIs safely
        // prompt or direct the user to System Settings. This coordinator is
        // reached only from an explicit UI action and the capability guard above
        // keeps Screen Recording at the semantic-CUA enablement boundary.
        let supportsExplicitRetry = permission == .accessibility || permission == .screenRecording
        guard current == .notDetermined || (current == .denied && supportsExplicitRetry) else {
            return current
        }
        return try await prompter.request(permission)
    }
}

public enum PermissionHealthError: Error, Sendable, Equatable {
    case prohibitedPrompt
}
