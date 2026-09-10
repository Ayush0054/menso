import Carbon.HIToolbox
import Foundation

public enum SecureInputState: String, Codable, Hashable, Sendable {
    case disabled
    case enabled
    case unknown
}

public protocol SecureInputStateProviding: Sendable {
    func currentSecureInputState() async -> SecureInputState
}

/// Use until a signed app-owned adapter calls `IsSecureEventInputEnabled()`.
/// Unknown is intentionally treated exactly like enabled by `ActionExecutor`.
public struct FailClosedSecureInputStateProvider: SecureInputStateProviding {
    public init() {}

    public func currentSecureInputState() async -> SecureInputState {
        .unknown
    }
}

/// Signed-app adapter for the system secure-event-input state. ActionExecutor still treats any
/// alternate provider's `.unknown` exactly like `.enabled`.
public struct MacOSSecureInputStateProvider: SecureInputStateProviding {
    public init() {}

    public func currentSecureInputState() async -> SecureInputState {
        IsSecureEventInputEnabled() ? .enabled : .disabled
    }
}

public enum CuaDriverHostState: String, Codable, Hashable, Sendable {
    case stopped
    case starting
    case ready
    case unavailable
    case failed
}

/// App-owned lifecycle boundary for a supported CUA Driver embedding.
/// Implementations must keep CUA as a direct child of the signed app and must never use
/// `open`, `NSWorkspace`, a hosted backend, or an inherited raw MCP surface to launch it.
public protocol CuaDriverHost: Sendable {
    func state() async -> CuaDriverHostState
    func semanticTransport() async throws -> any CUASemanticTransport
    func stop() async
}

/// Marker for the reviewed direct-child host. The concrete implementation is
/// `PinnedEmbeddedCuaDriverHost`; alternate implementations must satisfy the
/// same resource pinning, private JSON-RPC, and post-action verification rules.
public protocol EmbeddedCuaDriverHost: CuaDriverHost {}

public enum CuaDriverHostError: Error, Sendable, Equatable {
    case notConfigured
    case unsupportedEmbedding
    case unavailable
}

/// Safe composition default for disabled or incomplete configuration. Production
/// composition uses `PinnedEmbeddedCuaDriverHost`; it never falls back to raw MCP.
public struct UnavailableCuaDriverHost: CuaDriverHost {
    public init() {}

    public func state() async -> CuaDriverHostState { .unavailable }

    public func semanticTransport() async throws -> any CUASemanticTransport {
        throw CuaDriverHostError.notConfigured
    }

    public func stop() async {}
}

public struct CUATextInsertionRequest: Hashable, Sendable {
    public let actionID: ActionID
    public let target: FocusedApplicationTarget
    public let text: String
    public let contentHash: ContentHash

    public init(
        actionID: ActionID,
        target: FocusedApplicationTarget,
        text: String,
        contentHash: ContentHash
    ) {
        self.actionID = actionID
        self.target = target
        self.text = text
        self.contentHash = contentHash
    }
}

public struct CUATextInsertionReceipt: Hashable, Sendable {
    public let actionID: ActionID
    public let target: FocusedApplicationTarget
    public let contentHash: ContentHash
    public let verified: Bool
    public let evidenceReference: EvidenceReference

    public init(
        actionID: ActionID,
        target: FocusedApplicationTarget,
        contentHash: ContentHash,
        verified: Bool,
        evidenceReference: EvidenceReference
    ) {
        self.actionID = actionID
        self.target = target
        self.contentHash = contentHash
        self.verified = verified
        self.evidenceReference = evidenceReference
    }
}

public struct CUAApplicationActionRequest: Hashable, Sendable {
    public let actionID: ActionID
    public let target: FocusedApplicationTarget
    public let operation: ApplicationSemanticOperation

    public init(
        actionID: ActionID,
        target: FocusedApplicationTarget,
        operation: ApplicationSemanticOperation
    ) {
        self.actionID = actionID
        self.target = target
        self.operation = operation
    }
}

public struct CUAApplicationActionReceipt: Hashable, Sendable {
    public let actionID: ActionID
    public let target: FocusedApplicationTarget
    public let actionKind: ApplicationSemanticActionKind
    public let contentHash: ContentHash
    public let verified: Bool
    public let evidenceReference: EvidenceReference

    public init(
        actionID: ActionID,
        target: FocusedApplicationTarget,
        actionKind: ApplicationSemanticActionKind,
        contentHash: ContentHash,
        verified: Bool,
        evidenceReference: EvidenceReference
    ) {
        self.actionID = actionID
        self.target = target
        self.actionKind = actionKind
        self.contentHash = contentHash
        self.verified = verified
        self.evidenceReference = evidenceReference
    }
}

/// The only CUA surface visible outside a host adapter. It exposes semantic, verifiable actions;
/// raw screenshots, clicks, typing, keys, selectors, coordinates, and unrestricted RPC are absent.
public protocol CUASemanticTransport: Sendable {
    func performApplicationAction(
        _ request: CUAApplicationActionRequest
    ) async throws -> CUAApplicationActionReceipt
}

/// Local dictation is not model-visible and retains its separate insertion
/// contract even though the public Agno Toolkit also has semantic `insert_text`.
public protocol CUATextInsertionTransport: Sendable {
    func insertText(_ request: CUATextInsertionRequest) async throws -> CUATextInsertionReceipt
}

public enum LocalToolBrokerError: Error, Sendable, Equatable {
    case unsupportedOperation
    case targetMismatch
    case contentMismatch
    case verificationFailed
    case driverUnavailable
    case persistenceFailure
}

public protocol SemanticActionBroker: Sendable {
    func execute(_ request: ActionRequest) async throws -> ActionResult
}

/// The broker owns semantic validation around the embedded host. It never exposes the host's raw protocol.
public actor LocalToolBroker: SemanticActionBroker {
    private let host: any CuaDriverHost

    public init(host: any CuaDriverHost) {
        self.host = host
    }

    public func execute(_ request: ActionRequest) async throws -> ActionResult {
        guard request.isStructurallyValid else {
            throw LocalToolBrokerError.unsupportedOperation
        }

        let transport: any CUASemanticTransport
        do {
            transport = try await host.semanticTransport()
        } catch {
            throw LocalToolBrokerError.driverUnavailable
        }

        switch (request.target, request.operation) {
        case let (.focusedApplication(target), .application(operation)):
            return try await performApplicationAction(
                request: request,
                target: target,
                operation: operation,
                transport: transport
            )
        case let (.focusedApplication(target), .insertDictationText(operation)):
            guard let transport = transport as? any CUATextInsertionTransport else {
                throw LocalToolBrokerError.unsupportedOperation
            }
            return try await insertText(
                request: request,
                target: target,
                operation: operation,
                transport: transport
            )
        }
    }

    private func performApplicationAction(
        request: ActionRequest,
        target: FocusedApplicationTarget,
        operation: ApplicationSemanticOperation,
        transport: any CUASemanticTransport
    ) async throws -> ActionResult {
        let receipt = try await transport.performApplicationAction(
            CUAApplicationActionRequest(
                actionID: request.actionID,
                target: target,
                operation: operation
            )
        )
        guard receipt.actionID == request.actionID,
              receipt.target == target,
              receipt.actionKind == operation.kind
        else { throw LocalToolBrokerError.targetMismatch }
        guard receipt.contentHash == operation.contentHash else {
            throw LocalToolBrokerError.contentMismatch
        }
        guard receipt.verified else {
            throw LocalToolBrokerError.verificationFailed
        }

        let status: ActionStatus
        switch operation.kind {
        case .openApplication: status = .opened
        case .focusWindow: status = .focused
        case .insertText: status = .inserted
        case .activateControl: status = .activated
        }
        return ActionResult(
            actionID: request.actionID,
            status: status,
            target: request.target,
            contentHash: receipt.contentHash,
            verified: true,
            evidenceReference: receipt.evidenceReference
        )
    }

    private func insertText(
        request: ActionRequest,
        target: FocusedApplicationTarget,
        operation: DictationInsertionOperation,
        transport: any CUATextInsertionTransport
    ) async throws -> ActionResult {
        let receipt = try await transport.insertText(
            CUATextInsertionRequest(
                actionID: request.actionID,
                target: target,
                text: operation.text,
                contentHash: operation.contentHash
            )
        )
        guard receipt.actionID == request.actionID, receipt.target == target else {
            throw LocalToolBrokerError.targetMismatch
        }
        guard receipt.contentHash == operation.contentHash else {
            throw LocalToolBrokerError.contentMismatch
        }
        guard receipt.verified else {
            throw LocalToolBrokerError.verificationFailed
        }

        return ActionResult(
            actionID: request.actionID,
            status: .inserted,
            target: request.target,
            contentHash: receipt.contentHash,
            verified: true,
            evidenceReference: receipt.evidenceReference
        )
    }
}
