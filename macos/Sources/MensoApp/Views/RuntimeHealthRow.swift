import MensoCore
import SwiftUI

struct RuntimeHealthRow: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.needsApplicationsInstall {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Move Menso to Applications")
                    .lineLimit(1)
                Spacer(minLength: 4)
            } else if model.trustedRuntime == nil {
                Image(systemName: "lock.slash")
                    .foregroundStyle(.orange)
                Text("Trusted runtime unavailable")
                    .lineLimit(1)
                Spacer(minLength: 4)
            } else {
                permissionBadge(.accessibility, label: "Access")
                permissionBadge(.microphone, label: "Mic")
                Spacer(minLength: 4)
                if model.nextOnboardingPermission != nil {
                    Button("Enable") {
                        model.requestNextOnboardingPermission()
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                }
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.primary.opacity(0.035))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func permissionBadge(_ permission: MensoPermission, label: String) -> some View {
        let status = model.permissionHealth?.permissions[permission]?.status ?? .unknown
        Label(label, systemImage: icon(for: status))
            .foregroundStyle(color(for: status))
            .help("\(permission.displayName): \(status.displayName)")
    }

    private func icon(for status: PermissionAuthorizationStatus) -> String {
        switch status {
        case .authorized: "checkmark.circle.fill"
        case .denied, .restricted: "exclamationmark.triangle.fill"
        case .notDetermined, .unavailable, .unknown: "circle.dotted"
        }
    }

    private func color(for status: PermissionAuthorizationStatus) -> Color {
        switch status {
        case .authorized: .green
        case .denied, .restricted: .orange
        case .notDetermined, .unavailable, .unknown: .secondary
        }
    }
}

private extension MensoPermission {
    var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        case .notifications: "Notifications"
        case .automation: "Automation"
        case .speechRecognition: "Speech Recognition"
        case .screenRecording: "Screen Recording"
        case .inputMonitoring: "Input Monitoring"
        case .fullDiskAccess: "Full Disk Access"
        }
    }
}

private extension PermissionAuthorizationStatus {
    var displayName: String {
        switch self {
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
        case .unavailable: "Unavailable"
        case .unknown: "Unknown"
        }
    }
}
