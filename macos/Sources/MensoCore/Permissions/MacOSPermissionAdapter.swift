import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import Speech
import UserNotifications

/// Native permission adapter. It never probes or requests Input Monitoring or Full Disk Access.
public struct MacOSPermissionAdapter: PermissionStatusChecking, PermissionPrompting {
    public init() {}

    public func authorizationStatus(for permission: MensoPermission) async -> PermissionAuthorizationStatus {
        guard MacOSApplicationBundle.isCurrentProcess else {
            return .unavailable
        }
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .authorized : .denied
        case .microphone:
            return Self.mapCaptureStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .authorized, .provisional, .ephemeral: return .authorized
            @unknown default: return .unknown
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .authorized : .denied
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .restricted: return .restricted
            case .authorized: return .authorized
            @unknown default: return .unknown
            }
        case .automation:
            // Apple Events consent is target-specific and can only be determined by sending a scoped event.
            return .unknown
        case .inputMonitoring, .fullDiskAccess:
            return .unavailable
        }
    }

    public func settingsDeepLink(for permission: MensoPermission) async -> URL? {
        let pane: String
        switch permission {
        case .accessibility: pane = "Privacy_Accessibility"
        case .microphone: pane = "Privacy_Microphone"
        case .notifications: pane = "Notifications"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .speechRecognition: pane = "Privacy_SpeechRecognition"
        case .automation: pane = "Privacy_Automation"
        case .inputMonitoring, .fullDiskAccess: return nil
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    public func request(_ permission: MensoPermission) async throws -> PermissionAuthorizationStatus {
        guard MacOSApplicationBundle.isCurrentProcess else {
            throw MacOSPermissionAdapterError.unsupportedRequest
        }
        switch permission {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .authorized : .denied
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
        case .notifications:
            do {
                return try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound]) ? .authorized : .denied
            } catch {
                throw MacOSPermissionAdapterError.requestFailed
            }
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .authorized : .denied
        case .speechRecognition:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            switch status {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .restricted: return .restricted
            case .authorized: return .authorized
            @unknown default: return .unknown
            }
        case .automation, .inputMonitoring, .fullDiskAccess:
            throw MacOSPermissionAdapterError.unsupportedRequest
        }
    }

    private static func mapCaptureStatus(_ status: AVAuthorizationStatus) -> PermissionAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unknown
        }
    }
}

enum MacOSApplicationBundle {
    static var isCurrentProcess: Bool {
        Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }
}

public enum MacOSPermissionAdapterError: Error, Sendable, Equatable {
    case unsupportedRequest
    case requestFailed
}
