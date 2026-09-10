import Darwin
import Foundation

/// Per-file kqueue activity used after FSEvents discovers telemetry JSONL.
/// Rename/delete/revoke events retire the stale descriptor immediately; the
/// root watcher and periodic reconciliation then discover the replacement.
public final class TelemetryFileActivityWatcher: @unchecked Sendable {
    private struct Entry {
        let token: UUID
        let source: DispatchSourceFileSystemObject
    }

    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.menso.telemetry-file-activity",
            qos: .utility
        ),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func update(paths: [String], maximumFiles: Int = 512) {
        let desired = Set(paths.prefix(max(0, maximumFiles)))
        lock.lock()
        let stale = entries.keys.filter { !desired.contains($0) }
        let missing = desired.filter { entries[$0] == nil }
        for path in stale {
            entries.removeValue(forKey: path)?.source.cancel()
        }
        for path in missing {
            guard let entry = makeEntry(path: path) else { continue }
            entries[path] = entry
            entry.source.resume()
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let sources = entries.values.map(\.source)
        entries.removeAll()
        lock.unlock()
        for source in sources { source.cancel() }
    }

    private func makeEntry(path: String) -> Entry? {
        let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let token = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleEvent(path: path, token: token)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        return Entry(token: token, source: source)
    }

    private func handleEvent(path: String, token: UUID) {
        lock.lock()
        guard let entry = entries[path], entry.token == token else {
            lock.unlock()
            return
        }
        let shouldRetire = !entry.source.data
            .intersection([.rename, .delete, .revoke])
            .isEmpty
        if shouldRetire {
            entries.removeValue(forKey: path)
        }
        lock.unlock()
        if shouldRetire {
            entry.source.cancel()
        }
        onChange()
    }
}
