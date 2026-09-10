import CryptoKit
import Darwin
import Foundation

public struct EmbeddedCuaDriverResourceManifest: Decodable, Sendable, Hashable {
    public let version: String
    public let releaseTag: String
    public let releaseCommit: String
    public let archiveSHA256: String
    public let binarySHA256: String
    public let sessionPolicySHA256: String

    enum CodingKeys: String, CodingKey {
        case version
        case releaseTag = "release_tag"
        case releaseCommit = "release_commit"
        case archiveSHA256 = "archive_sha256"
        case binarySHA256 = "binary_sha256"
        case sessionPolicySHA256 = "session_policy_sha256"
    }
}

public enum PinnedEmbeddedCuaDriverHostError: Error, Sendable, Equatable {
    case resourceMissing
    case invalidManifest
    case invalidHostIdentity
    case resourceHashMismatch
    case endpointConflict
    case spawnFailed
    case startupTimedOut
    case proxyFailed
    case protocolFailure
    case incompatibleDriver
    case hostAttributionMissing
    case requiredPermissionMissing
    case driverExited
}

/// A private MCP call boundary. It is intentionally internal so callers outside
/// this file can obtain only `CUASemanticTransport`, never raw CUA tools.
private protocol CuaMCPCalling: Sendable {
    func call(tool: String, arguments: [String: JSONValue]) async throws -> JSONObjectEnvelope
    func close() async
}

/// Direct-child host for the exact CUA Driver release bundled by Menso's release
/// lane. It mirrors the upstream embedded contract: a private daemon inherits
/// the signed host's TCC responsibility chain, and a second child exposes MCP
/// only to this process over stdio. Neither child is launched through
/// LaunchServices, a shell, or AgentOS.
public actor PinnedEmbeddedCuaDriverHost: EmbeddedCuaDriverHost {
    public static let reviewedVersion = "0.12.6"
    public static let reviewedReleaseTag = "cua-driver-rs-v0.12.6"
    public static let reviewedReleaseCommit = "9eb1f481b8a12cd6ffda2ad5af21653a9e5aa9e5"
    public static let reviewedArchiveSHA256 = "c64017d5878d022df34137082fb918ae0d4304e28890569ff14458f1a54fd361"
    public static let reviewedBinarySHA256 = "3ee06efc14bb4ec501a4a8d8963514150684332f0281cc224c51b3dba3ef76ea"
    public static let reviewedSessionPolicySHA256 = "4e1371fef7b210147782feffdb6c31ee2707884d1d5484d39cde861230d00707"
    public static let reviewedMCPProtocolVersion = "2025-06-18"

    private enum Phase {
        case stopped
        case starting
        case ready(any CuaMCPCalling)
        case failed
    }

    private let bundle: Bundle
    private let startupTimeout: Duration
    private var phase: Phase = .stopped
    private var daemon: Process?
    private var daemonLiveness: Pipe?
    private var socketPath: String?

    public init(
        bundle: Bundle = .main,
        startupTimeout: Duration = .seconds(10)
    ) {
        self.bundle = bundle
        self.startupTimeout = startupTimeout
    }

    public func state() async -> CuaDriverHostState {
        switch phase {
        case .stopped: .stopped
        case .starting: .starting
        case .ready: .ready
        case .failed: .failed
        }
    }

    public func semanticTransport() async throws -> any CUASemanticTransport {
        switch phase {
        case let .ready(client):
            return PinnedCUASemanticTransport(client: client)
        case .starting:
            throw CuaDriverHostError.unavailable
        case .stopped, .failed:
            try await start()
            guard case let .ready(client) = phase else {
                throw CuaDriverHostError.unavailable
            }
            return PinnedCUASemanticTransport(client: client)
        }
    }

    public func stop() async {
        let client: (any CuaMCPCalling)?
        if case let .ready(current) = phase { client = current } else { client = nil }
        phase = .stopped
        await client?.close()
        daemonLiveness?.fileHandleForWriting.closeFile()
        daemonLiveness = nil
        if let daemon, daemon.isRunning {
            daemon.terminate()
            await Self.waitForExit(daemon, timeout: .seconds(2))
            if daemon.isRunning { kill(daemon.processIdentifier, SIGKILL) }
        }
        daemon = nil
        if let socketPath { try? Self.removeOwnedSocket(at: socketPath) }
        socketPath = nil
    }

    private func start() async throws {
        guard case .stopped = phase else {
            if case .failed = phase { phase = .stopped } else { return }
            return try await start()
        }
        phase = .starting
        do {
            let resources = try Self.resources(in: bundle)
            let endpoint = try Self.makePrivateSocketPath()
            try Self.prepareEndpoint(endpoint)

            let liveness = Pipe()
            let daemon = Process()
            daemon.executableURL = resources.binary
            daemon.arguments = [
                "serve", "--embedded", "--parent-liveness-stdio",
                "--no-permissions-gate", "--socket", endpoint,
                "--host-bundle-id", resources.bundleIdentifier,
                "--permission-mode", "bounded",
                "--session-policy", resources.sessionPolicy.path,
                "--approve-session-policy",
            ]
            daemon.environment = Self.minimumEnvironment()
            daemon.standardInput = liveness
            daemon.standardOutput = FileHandle.nullDevice
            daemon.standardError = FileHandle.nullDevice
            do { try daemon.run() }
            catch { throw PinnedEmbeddedCuaDriverHostError.spawnFailed }

            self.daemon = daemon
            daemonLiveness = liveness
            socketPath = endpoint
            try await Self.waitUntilReady(
                endpoint: endpoint,
                daemon: daemon,
                timeout: startupTimeout
            )

            let client = try await StdioCuaMCPClient.start(
                binary: resources.binary,
                socketPath: endpoint,
                hostBundleIdentifier: resources.bundleIdentifier,
                protocolVersion: Self.reviewedMCPProtocolVersion
            )
            let permissions = try await client.call(tool: "check_permissions", arguments: [:])
            try Self.verifyHostPermissions(
                permissions,
                hostBundleIdentifier: resources.bundleIdentifier
            )
            phase = .ready(client)
        } catch {
            phase = .failed
            await stopAfterFailedStart()
            throw error
        }
    }

    private func stopAfterFailedStart() async {
        daemonLiveness?.fileHandleForWriting.closeFile()
        daemonLiveness = nil
        if let daemon, daemon.isRunning {
            daemon.terminate()
            await Self.waitForExit(daemon, timeout: .seconds(2))
            if daemon.isRunning { kill(daemon.processIdentifier, SIGKILL) }
        }
        daemon = nil
        if let socketPath { try? Self.removeOwnedSocket(at: socketPath) }
        socketPath = nil
        phase = .failed
    }

    private struct Resources {
        let binary: URL
        let sessionPolicy: URL
        let bundleIdentifier: String
    }

    private static func resources(in bundle: Bundle) throws -> Resources {
        guard let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              !bundleIdentifier.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              })
        else { throw PinnedEmbeddedCuaDriverHostError.invalidHostIdentity }
        guard let resources = bundle.resourceURL,
              let manifestURL = bundle.url(
                  forResource: "manifest",
                  withExtension: "json",
                  subdirectory: "CuaDriver"
              ),
              let policyURL = bundle.url(
                  forResource: "session-policy",
                  withExtension: "yaml",
                  subdirectory: "CuaDriver"
              )
        else { throw PinnedEmbeddedCuaDriverHostError.resourceMissing }
        let binary = resources
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers/cua-driver", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw PinnedEmbeddedCuaDriverHostError.resourceMissing
        }
        let manifest: EmbeddedCuaDriverResourceManifest
        do {
            manifest = try JSONDecoder().decode(
                EmbeddedCuaDriverResourceManifest.self,
                from: Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            )
        } catch { throw PinnedEmbeddedCuaDriverHostError.invalidManifest }
        guard manifest.version == reviewedVersion,
              manifest.releaseTag == reviewedReleaseTag,
              manifest.releaseCommit == reviewedReleaseCommit,
              manifest.archiveSHA256 == reviewedArchiveSHA256,
              manifest.binarySHA256 == reviewedBinarySHA256,
              manifest.sessionPolicySHA256 == reviewedSessionPolicySHA256,
              try Self.sha256(binary) == manifest.binarySHA256,
              try Self.sha256(policyURL) == manifest.sessionPolicySHA256
        else { throw PinnedEmbeddedCuaDriverHostError.resourceHashMismatch }
        return Resources(binary: binary, sessionPolicy: policyURL, bundleIdentifier: bundleIdentifier)
    }

    fileprivate static func minimumEnvironment() -> [String: String] {
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
        ]
        if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") {
            environment["HOME"] = home
        }
        return environment
    }

    private static func makePrivateSocketPath() throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let path = directory.appendingPathComponent(
            "menso-cua-\(UUID().uuidString.lowercased()).sock",
            isDirectory: false
        ).path
        guard path.utf8.count < 100 else { throw PinnedEmbeddedCuaDriverHostError.endpointConflict }
        return path
    }

    private static func prepareEndpoint(_ path: String) throws {
        var status = stat()
        if lstat(path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFSOCK else {
                throw PinnedEmbeddedCuaDriverHostError.endpointConflict
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw PinnedEmbeddedCuaDriverHostError.endpointConflict
            }
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                bytes.withUnsafeBufferPointer { source in
                    destination.update(from: source.baseAddress!, count: source.count)
                }
            }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { if descriptor >= 0 { close(descriptor) } }
            let live = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            guard !live else { throw PinnedEmbeddedCuaDriverHostError.endpointConflict }
            try removeOwnedSocket(at: path)
        } else if errno != ENOENT {
            throw PinnedEmbeddedCuaDriverHostError.endpointConflict
        }
    }

    private static func removeOwnedSocket(at path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { return }
            throw PinnedEmbeddedCuaDriverHostError.endpointConflict
        }
        guard (status.st_mode & S_IFMT) == S_IFSOCK,
              status.st_uid == getuid()
        else { throw PinnedEmbeddedCuaDriverHostError.endpointConflict }
        guard unlink(path) == 0 else { throw PinnedEmbeddedCuaDriverHostError.endpointConflict }
    }

    private static func waitUntilReady(
        endpoint: String,
        daemon: Process,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard daemon.isRunning else { throw PinnedEmbeddedCuaDriverHostError.driverExited }
            var status = stat()
            if lstat(endpoint, &status) == 0,
               (status.st_mode & S_IFMT) == S_IFSOCK,
               status.st_uid == getuid() {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PinnedEmbeddedCuaDriverHostError.startupTimedOut
    }

    private static func verifyHostPermissions(
        _ response: JSONObjectEnvelope,
        hostBundleIdentifier: String
    ) throws {
        guard let object = response.fields["structuredContent"]?.objectValue
                ?? response.fields["structured_content"]?.objectValue,
              let source = object["source"]?.objectValue,
              source["embedded"]?.boolValue == true,
              source["attribution"]?.stringValue == "host",
              source["host_bundle_id"]?.stringValue == hostBundleIdentifier
        else { throw PinnedEmbeddedCuaDriverHostError.hostAttributionMissing }
        // Menso's semantic adapter is AX-only and explicitly requests
        // include_screenshot=false. Screen Recording is not required or
        // requested for this path; a future visual adapter must define its own
        // typed verification contract and permission boundary.
        guard object["accessibility"]?.boolValue == true else {
            throw PinnedEmbeddedCuaDriverHostError.requiredPermissionMissing
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func waitForExit(_ process: Process, timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}

private actor StdioCuaMCPClient: CuaMCPCalling {
    private static let maximumLineBytes = 16 * 1_024 * 1_024

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var nextID: UInt64 = 2
    private var closed = false

    private init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
    }

    static func start(
        binary: URL,
        socketPath: String,
        hostBundleIdentifier: String,
        protocolVersion: String
    ) async throws -> StdioCuaMCPClient {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "mcp", "--embedded", "--socket", socketPath,
            "--host-bundle-id", hostBundleIdentifier,
        ]
        process.environment = PinnedEmbeddedCuaDriverHost.minimumEnvironment()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw PinnedEmbeddedCuaDriverHostError.proxyFailed }
        let client = StdioCuaMCPClient(
            process: process,
            input: stdinPipe.fileHandleForWriting,
            output: stdoutPipe.fileHandleForReading
        )
        let initialization = try await client.request(
            id: 1,
            method: "initialize",
            params: .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("menso-embedded-cua"),
                    "version": .string("1"),
                ]),
            ])
        )
        guard let result = initialization.fields["result"]?.objectValue,
              result["protocolVersion"]?.stringValue == protocolVersion,
              let serverInfo = result["serverInfo"]?.objectValue,
              serverInfo["name"]?.stringValue == "cua-driver",
              serverInfo["version"]?.stringValue == PinnedEmbeddedCuaDriverHost.reviewedVersion
        else {
            await client.close()
            throw PinnedEmbeddedCuaDriverHostError.incompatibleDriver
        }
        try await client.sendNotification(method: "notifications/initialized", params: .object([:]))
        return client
    }

    func call(tool: String, arguments: [String: JSONValue]) async throws -> JSONObjectEnvelope {
        guard !closed, process.isRunning else {
            throw PinnedEmbeddedCuaDriverHostError.driverExited
        }
        let identifier = nextID
        guard identifier < UInt64.max else {
            throw PinnedEmbeddedCuaDriverHostError.protocolFailure
        }
        nextID += 1
        let envelope = try await request(
            id: identifier,
            method: "tools/call",
            params: .object([
                "name": .string(tool),
                "arguments": .object(arguments),
            ])
        )
        guard envelope.fields["error"] == nil,
              let result = envelope.fields["result"]?.objectValue,
              result["isError"]?.boolValue != true,
              result["is_error"]?.boolValue != true
        else { throw PinnedEmbeddedCuaDriverHostError.protocolFailure }
        return JSONObjectEnvelope(fields: result)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        try? input.close()
        try? output.close()
        if process.isRunning {
            process.terminate()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while process.isRunning, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func sendNotification(method: String, params: JSONValue) async throws {
        try write(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]))
    }

    private func request(
        id: UInt64,
        method: String,
        params: JSONValue
    ) async throws -> JSONObjectEnvelope {
        try write(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(.unsignedInteger(id)),
            "method": .string(method),
            "params": params,
        ]))
        while true {
            let response = try readLine()
            guard let object = response.objectValue else {
                throw PinnedEmbeddedCuaDriverHostError.protocolFailure
            }
            let signedID = Int64(exactly: id).map { JSONValue.number(.signedInteger($0)) }
            if object["id"] == .number(.unsignedInteger(id))
                || object["id"] == signedID {
                return JSONObjectEnvelope(fields: object)
            }
            // Ignore bounded server notifications; no other request is in
            // flight because this actor serializes every call.
        }
    }

    private func write(_ value: JSONValue) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count < Self.maximumLineBytes else {
            throw PinnedEmbeddedCuaDriverHostError.protocolFailure
        }
        var line = data
        line.append(0x0A)
        try input.write(contentsOf: line)
    }

    private func readLine() throws -> JSONValue {
        var data = Data()
        while data.count < Self.maximumLineBytes {
            guard let byte = try output.read(upToCount: 1), !byte.isEmpty else {
                throw PinnedEmbeddedCuaDriverHostError.driverExited
            }
            if byte[0] == 0x0A { break }
            data.append(byte)
        }
        guard !data.isEmpty, data.count < Self.maximumLineBytes else {
            throw PinnedEmbeddedCuaDriverHostError.protocolFailure
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// Semantic adapter over the reviewed CUA release. Raw MCP remains private to
/// this file. Every successful receipt is based on a fresh structured read-back;
/// transport acceptance, screenshots, coordinates, and unverified clicks never
/// count as completion.
private struct PinnedCUASemanticTransport:
    CUASemanticTransport,
    CUATextInsertionTransport
{
    private let client: any CuaMCPCalling

    init(client: any CuaMCPCalling) { self.client = client }

    func performApplicationAction(
        _ request: CUAApplicationActionRequest
    ) async throws -> CUAApplicationActionReceipt {
        let session = Self.sessionID(for: request.actionID)
        try await startSession(session)
        do {
            let evidence: [JSONValue]
            switch request.operation.kind {
            case .openApplication:
                evidence = try await openApplication(request, session: session)
            case .focusWindow:
                evidence = try await focusWindow(request, session: session)
            case .insertText:
                guard let text = request.operation.text else {
                    throw LocalToolBrokerError.contentMismatch
                }
                evidence = try await insert(
                    actionID: request.actionID,
                    target: request.target,
                    text: text,
                    session: session
                )
            case .activateControl:
                guard let expectedState = request.operation.expectedState else {
                    throw LocalToolBrokerError.contentMismatch
                }
                evidence = try await activate(
                    target: request.target,
                    expectedState: expectedState,
                    session: session
                )
            }
            try? await endSession(session)
            return CUAApplicationActionReceipt(
                actionID: request.actionID,
                target: request.target,
                actionKind: request.operation.kind,
                contentHash: request.operation.contentHash,
                verified: true,
                evidenceReference: Self.evidenceReference(
                    actionID: request.actionID,
                    values: evidence
                )
            )
        } catch {
            try? await endSession(session)
            throw error
        }
    }

    func insertText(_ request: CUATextInsertionRequest) async throws -> CUATextInsertionReceipt {
        guard request.contentHash == .sha256(of: request.text), !request.text.isEmpty else {
            throw LocalToolBrokerError.contentMismatch
        }
        let session = Self.sessionID(for: request.actionID)
        try await startSession(session)
        do {
            let evidence = try await insert(
                actionID: request.actionID,
                target: request.target,
                text: request.text,
                session: session
            )
            try? await endSession(session)
            return CUATextInsertionReceipt(
                actionID: request.actionID,
                target: request.target,
                contentHash: request.contentHash,
                verified: true,
                evidenceReference: Self.evidenceReference(
                    actionID: request.actionID,
                    values: evidence
                )
            )
        } catch {
            try? await endSession(session)
            throw error
        }
    }

    private func startSession(_ session: String) async throws {
        _ = try await client.call(
            tool: "start_session",
            arguments: [
                "session": .string(session),
                "capture_scope": .string("window"),
            ]
        )
    }

    private func endSession(_ session: String) async throws {
        _ = try await client.call(
            tool: "end_session",
            arguments: ["session": .string(session)]
        )
    }

    private func openApplication(
        _ request: CUAApplicationActionRequest,
        session _: String
    ) async throws -> [JSONValue] {
        let launch = try await client.call(
            tool: "launch_app",
            arguments: ["bundle_id": .string(request.target.bundleIdentifier)]
        )
        let launchState = try Self.structured(launch)
        guard launchState["bundle_id"]?.stringValue == request.target.bundleIdentifier,
              let pid = Self.int32(launchState["pid"]),
              request.target.processIdentifier.map({ $0 == pid }) ?? true
        else { throw LocalToolBrokerError.targetMismatch }

        let activation = try await client.call(
            tool: "bring_to_front",
            arguments: ["pid": .number(.signedInteger(Int64(pid)))]
        )
        let activationState = try Self.structured(activation)
        guard activationState["activated"]?.boolValue == true else {
            throw LocalToolBrokerError.verificationFailed
        }
        let apps = try await client.call(tool: "list_apps", arguments: [:])
        try Self.verifyActiveApplication(
            structured: Self.structured(apps),
            bundleIdentifier: request.target.bundleIdentifier,
            pid: pid
        )
        return [.object(launchState), .object(activationState), .object(try Self.structured(apps))]
    }

    private func focusWindow(
        _ request: CUAApplicationActionRequest,
        session _: String
    ) async throws -> [JSONValue] {
        let appState = try await resolveRunningApplication(request.target)
        let beforeWindows = try await client.call(
            tool: "list_windows",
            arguments: ["pid": .number(.signedInteger(Int64(appState.pid)))]
        )
        let window = try Self.resolveExactWindow(
            structured: Self.structured(beforeWindows),
            title: request.target.windowTitle
        )
        let activation = try await client.call(
            tool: "bring_to_front",
            arguments: [
                "pid": .number(.signedInteger(Int64(appState.pid))),
                "window_id": .number(.unsignedInteger(window.id)),
            ]
        )
        let activationState = try Self.structured(activation)
        guard activationState["activated"]?.boolValue == true else {
            throw LocalToolBrokerError.verificationFailed
        }
        let afterApps = try await client.call(tool: "list_apps", arguments: [:])
        try Self.verifyActiveApplication(
            structured: Self.structured(afterApps),
            bundleIdentifier: request.target.bundleIdentifier,
            pid: appState.pid
        )
        let afterWindows = try await client.call(
            tool: "list_windows",
            arguments: ["pid": .number(.signedInteger(Int64(appState.pid)))]
        )
        let verifiedWindow = try Self.resolveExactWindow(
            structured: Self.structured(afterWindows),
            title: request.target.windowTitle
        )
        guard verifiedWindow.id == window.id else { throw LocalToolBrokerError.verificationFailed }
        return [
            .object(try Self.structured(beforeWindows)),
            .object(activationState),
            .object(try Self.structured(afterApps)),
            .object(try Self.structured(afterWindows)),
        ]
    }

    private func insert(
        actionID _: ActionID,
        target: FocusedApplicationTarget,
        text: String,
        session: String
    ) async throws -> [JSONValue] {
        guard !text.isEmpty else { throw LocalToolBrokerError.contentMismatch }
        let app = try await resolveRunningApplication(target)
        let windows = try await client.call(
            tool: "list_windows",
            arguments: ["pid": .number(.signedInteger(Int64(app.pid)))]
        )
        let window = try Self.resolveExactWindow(
            structured: Self.structured(windows),
            title: target.windowTitle
        )
        let before = try await snapshot(
            pid: app.pid,
            windowID: window.id,
            session: session
        )
        let element = try Self.resolveExactElement(
            structured: Self.structured(before),
            role: target.elementRole,
            label: target.elementLabel
        )
        var arguments: [String: JSONValue] = [
            "session": .string(session),
            "pid": .number(.signedInteger(Int64(app.pid))),
            "window_id": .number(.unsignedInteger(window.id)),
            "text": .string(text),
            "delivery_mode": .string("background"),
        ]
        if let token = element.token {
            arguments["element_token"] = .string(token)
        } else {
            arguments["element_index"] = .number(.unsignedInteger(element.index))
        }
        let write = try await client.call(tool: "type_text", arguments: arguments)
        let writeState = try Self.structured(write)
        guard writeState["verified"]?.boolValue == true,
              writeState["effect"]?.stringValue == "confirmed"
        else { throw LocalToolBrokerError.verificationFailed }

        let after = try await snapshot(
            pid: app.pid,
            windowID: window.id,
            session: session
        )
        let verified = try Self.resolveExactElement(
            structured: Self.structured(after),
            role: target.elementRole,
            label: target.elementLabel
        )
        guard verified.value?.contains(text) == true else {
            throw LocalToolBrokerError.verificationFailed
        }
        return [
            .object(try Self.structured(windows)),
            .object(try Self.structured(before)),
            .object(writeState),
            .object(try Self.structured(after)),
        ]
    }

    private func activate(
        target: FocusedApplicationTarget,
        expectedState: String,
        session: String
    ) async throws -> [JSONValue] {
        guard !expectedState.isEmpty else { throw LocalToolBrokerError.contentMismatch }
        let app = try await resolveRunningApplication(target)
        let windows = try await client.call(
            tool: "list_windows",
            arguments: ["pid": .number(.signedInteger(Int64(app.pid)))]
        )
        let window = try Self.resolveExactWindow(
            structured: Self.structured(windows),
            title: target.windowTitle
        )
        let before = try await snapshot(pid: app.pid, windowID: window.id, session: session)
        let element = try Self.resolveExactElement(
            structured: Self.structured(before),
            role: target.elementRole,
            label: target.elementLabel
        )
        if element.matchesState(expectedState) {
            return [.object(try Self.structured(windows)), .object(try Self.structured(before))]
        }

        var arguments: [String: JSONValue] = [
            "session": .string(session),
            "pid": .number(.signedInteger(Int64(app.pid))),
            "window_id": .number(.unsignedInteger(window.id)),
            "action": .string("press"),
            "delivery_mode": .string("background"),
        ]
        if let token = element.token {
            arguments["element_token"] = .string(token)
        } else {
            arguments["element_index"] = .number(.unsignedInteger(element.index))
        }
        let click = try await client.call(tool: "click", arguments: arguments)
        let after = try await snapshot(pid: app.pid, windowID: window.id, session: session)
        let postElement = try Self.resolveExactElement(
            structured: Self.structured(after),
            role: target.elementRole,
            label: target.elementLabel
        )
        guard postElement.matchesState(expectedState) else {
            throw LocalToolBrokerError.verificationFailed
        }
        return [
            .object(try Self.structured(windows)),
            .object(try Self.structured(before)),
            .object(try Self.structured(click)),
            .object(try Self.structured(after)),
        ]
    }

    private func snapshot(
        pid: Int32,
        windowID: UInt64,
        session: String
    ) async throws -> JSONObjectEnvelope {
        try await client.call(
            tool: "get_window_state",
            arguments: [
                "session": .string(session),
                "pid": .number(.signedInteger(Int64(pid))),
                "window_id": .number(.unsignedInteger(windowID)),
                "include_screenshot": .bool(false),
                "max_elements": .number(.signedInteger(2_000)),
                "max_depth": .number(.signedInteger(25)),
            ]
        )
    }

    private func resolveRunningApplication(
        _ target: FocusedApplicationTarget
    ) async throws -> (pid: Int32, state: [String: JSONValue]) {
        let response = try await client.call(tool: "list_apps", arguments: [:])
        let structured = try Self.structured(response)
        let matches = structured["apps"]?.arrayValue?.compactMap { value -> (Int32, [String: JSONValue])? in
            guard let object = value.objectValue,
                  object["bundle_id"]?.stringValue == target.bundleIdentifier,
                  object["running"]?.boolValue == true,
                  let pid = Self.int32(object["pid"]),
                  target.processIdentifier.map({ $0 == pid }) ?? true
            else { return nil }
            return (pid, object)
        } ?? []
        guard matches.count == 1, let match = matches.first else {
            throw LocalToolBrokerError.targetMismatch
        }
        return (match.0, match.1)
    }

    private static func verifyActiveApplication(
        structured: [String: JSONValue],
        bundleIdentifier: String,
        pid: Int32
    ) throws {
        let matches = structured["apps"]?.arrayValue?.compactMap(\.objectValue).filter {
            $0["bundle_id"]?.stringValue == bundleIdentifier
                && int32($0["pid"]) == pid
                && $0["running"]?.boolValue == true
                && $0["active"]?.boolValue == true
        } ?? []
        guard matches.count == 1 else { throw LocalToolBrokerError.verificationFailed }
    }

    private struct WindowState {
        let id: UInt64
        let title: String
    }

    private static func resolveExactWindow(
        structured: [String: JSONValue],
        title: String?
    ) throws -> WindowState {
        guard let title, !title.isEmpty else { throw LocalToolBrokerError.targetMismatch }
        let matches = structured["windows"]?.arrayValue?.compactMap { value -> WindowState? in
            guard let object = value.objectValue,
                  object["title"]?.stringValue == title,
                  let id = unsigned(object["window_id"])
            else { return nil }
            return WindowState(id: id, title: title)
        } ?? []
        guard matches.count == 1, let match = matches.first else {
            throw LocalToolBrokerError.targetMismatch
        }
        return match
    }

    private struct ElementState {
        let index: UInt64
        let token: String?
        let value: String?
        let valueDescription: String?
        let selected: Bool?
        let enabled: Bool?

        func matchesState(_ expected: String) -> Bool {
            if value == expected || valueDescription == expected { return true }
            switch expected.lowercased() {
            case "selected", "checked", "on", "true", "1": return selected == true
            case "unselected", "unchecked", "off", "false", "0": return selected == false
            case "enabled": return enabled == true
            case "disabled": return enabled == false
            default: return false
            }
        }
    }

    private static func resolveExactElement(
        structured: [String: JSONValue],
        role: String?,
        label: String?
    ) throws -> ElementState {
        guard let role, !role.isEmpty, let label, !label.isEmpty,
              structured["degraded"]?.boolValue != true
        else { throw LocalToolBrokerError.targetMismatch }
        let matches = structured["elements"]?.arrayValue?.compactMap { value -> ElementState? in
            guard let object = value.objectValue,
                  object["role"]?.stringValue == role,
                  object["label"]?.stringValue == label,
                  let index = unsigned(object["element_index"])
            else { return nil }
            return ElementState(
                index: index,
                token: object["element_token"]?.stringValue,
                value: object["value"]?.stringValue,
                valueDescription: object["value_description"]?.stringValue,
                selected: object["selected"]?.boolValue,
                enabled: object["enabled"]?.boolValue
            )
        } ?? []
        guard matches.count == 1, let match = matches.first else {
            throw LocalToolBrokerError.targetMismatch
        }
        return match
    }

    private static func structured(_ response: JSONObjectEnvelope) throws -> [String: JSONValue] {
        guard let structured = response.fields["structuredContent"]?.objectValue
                ?? response.fields["structured_content"]?.objectValue
        else { throw PinnedEmbeddedCuaDriverHostError.protocolFailure }
        return structured
    }

    private static func int32(_ value: JSONValue?) -> Int32? {
        guard let value else { return nil }
        switch value.numberValue {
        case let .signedInteger(number): return Int32(exactly: number)
        case let .unsignedInteger(number): return Int32(exactly: number)
        case .decimal, .none: return nil
        }
    }

    private static func unsigned(_ value: JSONValue?) -> UInt64? {
        guard let value else { return nil }
        switch value.numberValue {
        case let .signedInteger(number): return UInt64(exactly: number)
        case let .unsignedInteger(number): return number
        case .decimal, .none: return nil
        }
    }

    private static func sessionID(for actionID: ActionID) -> String {
        "menso-" + String(ContentHash.sha256(of: actionID.rawValue).rawValue.prefix(32))
    }

    private static func evidenceReference(
        actionID: ActionID,
        values: [JSONValue]
    ) -> EvidenceReference {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(values)) ?? Data()
        var hasher = SHA256()
        hasher.update(data: Data(actionID.rawValue.utf8))
        hasher.update(data: encoded)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return EvidenceReference(rawValue: "cua:\(digest)")
    }
}
