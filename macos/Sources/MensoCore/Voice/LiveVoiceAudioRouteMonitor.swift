import AVFoundation
import CoreAudio
import Foundation

public struct LiveVoiceDeviceAudioFormat: Codable, Hashable, Sendable {
    public let sampleRate: Double
    public let channelCount: UInt32

    public init?(format: AVAudioFormat) {
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        self.sampleRate = format.sampleRate
        self.channelCount = format.channelCount
    }

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channelCount = "channel_count"
    }
}

public enum LiveVoiceMeterAvailability: String, Codable, Hashable, Sendable {
    /// The maintained native WebRTC binary owns its audio device module and does
    /// not expose supported raw microphone/output sample callbacks. Starting a
    /// second AVAudioEngine capture solely for a meter can degrade AEC, so this
    /// runtime reports the limitation instead of double-capturing.
    case unavailableWithNativeWebRTC = "unavailable_with_native_webrtc"
}

public enum LiveVoiceProcessingRecommendation: String, Codable, Hashable, Sendable {
    case enableForSpeakerRoute = "enable_for_speaker_route"
    case disableForHeadphoneRoute = "disable_for_headphone_route"
    /// CoreAudio did not expose enough stable information to classify the
    /// current output. The caller's explicit fallback remains authoritative.
    case useConfiguredFallback = "use_configured_fallback"

    public var enabled: Bool? {
        switch self {
        case .enableForSpeakerRoute: true
        case .disableForHeadphoneRoute: false
        case .useConfiguredFallback: nil
        }
    }
}

public struct LiveVoiceAudioRouteSnapshot: Codable, Hashable, Sendable {
    public let inputFormat: LiveVoiceDeviceAudioFormat?
    public let outputFormat: LiveVoiceDeviceAudioFormat?
    public let meterAvailability: LiveVoiceMeterAvailability
    public let voiceProcessingRecommendation: LiveVoiceProcessingRecommendation
    public let observedAt: Date

    public init(
        inputFormat: LiveVoiceDeviceAudioFormat?,
        outputFormat: LiveVoiceDeviceAudioFormat?,
        meterAvailability: LiveVoiceMeterAvailability,
        voiceProcessingRecommendation: LiveVoiceProcessingRecommendation,
        observedAt: Date
    ) {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.meterAvailability = meterAvailability
        self.voiceProcessingRecommendation = voiceProcessingRecommendation
        self.observedAt = observedAt
    }

    enum CodingKeys: String, CodingKey {
        case inputFormat = "input_format"
        case outputFormat = "output_format"
        case meterAvailability = "meter_availability"
        case voiceProcessingRecommendation = "voice_processing_recommendation"
        case observedAt = "observed_at"
    }
}

/// AVAudioEngine is retained as the app-owned route/configuration observation
/// boundary while libwebrtc owns the actual full-duplex media graph. The monitor
/// can be refreshed when the app foregrounds and also reacts to engine
/// configuration-change notifications.
public actor AVAudioEngineLiveVoiceRouteMonitor {
    private let now: @Sendable () -> Date
    private var observer: LiveVoiceConfigurationObserver?
    private var latest: LiveVoiceAudioRouteSnapshot?
    private var continuations: [UUID: AsyncStream<LiveVoiceAudioRouteSnapshot>.Continuation] = [:]

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func updates(bufferLimit: Int = 8) -> AsyncStream<LiveVoiceAudioRouteSnapshot> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: LiveVoiceAudioRouteSnapshot.self,
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
        )
        continuations[id] = pair.continuation
        if let latest {
            pair.continuation.yield(latest)
        }
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return pair.stream
    }

    @discardableResult
    public func start() async -> LiveVoiceAudioRouteSnapshot {
        if observer == nil {
            let token = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.refresh() }
            }
            observer = LiveVoiceConfigurationObserver(token: token)
        }
        return await refresh()
    }

    @discardableResult
    public func refresh() async -> LiveVoiceAudioRouteSnapshot {
        let observedAt = now()
        let snapshot = await MainActor.run {
            let engine = AVAudioEngine()
            return LiveVoiceAudioRouteSnapshot(
                inputFormat: LiveVoiceDeviceAudioFormat(format: engine.inputNode.inputFormat(forBus: 0)),
                outputFormat: LiveVoiceDeviceAudioFormat(format: engine.outputNode.outputFormat(forBus: 0)),
                meterAvailability: .unavailableWithNativeWebRTC,
                voiceProcessingRecommendation: LiveVoiceOutputRouteClassifier.recommendation(),
                observedAt: observedAt
            )
        }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
        return snapshot
    }

    public func stop() {
        observer?.cancel()
        observer = nil
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

/// Reads only the default output device's non-sensitive CoreAudio metadata.
/// Unknown USB/aggregate/virtual routes deliberately fall back to an explicit
/// caller choice instead of guessing and degrading the full-duplex graph.
private enum LiveVoiceOutputRouteClassifier {
    static func recommendation() -> LiveVoiceProcessingRecommendation {
        guard let deviceID = defaultOutputDevice(),
              deviceID != AudioDeviceID(kAudioObjectUnknown)
        else { return .useConfiguredFallback }

        let name = stringProperty(
            objectID: deviceID,
            selector: kAudioObjectPropertyName
        )?.lowercased() ?? ""
        if ["headphone", "headset", "earbud", "airpod"].contains(where: { name.contains($0) }) {
            return .disableForHeadphoneRoute
        }
        if ["speaker", "display", "television", "soundbar"].contains(where: { name.contains($0) }) {
            return .enableForSpeakerRoute
        }

        guard let transport = uint32Property(
            objectID: deviceID,
            selector: kAudioDevicePropertyTransportType
        ) else { return .useConfiguredFallback }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .disableForHeadphoneRoute
        case kAudioDeviceTransportTypeBuiltIn,
             kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeAirPlay:
            return .enableForSpeakerRoute
        default:
            return .useConfiguredFallback
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func uint32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }
}

private final class LiveVoiceConfigurationObserver: @unchecked Sendable {
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
