import Carbon.HIToolbox
import Foundation

public protocol ApprovalHotkeyRegistering: AnyObject {
    @MainActor
    func register(
        approve: @escaping @MainActor () -> Void,
        deny: @escaping @MainActor () -> Void
    ) throws

    @MainActor
    func unregister()
}

public enum ApprovalHotkeyRegistrationError: Error, Sendable {
    case eventHandler(OSStatus)
    case approveHotkey(OSStatus)
    case denyHotkey(OSStatus)
}

/// Permission-free Carbon hotkeys; this deliberately avoids event taps and
/// therefore never requests Input Monitoring.
@MainActor
public final class CarbonApprovalHotkeyRegistrar: ApprovalHotkeyRegistering {
    private static let signature: OSType = 0x4D4E534F // "MNSO"
    private static let approveID: UInt32 = 1
    private static let denyID: UInt32 = 2

    private var eventHandler: EventHandlerRef?
    private var approveReference: EventHotKeyRef?
    private var denyReference: EventHotKeyRef?
    private var approveHandler: (@MainActor () -> Void)?
    private var denyHandler: (@MainActor () -> Void)?

    public init() {}

    isolated deinit {
        unregister()
    }

    public func register(
        approve: @escaping @MainActor () -> Void,
        deny: @escaping @MainActor () -> Void
    ) throws {
        unregister()
        approveHandler = approve
        denyHandler = deny

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let registrar = Unmanaged<CarbonApprovalHotkeyRegistrar>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                var hotkeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                guard status == noErr else { return status }
                guard hotkeyID.signature == CarbonApprovalHotkeyRegistrar.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                Task { @MainActor in
                    switch hotkeyID.id {
                    case CarbonApprovalHotkeyRegistrar.approveID: registrar.approveHandler?()
                    case CarbonApprovalHotkeyRegistrar.denyID: registrar.denyHandler?()
                    default: break
                    }
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
            throw ApprovalHotkeyRegistrationError.eventHandler(handlerStatus)
        }

        let modifiers = UInt32(controlKey | optionKey)
        let approveID = EventHotKeyID(signature: Self.signature, id: Self.approveID)
        let approveStatus = RegisterEventHotKey(
            UInt32(kVK_Return),
            modifiers,
            approveID,
            GetApplicationEventTarget(),
            0,
            &approveReference
        )
        guard approveStatus == noErr else {
            unregister()
            throw ApprovalHotkeyRegistrationError.approveHotkey(approveStatus)
        }

        let denyID = EventHotKeyID(signature: Self.signature, id: Self.denyID)
        let denyStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            modifiers,
            denyID,
            GetApplicationEventTarget(),
            0,
            &denyReference
        )
        guard denyStatus == noErr else {
            unregister()
            throw ApprovalHotkeyRegistrationError.denyHotkey(denyStatus)
        }
    }

    public func unregister() {
        if let approveReference { UnregisterEventHotKey(approveReference) }
        if let denyReference { UnregisterEventHotKey(denyReference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        approveReference = nil
        denyReference = nil
        eventHandler = nil
        approveHandler = nil
        denyHandler = nil
    }
}
