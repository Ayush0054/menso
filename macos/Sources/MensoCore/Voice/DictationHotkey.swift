import Carbon.HIToolbox
import Foundation

public struct DictationHotkey: Sendable, Hashable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Control-Option-Space avoids the system Command-Space binding while
    /// remaining permission-free through Carbon RegisterEventHotKey.
    public static let standard = DictationHotkey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey)
    )
}

public protocol DictationHotkeyRegistering: AnyObject {
    @MainActor
    func register(
        hotkey: DictationHotkey,
        handler: @escaping @MainActor () -> Void
    ) throws

    @MainActor
    func unregister()
}

public enum DictationHotkeyRegistrationError: Error, Sendable, Equatable {
    case eventHandler(OSStatus)
    case hotkey(OSStatus)
}

/// Global hotkey registration without NSEvent event taps or Input Monitoring.
@MainActor
public final class CarbonDictationHotkeyRegistrar: DictationHotkeyRegistering {
    private static let signature: OSType = 0x4D4E5344 // "MNSD"
    private static let hotkeyID: UInt32 = 1

    private var eventHandler: EventHandlerRef?
    private var hotkeyReference: EventHotKeyRef?
    private var handler: (@MainActor () -> Void)?

    public init() {}

    isolated deinit {
        unregister()
    }

    public func register(
        hotkey: DictationHotkey = .standard,
        handler: @escaping @MainActor () -> Void
    ) throws {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let registrar = Unmanaged<CarbonDictationHotkeyRegistrar>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr else { return status }
                guard identifier.signature == CarbonDictationHotkeyRegistrar.signature,
                      identifier.id == CarbonDictationHotkeyRegistrar.hotkeyID
                else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in
                    registrar.handler?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            unregister()
            throw DictationHotkeyRegistrationError.eventHandler(handlerStatus)
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: Self.hotkeyID)
        let hotkeyStatus = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotkeyReference
        )
        guard hotkeyStatus == noErr else {
            unregister()
            throw DictationHotkeyRegistrationError.hotkey(hotkeyStatus)
        }
    }

    public func unregister() {
        if let hotkeyReference {
            UnregisterEventHotKey(hotkeyReference)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotkeyReference = nil
        eventHandler = nil
        handler = nil
    }
}
