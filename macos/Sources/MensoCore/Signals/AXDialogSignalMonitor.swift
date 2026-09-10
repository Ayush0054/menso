@preconcurrency import AppKit
import ApplicationServices
import Foundation

/// Watches app-owned sheets and windows on a dedicated CFRunLoop thread.
/// Titles are presentation-only, attacker-controlled signal text; this type
/// never turns AX observations into action or policy authority.
@MainActor
public final class AXDialogSignalMonitor {
    private let workspace: NSWorkspace
    private let worker: AXDialogObserverWorker
    private var notificationTokens: [NSObjectProtocol] = []
    private var started = false

    public init(
        signalBus: SignalBus,
        workspace: NSWorkspace = .shared
    ) {
        self.workspace = workspace
        self.worker = AXDialogObserverWorker(signalBus: signalBus)
    }

    isolated deinit {
        for token in notificationTokens {
            workspace.notificationCenter.removeObserver(token)
        }
        worker.stop()
    }

    public func start() {
        guard !started else { return }
        started = true
        worker.start()

        for application in workspace.runningApplications {
            observe(application)
        }

        notificationTokens.append(
            workspace.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                else { return }
                Task { @MainActor [weak self] in self?.observe(application) }
            }
        )
        notificationTokens.append(
            workspace.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                else { return }
                self?.worker.remove(processIdentifier: application.processIdentifier)
            }
        )
    }

    public func stop() {
        guard started else { return }
        started = false
        for token in notificationTokens {
            workspace.notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
        worker.stop()
    }

    /// Retries observer installation for running apps after Accessibility is
    /// granted. Existing PID observations are ignored by the worker, so this is
    /// restart-free and safe to call whenever the app becomes active.
    public func refreshRunningApplications() {
        guard started else { return }
        for application in workspace.runningApplications {
            observe(application)
        }
    }

    private func observe(_ application: NSRunningApplication) {
        guard application.processIdentifier > 0,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy != .prohibited
        else { return }
        worker.add(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
        )
    }
}

private final class AXDialogObserverWorker: @unchecked Sendable {
    private enum Command {
        case add(pid_t, String)
        case remove(pid_t)
        case stop
    }

    private struct Observation {
        let observer: AXObserver
        let application: AXUIElement
        let bundleIdentifier: String
        let notifications: [String]
    }

    private static let callback: AXObserverCallback = { _, element, notification, context in
        guard let context else { return }
        let worker = Unmanaged<AXDialogObserverWorker>
            .fromOpaque(context)
            .takeUnretainedValue()
        worker.received(element: element, notification: notification as String)
    }

    private let signalBus: SignalBus
    private let commandLock = NSLock()
    private var queuedCommands: [Command] = []
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var threadCompletion: DispatchSemaphore?

    // Accessed only on the observer thread.
    private var observations: [pid_t: Observation] = [:]
    private var recentSignals: [String: Date] = [:]
    private var stopping = false

    init(signalBus: SignalBus) {
        self.signalBus = signalBus
    }

    func start() {
        commandLock.lock()
        guard thread == nil else {
            commandLock.unlock()
            return
        }
        stopping = false
        let completion = DispatchSemaphore(value: 0)
        // The observer callback uses passUnretained, so the observer thread
        // intentionally owns the worker until every AX callback is removed.
        let workerThread = Thread { [self, completion] in
            run(completion: completion)
        }
        workerThread.name = "com.menso.ax-dialog-observer"
        workerThread.qualityOfService = .utility
        thread = workerThread
        threadCompletion = completion
        commandLock.unlock()
        workerThread.start()
    }

    func add(processIdentifier: pid_t, bundleIdentifier: String) {
        enqueue(.add(processIdentifier, bundleIdentifier))
    }

    func remove(processIdentifier: pid_t) {
        enqueue(.remove(processIdentifier))
    }

    func stop() {
        commandLock.lock()
        guard let workerThread = thread,
              let completion = threadCompletion
        else {
            commandLock.unlock()
            return
        }
        queuedCommands.append(.stop)
        let currentRunLoop = runLoop
        commandLock.unlock()

        if let currentRunLoop,
           let defaultMode = CFRunLoopMode.defaultMode
        {
            CFRunLoopPerformBlock(currentRunLoop, defaultMode.rawValue) { [self] in
                drainCommands()
            }
            CFRunLoopWakeUp(currentRunLoop)
        }

        // This is only called by the @MainActor monitor. The AX worker never
        // waits on the main actor, so synchronously joining it cannot form a
        // main/worker cycle. Retain a defensive same-thread path for teardown.
        guard Thread.current !== workerThread else {
            drainCommands()
            return
        }
        completion.wait()
    }

    private func enqueue(_ command: Command) {
        commandLock.lock()
        queuedCommands.append(command)
        let currentRunLoop = runLoop
        commandLock.unlock()
        guard let currentRunLoop,
              let defaultMode = CFRunLoopMode.defaultMode
        else { return }
        CFRunLoopPerformBlock(currentRunLoop, defaultMode.rawValue) { [weak self] in
            self?.drainCommands()
        }
        CFRunLoopWakeUp(currentRunLoop)
    }

    private func run(completion: DispatchSemaphore) {
        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            completion.signal()
            return
        }
        commandLock.lock()
        runLoop = currentRunLoop
        commandLock.unlock()
        drainCommands()

        while !stopping {
            CFRunLoopRunInMode(.defaultMode, 1, true)
            drainCommands()
        }
        removeAllObservations(from: currentRunLoop)
        commandLock.lock()
        runLoop = nil
        thread = nil
        threadCompletion = nil
        commandLock.unlock()
        completion.signal()
    }

    private func drainCommands() {
        commandLock.lock()
        let commands = queuedCommands
        queuedCommands.removeAll(keepingCapacity: true)
        commandLock.unlock()

        for command in commands {
            switch command {
            case let .add(processIdentifier, bundleIdentifier):
                install(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier)
            case let .remove(processIdentifier):
                removeObservation(processIdentifier: processIdentifier)
            case .stop:
                stopping = true
            }
        }
    }

    private func install(processIdentifier: pid_t, bundleIdentifier: String) {
        guard observations[processIdentifier] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(processIdentifier, Self.callback, &observer) == .success,
              let observer
        else { return }

        let application = AXUIElementCreateApplication(processIdentifier)
        if Self.electronAccessibilityBundleIDs.contains(bundleIdentifier) {
            _ = AXUIElementSetAttributeValue(
                application,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var registeredNotifications: [String] = []
        for notification in [kAXSheetCreatedNotification, kAXWindowCreatedNotification] {
            let error = AXObserverAddNotification(observer, application, notification as CFString, context)
            if error == .success || error == .notificationAlreadyRegistered {
                registeredNotifications.append(notification)
            }
        }
        guard !registeredNotifications.isEmpty else { return }

        let source = AXObserverGetRunLoopSource(observer)
        guard let currentRunLoop = CFRunLoopGetCurrent() else { return }
        CFRunLoopAddSource(currentRunLoop, source, .defaultMode)
        observations[processIdentifier] = Observation(
            observer: observer,
            application: application,
            bundleIdentifier: bundleIdentifier,
            notifications: registeredNotifications
        )
    }

    private func removeObservation(processIdentifier: pid_t) {
        guard let observation = observations.removeValue(forKey: processIdentifier) else { return }
        for notification in observation.notifications {
            _ = AXObserverRemoveNotification(
                observation.observer,
                observation.application,
                notification as CFString
            )
        }
        guard let currentRunLoop = CFRunLoopGetCurrent() else { return }
        CFRunLoopRemoveSource(
            currentRunLoop,
            AXObserverGetRunLoopSource(observation.observer),
            .defaultMode
        )
    }

    private func removeAllObservations(from runLoop: CFRunLoop) {
        for observation in observations.values {
            for notification in observation.notifications {
                _ = AXObserverRemoveNotification(
                    observation.observer,
                    observation.application,
                    notification as CFString
                )
            }
            CFRunLoopRemoveSource(
                runLoop,
                AXObserverGetRunLoopSource(observation.observer),
                .defaultMode
            )
        }
        observations.removeAll()
    }

    private func received(element: AXUIElement, notification: String) {
        let processIdentifier = pid(for: element)
        guard let observation = observations[processIdentifier] else { return }
        let title = stringAttribute(kAXTitleAttribute, element: element)
            ?? stringAttribute(kAXDescriptionAttribute, element: element)
            ?? "App dialog"
        let role = stringAttribute(kAXRoleAttribute, element: element) ?? "window"
        let detail = "\(role) · \(notification)"

        let now = Date()
        recentSignals = recentSignals.filter { now.timeIntervalSince($0.value) < 2 }
        let duplicateKey = "\(processIdentifier)\u{1f}\(title)\u{1f}\(role)"
        guard recentSignals[duplicateKey] == nil else { return }
        recentSignals[duplicateKey] = now

        let nonce = UUID().uuidString.lowercased()
        let signal = SignalEnvelope(
            id: SignalID(rawValue: "ax-dialog:\(processIdentifier):\(nonce)"),
            source: .accessibilityDialog,
            receivedAt: now,
            expiresAt: now.addingTimeInterval(2 * 60),
            payload: .attention(
                AttentionSignal(
                    applicationIdentifier: observation.bundleIdentifier,
                    title: String(title.prefix(1_024)),
                    detail: String(detail.prefix(1_024))
                )
            )
        )
        Task { [signalBus] in _ = await signalBus.publish(signal) }
    }

    private func pid(for element: AXUIElement) -> pid_t {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        return processIdentifier
    }

    private func stringAttribute(_ attribute: String, element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let string = value as? String,
              !string.isEmpty
        else { return nil }
        return string
    }

    private static let electronAccessibilityBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "com.hnc.Discord",
    ]
}
