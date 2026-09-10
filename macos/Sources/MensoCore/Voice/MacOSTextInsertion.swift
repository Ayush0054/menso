import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Narrow transport used by dictation. It cannot click, navigate, capture the
/// screen, send a message, or execute an arbitrary key sequence.
public protocol VerifiedTextInsertionTransport: Sendable {
    func insertText(_ request: CUATextInsertionRequest) async throws -> CUATextInsertionReceipt
}

/// Semantic broker for a dictation-only ActionExecutor composition. Request and
/// receipt bindings are checked on both sides of the platform side effect.
public actor MacOSTextInsertionBroker: SemanticActionBroker {
    private let transport: any VerifiedTextInsertionTransport

    public init(transport: any VerifiedTextInsertionTransport) {
        self.transport = transport
    }

    public func execute(_ request: ActionRequest) async throws -> ActionResult {
        guard request.isStructurallyValid else {
            throw LocalToolBrokerError.unsupportedOperation
        }
        guard case let .focusedApplication(target) = request.target,
              case let .insertDictationText(operation) = request.operation
        else {
            throw LocalToolBrokerError.targetMismatch
        }

        let receipt: CUATextInsertionReceipt
        do {
            receipt = try await transport.insertText(
                CUATextInsertionRequest(
                    actionID: request.actionID,
                    target: target,
                    text: operation.text,
                    contentHash: operation.contentHash
                )
            )
        } catch let error as MacOSTextInsertionError {
            switch error {
            case .targetNotFocused:
                throw LocalToolBrokerError.targetMismatch
            case .contentMismatch:
                throw LocalToolBrokerError.contentMismatch
            case .secureInputActive, .eventCreationFailed, .eventPostCouldNotBeVerified:
                throw LocalToolBrokerError.verificationFailed
            case .clipboardUnavailable:
                throw LocalToolBrokerError.driverUnavailable
            }
        } catch {
            throw LocalToolBrokerError.driverUnavailable
        }

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

/// Main-actor isolation keeps pasteboard and frontmost-application snapshots
/// ordered. ActionExecutor provides the serialized, audited outer boundary.
@MainActor
public final class ClipboardSwapTextInsertionTransport: VerifiedTextInsertionTransport {
    public static let transientPasteboardType = NSPasteboard.PasteboardType(
        "org.nspasteboard.TransientType"
    )

    private let restoreDelayNanoseconds: UInt64
    private let secureInput: any SecureInputStateProviding

    public init(
        restoreDelayNanoseconds: UInt64 = 300_000_000,
        secureInput: any SecureInputStateProviding = MacOSSecureInputStateProvider()
    ) {
        self.restoreDelayNanoseconds = max(300_000_000, restoreDelayNanoseconds)
        self.secureInput = secureInput
    }

    public func insertText(_ request: CUATextInsertionRequest) async throws -> CUATextInsertionReceipt {
        guard request.contentHash == .sha256(of: request.text) else {
            throw MacOSTextInsertionError.contentMismatch
        }
        guard targetIsFrontmost(request.target) else {
            throw MacOSTextInsertionError.targetNotFocused
        }
        guard await secureInput.currentSecureInputState() == .disabled else {
            throw MacOSTextInsertionError.secureInputActive
        }
        guard targetIsFrontmost(request.target) else {
            throw MacOSTextInsertionError.targetNotFocused
        }

        let method: InsertionMethod
        do {
            try await insertWithClipboardSwap(request.text)
            method = .clipboardSwap
        } catch let error as MacOSTextInsertionError {
            switch error {
            case .clipboardUnavailable, .eventCreationFailed:
                guard targetIsFrontmost(request.target) else {
                    throw MacOSTextInsertionError.targetNotFocused
                }
                try insertWithUnicodeEvents(request.text)
                method = .unicodeEvents
            default:
                throw error
            }
        }

        // Posting an event has no success callback, so stable focus proves only
        // delivery intent—not insertion. Never promote that to a verified action
        // receipt. A future adapter may succeed only after comparing an AX text
        // value/selection (or another app-specific observable) before and after.
        guard targetIsFrontmost(request.target) else {
            throw MacOSTextInsertionError.eventPostCouldNotBeVerified
        }
        _ = method
        throw MacOSTextInsertionError.eventPostCouldNotBeVerified
    }

    private func insertWithClipboardSwap(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        let transientItem = NSPasteboardItem()
        guard transientItem.setString(text, forType: .string),
              transientItem.setData(Data(), forType: Self.transientPasteboardType),
              pasteboard.writeObjects([transientItem])
        else {
            snapshot.restore(to: pasteboard)
            throw MacOSTextInsertionError.clipboardUnavailable
        }
        let insertedChangeCount = pasteboard.changeCount

        do {
            try await Task.sleep(nanoseconds: 10_000_000)
        } catch {
            if pasteboard.changeCount == insertedChangeCount {
                snapshot.restore(to: pasteboard)
            }
            throw MacOSTextInsertionError.eventPostCouldNotBeVerified
        }
        do {
            try postCommandV()
        } catch {
            if pasteboard.changeCount == insertedChangeCount {
                snapshot.restore(to: pasteboard)
            }
            throw error
        }

        do {
            try await Task.sleep(nanoseconds: restoreDelayNanoseconds)
        } catch {
            if pasteboard.changeCount == insertedChangeCount {
                snapshot.restore(to: pasteboard)
            }
            throw MacOSTextInsertionError.eventPostCouldNotBeVerified
        }

        // Do not overwrite a clipboard value the user or target application
        // deliberately wrote during Chromium's asynchronous paste window.
        if pasteboard.changeCount == insertedChangeCount {
            snapshot.restore(to: pasteboard)
        }
    }

    private func postCommandV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: false
              )
        else {
            throw MacOSTextInsertionError.eventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func insertWithUnicodeEvents(_ text: String) throws {
        let units = Array(text.utf16)
        guard !units.isEmpty, let source = CGEventSource(stateID: .combinedSessionState) else {
            throw MacOSTextInsertionError.eventCreationFailed
        }
        source.localEventsSuppressionInterval = 0

        var offset = 0
        while offset < units.count {
            var count = min(20, units.count - offset)
            if offset + count < units.count,
               Self.isHighSurrogate(units[offset + count - 1]),
               Self.isLowSurrogate(units[offset + count])
            {
                count -= 1
            }
            guard count > 0 else {
                throw MacOSTextInsertionError.eventCreationFailed
            }

            let chunk = Array(units[offset..<(offset + count)])
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ), let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) else {
                throw MacOSTextInsertionError.eventCreationFailed
            }
            chunk.withUnsafeBufferPointer { pointer in
                guard let address = pointer.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(
                    stringLength: pointer.count,
                    unicodeString: address
                )
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            offset += count
        }
    }

    private func targetIsFrontmost(_ target: FocusedApplicationTarget) -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier == target.bundleIdentifier
        else {
            return false
        }
        return target.processIdentifier.map { application.processIdentifier == $0 } ?? true
    }

    private static func isHighSurrogate(_ unit: UInt16) -> Bool {
        (0xD800...0xDBFF).contains(unit)
    }

    private static func isLowSurrogate(_ unit: UInt16) -> Bool {
        (0xDC00...0xDFFF).contains(unit)
    }
}

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    @MainActor
    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restoredItems = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        _ = pasteboard.writeObjects(restoredItems)
    }
}

private enum InsertionMethod: String {
    case clipboardSwap = "clipboard-swap"
    case unicodeEvents = "unicode-events"
}

public enum MacOSTextInsertionError: Error, Sendable, Equatable {
    case targetNotFocused
    case contentMismatch
    case secureInputActive
    case clipboardUnavailable
    case eventCreationFailed
    case eventPostCouldNotBeVerified
}
