import AppKit
import ApplicationServices
import Foundation

public enum TrustedSemanticTargetError: Error, Sendable, Equatable {
    case unavailable
    case ambiguousElement
}

/// Reads the current frontmost application, focused window, and focused AX
/// element without activating Menso. This snapshot is user-owned authority;
/// model output can only echo and match it later.
@MainActor
public final class MacOSTrustedSemanticTargetProvider {
    private let excludedBundleIdentifiers: Set<String>

    public init(excludedBundleIdentifiers: Set<String> = []) {
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    public func focusedTarget() throws -> FocusedApplicationTarget {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              !excludedBundleIdentifiers.contains(bundleIdentifier)
        else { throw TrustedSemanticTargetError.unavailable }

        let app = AXUIElementCreateApplication(application.processIdentifier)
        let window = Self.element(app, kAXFocusedWindowAttribute as CFString)
        let focused = Self.element(app, kAXFocusedUIElementAttribute as CFString)
        return FocusedApplicationTarget(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: application.processIdentifier,
            windowTitle: window.flatMap {
                Self.string($0, kAXTitleAttribute as CFString)
            },
            elementRole: focused.flatMap {
                Self.string($0, kAXRoleAttribute as CFString)
            },
            elementLabel: focused.flatMap {
                Self.firstString(
                    $0,
                    [
                        kAXTitleAttribute as CFString,
                        kAXDescriptionAttribute as CFString,
                        kAXPlaceholderValueAttribute as CFString,
                        kAXIdentifierAttribute as CFString,
                    ]
                )
            }
        )
    }

    private static func element(_ source: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func string(_ source: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute, &value) == .success,
              let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return string
    }

    private static func firstString(
        _ source: AXUIElement,
        _ attributes: [CFString]
    ) -> String? {
        attributes.lazy.compactMap { string(source, $0) }.first
    }
}
