import AppKit
import ApplicationServices
import Foundation

/// Request-scoped native observations, not permission to execute. A proposed
/// action must match these observations and still pass the local review gate.
public struct VoiceActionContext: Codable, Hashable, Sendable {
    public struct Application: Codable, Hashable, Sendable {
        public let name: String
        public let bundleIdentifier: String

        public init(name: String, bundleIdentifier: String) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
        }

        enum CodingKeys: String, CodingKey {
            case name
            case bundleIdentifier = "bundle_id"
        }
    }

    public let applications: [Application]
    public let focusedTarget: FocusedApplicationTarget?
    public let accessibilityGranted: Bool

    public init(
        applications: [Application],
        focusedTarget: FocusedApplicationTarget?,
        accessibilityGranted: Bool
    ) {
        self.applications = applications
        self.focusedTarget = focusedTarget
        self.accessibilityGranted = accessibilityGranted
    }

    func permits(_ authority: TrustedVoiceActionAuthority) -> Bool {
        guard accessibilityGranted,
              case let .focusedApplication(target) = authority.target,
              case let .application(operation) = authority.operation
        else { return false }
        switch operation.kind {
        case .openApplication:
            return applications.contains { $0.bundleIdentifier == target.bundleIdentifier }
                && target == FocusedApplicationTarget(bundleIdentifier: target.bundleIdentifier)
        case .focusWindow:
            guard let focusedTarget else { return false }
            return target == FocusedApplicationTarget(
                bundleIdentifier: focusedTarget.bundleIdentifier,
                processIdentifier: focusedTarget.processIdentifier,
                windowTitle: focusedTarget.windowTitle
            )
        case .insertText, .activateControl:
            return target == focusedTarget
        }
    }
}

public protocol VoiceActionContextProviding: Sendable {
    func contextForRequest() async -> VoiceActionContext
}

/// Reads app identities and the currently focused target only when voice
/// delegates a request. No polling, screenshots, field values, or activation.
public struct MacOSVoiceActionContextProvider: VoiceActionContextProviding {
    public init() {}

    public func contextForRequest() async -> VoiceActionContext {
        let native = await MainActor.run {
            let ownID = Bundle.main.bundleIdentifier ?? "com.menso.app"
            let granted = AXIsProcessTrusted()
            let observedTarget = granted ? (try? MacOSTrustedSemanticTargetProvider(
                excludedBundleIdentifiers: [ownID]
            ).focusedTarget()) : nil
            // Drop oversized metadata instead of truncating exact target keys.
            let target = observedTarget.flatMap { target -> FocusedApplicationTarget? in
                let labels = [target.bundleIdentifier, target.windowTitle, target.elementRole, target.elementLabel]
                return labels.compactMap { $0 }.allSatisfy { $0.utf8.count <= 1_024 } ? target : nil
            }
            let apps = NSWorkspace.shared.runningApplications.compactMap { app -> VoiceActionContext.Application? in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                      id != ownID, !id.isEmpty, id.utf8.count <= 256,
                      let name = app.localizedName else { return nil }
                return .init(name: String(name.prefix(128)), bundleIdentifier: id)
            }
            return (ownID, granted, target, apps)
        }
        // File discovery runs off the UI actor. Only application bundles in
        // standard app folders are inspected, never user documents or content.
        return await Task.detached {
            var apps = Dictionary(native.3.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
            let roots = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/System/Applications"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            ]
            for root in roots {
                let folders = [root, root.appendingPathComponent("Utilities")]
                for folder in folders {
                    let urls = (try? FileManager.default.contentsOfDirectory(
                        at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                    )) ?? []
                    for url in urls.sorted(by: { $0.path < $1.path }) where url.pathExtension == "app" {
                        guard apps.count < 160, let bundle = Bundle(url: url),
                              let id = bundle.bundleIdentifier, id != native.0,
                              !id.isEmpty, id.utf8.count <= 256 else { continue }
                        apps[id] = .init(
                            name: String(url.deletingPathExtension().lastPathComponent.prefix(128)),
                            bundleIdentifier: id
                        )
                    }
                }
            }
            return VoiceActionContext(
                applications: Array(apps.values.sorted { $0.name < $1.name }.prefix(160)),
                focusedTarget: native.2,
                accessibilityGranted: native.1
            )
        }.value
    }
}
