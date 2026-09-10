@preconcurrency import AVFoundation
import Foundation

/// App-owned microphone capture for local dictation. The emitted payload is
/// non-interleaved Float32 PCM at 16 kHz mono.
public actor AVAudioEngineDictationCapture: DictationAudioCapturing {
    public static let outputSampleRate = 16_000

    private var engine: AVAudioEngine?
    private var streamContinuation: DictationAudioStream.Continuation?
    private var configurationObserver: DictationConfigurationObserver?
    private var captureGeneration: UInt64 = 0
    private var isRebuilding = false
    private var rebuildRequested = false
    private var tapInstalled = false

    public init() {}

    public func startCapture() async throws -> DictationAudioStream {
        guard streamContinuation == nil else {
            throw AVAudioDictationCaptureError.captureAlreadyRunning
        }
        guard MacOSApplicationBundle.isCurrentProcess,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        else {
            throw AVAudioDictationCaptureError.microphonePermissionRequired
        }

        var continuation: DictationAudioStream.Continuation?
        let stream = DictationAudioStream(bufferingPolicy: .bufferingNewest(96)) {
            continuation = $0
        }
        guard let continuation else {
            throw AVAudioDictationCaptureError.streamCreationFailed
        }

        captureGeneration &+= 1
        let generation = captureGeneration
        streamContinuation = continuation
        installConfigurationObserverIfNeeded()

        do {
            try installAndStartEngine(continuation: continuation, generation: generation)
            return stream
        } catch {
            tearDownEngine()
            streamContinuation = nil
            rebuildRequested = false
            continuation.finish(throwing: error)
            removeConfigurationObserver()
            throw error
        }
    }

    public func stopCapture() async {
        guard let continuation = streamContinuation else { return }
        streamContinuation = nil
        captureGeneration &+= 1
        rebuildRequested = false
        tearDownEngine()
        removeConfigurationObserver()
        continuation.finish()
    }

    private func installAndStartEngine(
        continuation: DictationAudioStream.Continuation,
        generation: UInt64
    ) throws {
        tapInstalled = false
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AVAudioDictationCaptureError.inputUnavailable
        }

        let converter = try DictationAudioFrameConverter(inputFormat: inputFormat)
        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: inputFormat
        ) { [weak self] buffer, time in
            do {
                if let frame = try converter.convert(buffer, time: time) {
                    continuation.yield(frame)
                }
            } catch {
                let captureError = error as? AVAudioDictationCaptureError ?? .conversionFailed
                continuation.finish(throwing: captureError)
                Task { [weak self] in
                    await self?.captureFailed(captureError, generation: generation)
                }
            }
        }
        tapInstalled = true

        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw AVAudioDictationCaptureError.engineStartFailed
        }
        engine = newEngine
    }

    private func installConfigurationObserverIfNeeded() {
        guard configurationObserver == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.rebuildForConfigurationChange()
            }
        }
        configurationObserver = DictationConfigurationObserver(token: token)
    }

    /// A configuration notification invalidates both the input format and its
    /// converter. Reusing either can silently emit audio with the wrong layout.
    private func rebuildForConfigurationChange() async {
        guard let continuation = streamContinuation else { return }
        if isRebuilding {
            rebuildRequested = true
            return
        }
        isRebuilding = true
        defer {
            isRebuilding = false
            if rebuildRequested {
                rebuildRequested = false
                Task { [weak self] in
                    await self?.rebuildForConfigurationChange()
                }
            }
        }

        captureGeneration &+= 1
        let generation = captureGeneration
        tearDownEngine()
        do {
            try installAndStartEngine(continuation: continuation, generation: generation)
        } catch {
            await captureFailed(
                error as? AVAudioDictationCaptureError ?? .engineStartFailed,
                generation: generation
            )
        }
    }

    private func captureFailed(_ error: AVAudioDictationCaptureError, generation: UInt64) async {
        guard generation == captureGeneration, let continuation = streamContinuation else { return }
        streamContinuation = nil
        captureGeneration &+= 1
        rebuildRequested = false
        tearDownEngine()
        removeConfigurationObserver()
        continuation.finish(throwing: error)
    }

    private func tearDownEngine() {
        guard let engine else {
            tapInstalled = false
            return
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
        self.engine = nil
    }

    private func removeConfigurationObserver() {
        configurationObserver?.cancel()
        configurationObserver = nil
    }
}

private final class DictationConfigurationObserver: @unchecked Sendable {
    private var token: NSObjectProtocol?

    init(token: NSObjectProtocol) {
        self.token = token
    }

    func cancel() {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        token = nil
    }

    deinit {
        cancel()
    }
}

private final class DictationAudioFrameConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputSampleRate: Double

    init(inputFormat: AVAudioFormat) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(AVAudioEngineDictationCapture.outputSampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AVAudioDictationCaptureError.converterUnavailable
        }
        self.converter = converter
        self.outputFormat = outputFormat
        self.inputSampleRate = inputFormat.sampleRate
    }

    func convert(_ input: AVAudioPCMBuffer, time: AVAudioTime) throws -> DictationAudioFrame? {
        let scaledFrames = ceil(
            Double(input.frameLength)
                * Double(AVAudioEngineDictationCapture.outputSampleRate)
                / inputSampleRate
        )
        let capacity = AVAudioFrameCount(max(1, Int(scaledFrames) + 8))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AVAudioDictationCaptureError.outputBufferUnavailable
        }

        let inputProvider = DictationAudioConverterInputProvider(input: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }
        if status == .error || conversionError != nil {
            throw AVAudioDictationCaptureError.conversionFailed
        }
        guard output.frameLength > 0, let samples = output.floatChannelData?[0] else {
            return nil
        }

        let byteCount = Int(output.frameLength) * MemoryLayout<Float>.size
        let presentationTime: UInt64
        if time.isHostTimeValid {
            presentationTime = UInt64(max(0, AVAudioTime.seconds(forHostTime: time.hostTime) * 1_000_000_000))
        } else {
            presentationTime = DispatchTime.now().uptimeNanoseconds
        }
        return try DictationAudioFrame(
            pcmData: Data(bytes: samples, count: byteCount),
            sampleRate: AVAudioEngineDictationCapture.outputSampleRate,
            channelCount: 1,
            presentationTimeNanoseconds: presentationTime
        )
    }
}

private final class DictationAudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var input: AVAudioPCMBuffer?

    init(input: AVAudioPCMBuffer) {
        self.input = input
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let input else {
            status.pointee = .noDataNow
            return nil
        }
        self.input = nil
        status.pointee = .haveData
        return input
    }
}

public enum AVAudioDictationCaptureError: Error, Sendable, Equatable {
    case captureAlreadyRunning
    case microphonePermissionRequired
    case inputUnavailable
    case converterUnavailable
    case outputBufferUnavailable
    case engineStartFailed
    case conversionFailed
    case streamCreationFailed
}
