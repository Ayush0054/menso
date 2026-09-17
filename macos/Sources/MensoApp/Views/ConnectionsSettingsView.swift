import AppKit
import MensoCore
import SwiftUI

struct ConnectionsSettingsView: View {
    private static let localAgentOSURL = URL(string: "http://127.0.0.1:8000")!

    let coordinator: TrustedRuntimeProvisioningCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var backendURL = "http://127.0.0.1:8000"
    @State private var sessionID = UUID().uuidString.lowercased()
    @State private var bearerToken = ""
    @State private var bearerExpiry = Date.now.addingTimeInterval(3_600)
    @State private var existingSummary: TrustedRuntimeConfigurationSummary?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Form {
                #if DEBUG
                Section("Local AgentOS") {
                    LabeledContent("AgentOS", value: Self.localAgentOSURL.absoluteString)
                    LabeledContent(
                        "Authentication",
                        value: existingSummary == nil ? "Loading…" : "Verified local JWT"
                    )
                    if let existingSummary {
                        LabeledContent(
                            "Token expiry",
                            value: existingSummary.accessTokenExpiresAt?.formatted() ?? "Unavailable"
                        )
                    }
                    Text("This debug build reads the ignored token from backend/.local-auth and verifies it with localhost AgentOS. No Keychain entry or manual token paste is required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #else
                Section("AgentOS") {
                    TextField("Server URL", text: $backendURL)
                    SecureField("Bearer access token", text: $bearerToken)
                    if existingSummary != nil {
                        Text("Enter the current or rotated bearer token again before saving; stored secrets are never read back into this form.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    DatePicker(
                        "Token expires",
                        selection: $bearerExpiry,
                        in: Date.now.addingTimeInterval(31)...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                if let existingSummary {
                    Section("Currently stored") {
                        LabeledContent("AgentOS", value: existingSummary.agentOSBaseURL.absoluteString)
                        LabeledContent("Session", value: existingSummary.sessionID.uuidString.lowercased())
                        LabeledContent(
                            "Bearer expiry",
                            value: existingSummary.accessTokenExpiresAt?.formatted() ?? "Unavailable"
                        )
                    }
                }
                #endif
            }
            .formStyle(.grouped)
            .disabled(isSaving || isLoading)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            #if DEBUG
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            #else
            HStack {
                Button("Clear Stored Connections", role: .destructive) {
                    clearConnections()
                }
                .disabled(existingSummary == nil || isSaving)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save and Verify") { saveConnections() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || isSaving || isLoading)
            }
            #endif
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .task { await loadSummary() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Connection")
                .font(.title2.bold())
            #if DEBUG
            Text("Local debug authentication is loaded from the ignored backend token and verified by AgentOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("Secrets are stored in the device-only Keychain. Menso verifies the bearer token with AgentOS before enabling it; restart Menso after saving or clearing connections.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }

    private var canSave: Bool {
        guard UUID(uuidString: sessionID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil,
              !bearerToken.isEmpty,
              bearerExpiry > Date.now.addingTimeInterval(30)
        else { return false }
        return true
    }

    private func loadSummary() async {
        defer { isLoading = false }
        do {
            switch try await coordinator.state() {
            case .unconfigured:
                existingSummary = nil
            case let .configured(summary):
                existingSummary = summary
                backendURL = summary.agentOSBaseURL.absoluteString
                sessionID = summary.sessionID.uuidString.lowercased()
                if let expiry = summary.accessTokenExpiresAt, expiry > Date.now {
                    bearerExpiry = expiry
                }
            }
        } catch {
            message = "Stored connection metadata could not be read. You can clear it and configure again."
        }
    }

    private func saveConnections() {
        guard let serverURL = URL(string: backendURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let session = UUID(uuidString: sessionID.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        isSaving = true
        message = "Verifying the authenticated AgentOS identity…"
        let request = TrustedRuntimeProvisioningRequest(
            agentOSBaseURL: serverURL,
            sessionID: session,
            accessToken: bearerToken,
            accessTokenExpiresAt: bearerExpiry
        )
        Task {
            do {
                try await coordinator.save(request)
                await MainActor.run {
                    bearerToken = ""
                    isSaving = false
                    message = "Verified and stored. Restart Menso to activate the new connection."
                }
                await loadSummary()
            } catch {
                await MainActor.run {
                    isSaving = false
                    message = "The connection was not stored because authenticated verification failed."
                }
            }
        }
    }

    private func clearConnections() {
        isSaving = true
        Task {
            do {
                try await coordinator.clear()
                await MainActor.run {
                    existingSummary = nil
                    sessionID = UUID().uuidString.lowercased()
                    bearerToken = ""
                    isSaving = false
                    message = "Stored AgentOS credentials were removed. Restart Menso to stop the active runtime."
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    message = "Some stored connection data could not be removed."
                }
            }
        }
    }
}
