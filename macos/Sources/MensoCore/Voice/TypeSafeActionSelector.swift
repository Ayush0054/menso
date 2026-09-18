import Foundation

/// Only this projection crosses the network. Authority stays in the local catalog.
public struct VoiceActionCandidate: Codable, Sendable, Hashable {
    public let id: String
    public let kind: String
    public let description: String
}

public struct VoiceActionSelection: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case selected, unclear, unsupported, complete }
    public let status: Status
    public let candidateID: String?

    enum CodingKeys: String, CodingKey {
        case status
        case candidateID = "candidate_id"
    }
}

public protocol VoiceActionSelecting: Sendable {
    func select(
        utterance: String, candidates: [VoiceActionCandidate], completedSteps: [VoiceActionCandidate], userID: UserID
    ) async throws -> VoiceActionSelection
}

public enum TypeSafeActionError: Error, Sendable, Equatable {
    case notConfigured
    case authenticationFailed
    case unavailable

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let code: String }
        let detail: Detail
    }

    static func gatewayFailure(from data: Data) -> Self {
        guard data.count <= 16_384,
              let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              envelope.detail.code == "typesafe_authentication_failed"
        else { return .unavailable }
        return .authenticationFailed
    }
}

private final class NoActionRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

/// Uses Menso authentication, never embeds the TypeSafe provider key in the app.
public struct TypeSafeActionSelector: VoiceActionSelecting {
    private struct Body: Encodable {
        let utterance: String
        let candidates: [VoiceActionCandidate]
        let completed_steps: [VoiceActionCandidate]
    }
    private let configuration: AgentOSConnectionConfiguration
    private let tokenProvider: any AgentOSAccessTokenProvider
    private let session: URLSession

    public init(configuration: AgentOSConnectionConfiguration, tokenProvider: any AgentOSAccessTokenProvider) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        self.session = URLSession(configuration: settings, delegate: NoActionRedirects(), delegateQueue: nil)
    }

    public func select(
        utterance: String, candidates: [VoiceActionCandidate], completedSteps: [VoiceActionCandidate], userID: UserID
    ) async throws -> VoiceActionSelection {
        let token = try await tokenProvider.accessToken()
        guard token.expiresAt > Date(), !token.value.isEmpty else {
            throw AgentOSClientError.expiredAccessToken
        }
        let identity = try await AgentOSVerifiedAuthenticationContextClient(
            configuration: configuration,
            tokenProvider: FixedBearerAccessTokenProvider(token: token), session: session
        ).fetchContext()
        guard identity.userID == userID else { throw AgentOSClientError.authenticatedIdentityMismatch }
        try Task.checkCancellation()
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("menso/actions/next"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(Body(utterance: utterance, candidates: candidates, completed_steps: completedSteps))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentOSClientError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 503: throw TypeSafeActionError.notConfigured
        case 502: throw TypeSafeActionError.gatewayFailure(from: data)
        default: throw AgentOSClientError.httpStatus(http.statusCode)
        }
        guard data.count <= 16_384 else { throw AgentOSClientError.invalidResponse }
        let result = try JSONDecoder().decode(VoiceActionSelection.self, from: data)
        guard result.status != .complete || !completedSteps.isEmpty else {
            throw AgentOSClientError.invalidResponse
        }
        if result.status == .selected {
            guard let id = result.candidateID, candidates.contains(where: { $0.id == id }) else {
                throw AgentOSClientError.invalidResponse
            }
        } else if result.candidateID != nil {
            throw AgentOSClientError.invalidResponse
        }
        return result
    }
}

/// Builds immutable, request-scoped alternatives before any model is called.
struct NativeVoiceActionCatalog: Sendable {
    struct Entry: Sendable {
        let candidate: VoiceActionCandidate
        let authority: TrustedVoiceActionAuthority
        let title: String
        let detail: String
    }
    let entries: [Entry]

    init(context: VoiceActionContext, utterance: String) {
        var choices: [Entry] = []
        func add(_ target: FocusedApplicationTarget, _ operation: ApplicationSemanticOperation,
                 title: String, detail: String) {
            guard let authority = try? TrustedVoiceActionAuthority(
                target: .focusedApplication(target), operation: .application(operation)
            ), context.permits(authority), choices.count < 200 else { return }
            let description = title + ". " + detail
            guard description.count <= 4096 else { return }
            choices.append(Entry(candidate: VoiceActionCandidate(
                id: "action_\(choices.count)", kind: operation.kind.rawValue, description: description
            ), authority: authority, title: title, detail: detail))
        }
        for app in context.applications.prefix(160) {
            add(.init(bundleIdentifier: app.bundleIdentifier), .init(kind: .openApplication),
                title: "Open \(app.name)", detail: "Launch or bring forward \(app.bundleIdentifier).")
        }
        if let target = context.focusedTarget {
            let label = [target.bundleIdentifier, target.windowTitle, target.elementLabel]
                .compactMap { $0 }.joined(separator: " · ")
            add(.init(bundleIdentifier: target.bundleIdentifier, processIdentifier: target.processIdentifier,
                      windowTitle: target.windowTitle), .init(kind: .focusWindow),
                title: "Focus window", detail: label)
            if target.elementRole != nil, target.elementLabel != nil {
                for text in Self.literalTextCandidates(utterance) {
                    add(target, .init(kind: .insertText, text: text), title: "Insert dictated text",
                        detail: "Into \(label):\n\(text)")
                }
                for state in ["checked", "unchecked", "selected", "unselected"] {
                    add(target, .init(kind: .activateControl, expectedState: state),
                        title: "Set control to \(state)", detail: label)
                }
            }
        }
        entries = choices
    }

    /// No generated strings: every candidate is an exact substring of this utterance.
    /// TypeSafe must abstain when a span contains command syntax or misses requested text.
    static func literalTextCandidates(_ utterance: String) -> [String] {
        var spans: [String] = []
        for (opening, closing) in [("\"", "\""), ("“", "”")] {
            if let start = utterance.range(of: opening),
               let end = utterance.range(of: closing, range: start.upperBound..<utterance.endIndex) {
                spans.append(String(utterance[start.upperBound..<end.lowerBound]))
            }
        }
        for prefix in ["type ", "insert ", "enter ", "write "] {
            if let marker = utterance.range(of: prefix, options: [.caseInsensitive]) {
                spans.append(String(utterance[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return Array(Set(spans.filter { !$0.isEmpty && $0.utf8.count <= 2000 })).sorted()
    }
}
