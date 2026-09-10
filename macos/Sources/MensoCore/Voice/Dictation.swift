import Foundation

public struct DictationAudioFrame: Sendable, Hashable {
    public let pcmData: Data
    public let sampleRate: Int
    public let channelCount: Int
    public let presentationTimeNanoseconds: UInt64

    public init(
        pcmData: Data,
        sampleRate: Int,
        channelCount: Int,
        presentationTimeNanoseconds: UInt64
    ) throws {
        guard !pcmData.isEmpty, sampleRate > 0, (1...2).contains(channelCount) else {
            throw DictationError.invalidAudioFrame
        }
        self.pcmData = pcmData
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
    }
}

public typealias DictationAudioStream = AsyncThrowingStream<DictationAudioFrame, Error>

public protocol DictationAudioCapturing: Sendable {
    func startCapture() async throws -> DictationAudioStream
    func stopCapture() async
}

public enum DictationEngineKind: String, Codable, Hashable, Sendable {
    case localParakeet = "local_parakeet"
    case appleSpeech = "apple_speech"
    case cloudOptIn = "cloud_opt_in"
}

public struct DictationTranscriptionConfiguration: Sendable, Hashable {
    public let localeIdentifier: String
    public let addsPunctuation: Bool

    public init(localeIdentifier: String, addsPunctuation: Bool = true) {
        self.localeIdentifier = localeIdentifier
        self.addsPunctuation = addsPunctuation
    }
}

public enum DictationTranscriptionEvent: Sendable, Hashable {
    case partial(text: String, isVolatile: Bool)
    case final(text: String)
    case endOfUtterance
}

public typealias DictationTranscriptionStream = AsyncThrowingStream<DictationTranscriptionEvent, Error>

public protocol DictationTranscribing: Sendable {
    var kind: DictationEngineKind { get }
    func prepare(configuration: DictationTranscriptionConfiguration) async throws
    func transcribe(audio: DictationAudioStream) async throws -> DictationTranscriptionStream
    func cancel() async
}

public enum DictationIntent: Sendable, Hashable {
    case insertText
    case command
}

public struct CompletedDictation: Sendable, Hashable {
    public let text: String
    public let intent: DictationIntent

    public init(text: String, intent: DictationIntent) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictationError.emptyTranscription
        }
        self.text = text
        self.intent = intent
    }
}

public protocol DictationCommandDelegating: Sendable {
    func delegateCommand(
        _ dictation: CompletedDictation,
        userID: UserID,
        sessionID: ProductSessionID
    ) async throws -> VoiceDelegationResult
}

public struct DictationActionRequestFactory: Sendable {
    public init() {}

    public func insertionRequest(
        text: String,
        target: FocusedApplicationTarget,
        userID: UserID,
        sessionID: ProductSessionID,
        expiresAt: Date,
        nonce: UUID = UUID(),
        now: Date = Date()
    ) throws -> ActionRequest {
        guard !text.isEmpty, expiresAt > now else { throw DictationError.invalidInsertionRequest }
        let hash = ContentHash.sha256(of: text)
        return ActionRequest(
            actionID: ActionID(),
            idempotencyKey: IdempotencyKey(
                rawValue: "dictation:\(sessionID.rawValue):\(hash.rawValue):\(nonce.uuidString.lowercased())"
            ),
            userID: userID,
            sessionID: sessionID,
            source: .dictation,
            target: .focusedApplication(target),
            operation: .insertDictationText(DictationInsertionOperation(text: text, contentHash: hash)),
            capability: ActionCapabilityBinding(expectedToolName: "insert_dictation_text"),
            createdAt: now,
            expiresAt: expiresAt
        )
    }
}

public enum DictationError: Error, Sendable, Equatable {
    case invalidAudioFrame
    case emptyTranscription
    case invalidInsertionRequest
}

/// Safe composition default when no reviewed STT package/model assets are
/// present. It never uploads audio or silently selects a cloud provider.
public actor UnavailableDictationTranscriber: DictationTranscribing {
    public nonisolated let kind: DictationEngineKind

    public init(kind: DictationEngineKind = .localParakeet) {
        self.kind = kind
    }

    public func prepare(configuration: DictationTranscriptionConfiguration) async throws {
        throw UnavailableDictationTranscriberError.modelNotConfigured
    }

    public func transcribe(audio: DictationAudioStream) async throws -> DictationTranscriptionStream {
        throw UnavailableDictationTranscriberError.modelNotConfigured
    }

    public func cancel() async {}
}

public enum UnavailableDictationTranscriberError: Error, Sendable, Equatable {
    case modelNotConfigured
}
