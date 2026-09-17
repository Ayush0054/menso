import CryptoKit
import Foundation

public enum PersistedVoiceDelegationState: String, Codable, Hashable, Sendable {
    /// The request was durably recorded before AgentOS delegation began. After a
    /// process restart Menso does not submit it again because the first submit
    /// may have succeeded even when its response was not observed.
    case inFlight = "in_flight"
    /// The result is durably available but has not been accepted by the
    /// original GPT-Live delegation.
    case awaitingOriginalCall = "awaiting_original_call"
    /// The original GPT-Live data channel accepted the delegation result.
    case deliveredToOriginalCall = "delivered_to_original_call"
    /// The replacement GPT-Live adapter's local data channel accepted this
    /// record as continuity data. This is deliberately not a function-call output.
    case representedInReplacement = "represented_in_replacement"
}

public struct PersistedVoiceDelegation: Codable, Hashable, Sendable {
    public let recordID: String
    public let providerSessionID: String
    public let callID: String
    public let request: VoiceDelegationRequest
    public let state: PersistedVoiceDelegationState
    public let result: VoiceDelegationResult?
    public let recordedAt: Date
    public let updatedAt: Date

    public init(
        recordID: String,
        providerSessionID: String,
        callID: String,
        request: VoiceDelegationRequest,
        state: PersistedVoiceDelegationState,
        result: VoiceDelegationResult?,
        recordedAt: Date,
        updatedAt: Date
    ) throws {
        guard !providerSessionID.isEmpty,
              providerSessionID.utf8.count <= 128,
              UUID(uuidString: providerSessionID) != nil,
              callID.utf8.count <= 256,
              !callID.isEmpty,
              callID == request.callID,
              recordID == Self.makeRecordID(
                  providerSessionID: providerSessionID,
                  callID: callID
              ),
              !request.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.task.utf8.count <= 4_000,
              request.contextReferences.count <= 20,
              request.contextReferences.allSatisfy({ reference in
                  !reference.isEmpty && reference.utf8.count <= 1_024
              }),
              updatedAt >= recordedAt,
              (state == .inFlight) == (result == nil)
        else {
            throw LiveVoiceContinuityError.invalidDelegationRecord
        }
        self.recordID = recordID
        self.providerSessionID = providerSessionID
        self.callID = callID
        self.request = request
        self.state = state
        self.result = result
        self.recordedAt = recordedAt
        self.updatedAt = updatedAt
    }

    public func replacing(
        state: PersistedVoiceDelegationState,
        result: VoiceDelegationResult?,
        updatedAt: Date
    ) throws -> PersistedVoiceDelegation {
        try PersistedVoiceDelegation(
            recordID: recordID,
            providerSessionID: providerSessionID,
            callID: callID,
            request: request,
            state: state,
            result: result,
            recordedAt: recordedAt,
            updatedAt: updatedAt
        )
    }

    static func makeRecordID(providerSessionID: String, callID: String) -> String {
        let digest = SHA256.hash(data: Data("\(providerSessionID)\u{0}\(callID)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var isValid: Bool {
        (try? PersistedVoiceDelegation(
            recordID: recordID,
            providerSessionID: providerSessionID,
            callID: callID,
            request: request,
            state: state,
            result: result,
            recordedAt: recordedAt,
            updatedAt: updatedAt
        )) != nil
    }
}

public struct LiveVoiceContinuityCheckpoint: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let userID: UserID
    public let productSessionID: ProductSessionID
    public let finalTranscript: [LiveTranscriptSegment]
    public let delegations: [PersistedVoiceDelegation]
    public let updatedAt: Date

    public init(
        userID: UserID,
        productSessionID: ProductSessionID,
        finalTranscript: [LiveTranscriptSegment],
        delegations: [PersistedVoiceDelegation],
        updatedAt: Date
    ) throws {
        guard !userID.rawValue.isEmpty,
              userID.rawValue.utf8.count <= 256,
              UUID(uuidString: productSessionID.rawValue) != nil,
              finalTranscript.count <= LiveVoiceContinuityLimits.maximumFinalTranscriptSegments,
              finalTranscript.allSatisfy({
                  $0.isFinal
                    && !$0.text.isEmpty
                    && $0.text.utf8.count <= LiveVoiceContinuityLimits.maximumTranscriptSegmentBytes
              }),
              delegations.count <= LiveVoiceContinuityLimits.maximumDelegationRecords,
              delegations.allSatisfy({ $0.isValid }),
              Set(delegations.map(\.recordID)).count == delegations.count
        else {
            throw LiveVoiceContinuityError.invalidCheckpoint
        }
        self.version = Self.schemaVersion
        self.userID = userID
        self.productSessionID = productSessionID
        self.finalTranscript = finalTranscript
        self.delegations = delegations
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case userID = "user_id"
        case productSessionID = "product_session_id"
        case finalTranscript = "final_transcript"
        case delegations
        case updatedAt = "updated_at"
    }
}

/// Provider-neutral data inserted into a newly authenticated live session.
/// It contains no executable action request and no provider function-call ID.
public struct LiveVoiceContinuationContext: Codable, Hashable, Sendable {
    public struct Delegation: Codable, Hashable, Sendable {
        public let recordID: String
        public let status: String
        public let deliveryState: PersistedVoiceDelegationState
        public let shouldAnnounce: Bool
        public let taskSummary: String
        public let spokenSummary: String?
        public let runID: String?

        public init(
            recordID: String,
            status: String,
            deliveryState: PersistedVoiceDelegationState,
            shouldAnnounce: Bool,
            taskSummary: String,
            spokenSummary: String?,
            runID: String?
        ) {
            self.recordID = recordID
            self.status = status
            self.deliveryState = deliveryState
            self.shouldAnnounce = shouldAnnounce
            self.taskSummary = taskSummary
            self.spokenSummary = spokenSummary
            self.runID = runID
        }

        enum CodingKeys: String, CodingKey {
            case recordID = "record_id"
            case status
            case deliveryState = "delivery_state"
            case shouldAnnounce = "should_announce"
            case taskSummary = "task_summary"
            case spokenSummary = "spoken_summary"
            case runID = "run_id"
        }
    }

    public let productSessionID: ProductSessionID
    public let transcriptSummary: String
    public let delegations: [Delegation]

    public init(
        productSessionID: ProductSessionID,
        transcriptSummary: String,
        delegations: [Delegation]
    ) {
        self.productSessionID = productSessionID
        self.transcriptSummary = transcriptSummary
        self.delegations = delegations
    }

    enum CodingKeys: String, CodingKey {
        case productSessionID = "product_session_id"
        case transcriptSummary = "transcript_summary"
        case delegations
    }

    public var isEmpty: Bool {
        transcriptSummary.isEmpty && delegations.isEmpty
    }
}

public protocol LiveVoiceCheckpointPersisting: Sendable {
    func loadCheckpoint(
        userID: UserID,
        productSessionID: ProductSessionID
    ) async throws -> LiveVoiceContinuityCheckpoint?
    func saveCheckpoint(_ checkpoint: LiveVoiceContinuityCheckpoint) async throws
}

/// Stores a bounded JSON checkpoint in the existing transactional local
/// settings store. The content-addressed key prevents raw account/session IDs
/// from becoming SQLite keys; decoded identity is still verified on every load.
public struct SettingsLiveVoiceCheckpointStore: LiveVoiceCheckpointPersisting {
    private let settings: any SettingsPersisting

    public init(settings: any SettingsPersisting) {
        self.settings = settings
    }

    /// Production convenience. Trusted runtime composition should use this
    /// initializer so continuity cannot silently fall back to volatile storage.
    public init(database: LocalDatabase) {
        self.settings = database.settingsStore
    }

    public func loadCheckpoint(
        userID: UserID,
        productSessionID: ProductSessionID
    ) async throws -> LiveVoiceContinuityCheckpoint? {
        let key = Self.storageKey(userID: userID, productSessionID: productSessionID)
        guard let data = try await settings.data(forKey: key) else { return nil }
        guard !data.isEmpty, data.count <= LiveVoiceContinuityLimits.maximumEncodedCheckpointBytes else {
            throw LiveVoiceContinuityError.invalidCheckpoint
        }
        let checkpoint = try JSONDecoder().decode(LiveVoiceContinuityCheckpoint.self, from: data)
        guard checkpoint.version == LiveVoiceContinuityCheckpoint.schemaVersion,
              checkpoint.userID == userID,
              checkpoint.productSessionID == productSessionID,
              checkpoint.finalTranscript.count <= LiveVoiceContinuityLimits.maximumFinalTranscriptSegments,
              checkpoint.finalTranscript.allSatisfy({
                  $0.isFinal
                    && !$0.text.isEmpty
                    && $0.text.utf8.count <= LiveVoiceContinuityLimits.maximumTranscriptSegmentBytes
              }),
              checkpoint.delegations.count <= LiveVoiceContinuityLimits.maximumDelegationRecords,
              checkpoint.delegations.allSatisfy({ $0.isValid }),
              Set(checkpoint.delegations.map(\.recordID)).count == checkpoint.delegations.count
        else {
            throw LiveVoiceContinuityError.invalidCheckpoint
        }
        return checkpoint
    }

    public func saveCheckpoint(_ checkpoint: LiveVoiceContinuityCheckpoint) async throws {
        guard checkpoint.version == LiveVoiceContinuityCheckpoint.schemaVersion else {
            throw LiveVoiceContinuityError.invalidCheckpoint
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(checkpoint)
        guard data.count <= LiveVoiceContinuityLimits.maximumEncodedCheckpointBytes else {
            throw LiveVoiceContinuityError.checkpointTooLarge
        }
        try await settings.saveData(
            data,
            forKey: Self.storageKey(
                userID: checkpoint.userID,
                productSessionID: checkpoint.productSessionID
            )
        )
    }

    private static func storageKey(userID: UserID, productSessionID: ProductSessionID) -> String {
        let material = Data("\(userID.rawValue)\u{0}\(productSessionID.rawValue)".utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return "live_voice_checkpoint_v1_\(digest)"
    }
}

public enum LiveVoiceContinuityError: Error, Sendable, Equatable {
    case invalidCheckpoint
    case checkpointTooLarge
    case invalidDelegationRecord
    case persistenceRequired
}

enum LiveVoiceContinuityLimits {
    static let maximumFinalTranscriptSegments = 24
    static let maximumDelegationRecords = 16
    static let maximumEncodedCheckpointBytes = 512 * 1_024
    static let maximumTranscriptSegmentBytes = 2_048
    static let maximumTranscriptSummaryBytes = 16 * 1_024
    static let maximumTaskSummaryBytes = 1_024
    static let maximumSpokenSummaryBytes = 2_048

    static func bounded(_ value: String, maximumUTF8Bytes: Int) -> String {
        let normalized = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard normalized.utf8.count > maximumUTF8Bytes else { return normalized }
        // Four bytes per Swift Character is not a universal upper bound for an
        // extended grapheme cluster. Iterative removal is used only on the
        // already-small checkpoint boundary and never on the media hot path.
        var bounded = String(normalized.prefix(maximumUTF8Bytes))
        while bounded.utf8.count > maximumUTF8Bytes, !bounded.isEmpty {
            bounded.removeLast()
        }
        return bounded
    }
}
