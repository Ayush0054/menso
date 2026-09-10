import CoreServices
import Foundation

/// Coalesces native filesystem events into a cheap telemetry refresh signal.
/// The monitor retains periodic polling for reconciliation and for roots that
/// are created after launch.
public final class TelemetryFileSystemWatcher: @unchecked Sendable {
    private let roots: [URL]
    private let callbackQueue: DispatchQueue
    private let debounceInterval: DispatchTimeInterval
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var pendingWorkItem: DispatchWorkItem?

    public init(
        roots: [URL],
        callbackQueue: DispatchQueue = DispatchQueue(
            label: "com.menso.telemetry-fsevents",
            qos: .utility
        ),
        debounceInterval: DispatchTimeInterval = .milliseconds(180),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.roots = roots
        self.callbackQueue = callbackQueue
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil, !roots.isEmpty else { return stream != nil }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = roots.map(\.path) as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, contextInfo, eventCount, eventPaths, _, _ in
                guard contextInfo != nil, eventCount > 0 else { return }
                let watcher = Unmanaged<TelemetryFileSystemWatcher>
                    .fromOpaque(contextInfo!)
                    .takeUnretainedValue()
                // Paths and flags are intentionally ignored: every native
                // change is coalesced and parsers inspect only known JSONL.
                _ = eventPaths
                watcher.enqueueRefresh()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return false }

        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    public func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        lock.unlock()

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func enqueueRefresh() {
        lock.lock()
        pendingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        pendingWorkItem = item
        lock.unlock()
        callbackQueue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }
}
