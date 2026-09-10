@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

public enum AppleOnDeviceDictationError: Error, Sendable, Equatable {
    case permissionRequired
    case localeUnavailable
    case onDeviceRecognitionUnavailable
    case invalidAudioFormat
    case recognitionFailed
    case alreadyRunning
}

/// Concrete local-only speech adapter. `requiresOnDeviceRecognition` is always
/// true; it never silently falls back to Apple's server transcription.
public actor AppleOnDeviceDictationTranscriber: DictationTranscribing {
    public nonisolated let kind: DictationEngineKind = .appleSpeech

    private var recognizer: SFSpeechRecognizer?
    private var configuration: DictationTranscriptionConfiguration?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFeedTask: Task<Void, Never>?

    public init() {}

    public func prepare(
        configuration: DictationTranscriptionConfiguration
    ) async throws {
        guard MacOSApplicationBundle.isCurrentProcess,
              SFSpeechRecognizer.authorizationStatus() == .authorized
        else {
            throw AppleOnDeviceDictationError.permissionRequired
        }
        guard let recognizer = SFSpeechRecognizer(
            locale: Locale(identifier: configuration.localeIdentifier)
        ), recognizer.isAvailable else {
            throw AppleOnDeviceDictationError.localeUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AppleOnDeviceDictationError.onDeviceRecognitionUnavailable
        }
        self.recognizer = recognizer
        self.configuration = configuration
    }

    public func transcribe(
        audio: DictationAudioStream
    ) async throws -> DictationTranscriptionStream {
        guard recognitionTask == nil, audioFeedTask == nil else {
            throw AppleOnDeviceDictationError.alreadyRunning
        }
        guard let recognizer, let configuration else {
            throw AppleOnDeviceDictationError.localeUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = configuration.addsPunctuation

        let pair = DictationTranscriptionStream.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        let continuation = pair.continuation
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    continuation.yield(.final(text: text))
                    continuation.yield(.endOfUtterance)
                    continuation.finish()
                } else {
                    continuation.yield(.partial(text: text, isVolatile: true))
                }
            } else if error != nil {
                continuation.finish(throwing: AppleOnDeviceDictationError.recognitionFailed)
            }
        }

        let feed = AppleSpeechAudioFeed(request: request, continuation: continuation)
        audioFeedTask = Task { [weak self, feed] in
            await feed.run(audio: audio)
            await self?.feedFinished()
        }
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel() }
        }
        return pair.stream
    }

    public func cancel() async {
        audioFeedTask?.cancel()
        audioFeedTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func feedFinished() {
        audioFeedTask = nil
        if recognitionTask?.state == .completed
            || recognitionTask?.state == .canceling
        {
            recognitionTask = nil
        }
    }

    fileprivate static func buffer(from frame: DictationAudioFrame) throws -> AVAudioPCMBuffer {
        guard frame.sampleRate == AVAudioEngineDictationCapture.outputSampleRate,
              frame.channelCount == 1,
              frame.pcmData.count.isMultiple(of: MemoryLayout<Float>.size),
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(frame.sampleRate),
                  channels: 1,
                  interleaved: false
              )
        else { throw AppleOnDeviceDictationError.invalidAudioFormat }
        let frames = frame.pcmData.count / MemoryLayout<Float>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frames)
              ),
              let destination = buffer.floatChannelData?[0]
        else { throw AppleOnDeviceDictationError.invalidAudioFormat }
        frame.pcmData.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            memcpy(destination, base, frame.pcmData.count)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}

private final class AppleSpeechAudioFeed: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let continuation: DictationTranscriptionStream.Continuation

    init(
        request: SFSpeechAudioBufferRecognitionRequest,
        continuation: DictationTranscriptionStream.Continuation
    ) {
        self.request = request
        self.continuation = continuation
    }

    func run(audio: DictationAudioStream) async {
        do {
            for try await frame in audio {
                try Task.checkCancellation()
                let buffer = try AppleOnDeviceDictationTranscriber.buffer(from: frame)
                request.append(buffer)
            }
            request.endAudio()
        } catch is CancellationError {
            request.endAudio()
        } catch {
            request.endAudio()
            continuation.finish(throwing: error)
        }
    }
}
