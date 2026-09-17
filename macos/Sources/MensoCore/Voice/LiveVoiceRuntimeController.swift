import Foundation

/// Small signed-app composition adapter. Authentication, identity, delegation,
/// and durable checkpoint dependencies are all required by the coordinator's
/// initializer; this controller supplies only the user-selected media defaults.
public actor ConfiguredLiveVoiceRuntimeController: LiveVoiceRuntimeControlling {
    private let coordinator: LiveVoiceCoordinator
    private let inputFormat: LiveVoiceAudioFormat
    private let configuredVoiceProcessingFallback: Bool
    private var desiredActive = false

    public init(
        coordinator: LiveVoiceCoordinator,
        inputFormat: LiveVoiceAudioFormat,
        configuredVoiceProcessingFallback: Bool = true
    ) {
        self.coordinator = coordinator
        self.inputFormat = inputFormat
        self.configuredVoiceProcessingFallback = configuredVoiceProcessingFallback
    }

    public func toggle() async throws {
        let current = await coordinator.currentState()
        if desiredActive && current != .failed && current != .disconnected {
            desiredActive = false
            await coordinator.stop()
            return
        }

        desiredActive = true
        do {
            try await coordinator.start(
                inputFormat: inputFormat,
                voiceProcessingEnabled: configuredVoiceProcessingFallback
            )
        } catch {
            desiredActive = false
            throw error
        }
    }

    public func stop() async {
        desiredActive = false
        await coordinator.stop()
    }

    public func state() async -> LiveVoiceSessionState {
        await coordinator.currentState()
    }

    public func updates() async -> AsyncStream<LiveVoiceUpdate> {
        await coordinator.updates()
    }
}
