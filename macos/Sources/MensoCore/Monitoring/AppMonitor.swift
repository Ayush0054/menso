@preconcurrency import AppKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
public final class AppMonitor {
    public private(set) var state = AppMonitorState()
    public var includesAccessoryApplications = true {
        didSet { refreshRunningApplications() }
    }
    public var includesBackgroundApplications = false {
        didSet { refreshRunningApplications() }
    }

    private let workspace: NSWorkspace
    private let sampler: ProcessMetricsSampler
    private var timer: DispatchSourceTimer?
    private var observation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var seeds: [MonitoredApplicationSeed] = []
    private var sampleTask: Task<Void, Never>?
    private var panelIsExpanded = false
    private var screenIsSleeping = false
    private var started = false

    public init(
        workspace: NSWorkspace = .shared,
        sampler: ProcessMetricsSampler = ProcessMetricsSampler()
    ) {
        self.workspace = workspace
        self.sampler = sampler
    }

    isolated deinit {
        timer?.cancel()
        observation?.invalidate()
        for token in notificationTokens {
            workspace.notificationCenter.removeObserver(token)
        }
    }

    public func start() {
        guard !started else { return }
        started = true

        observation = workspace.observe(\.runningApplications, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshRunningApplications()
            }
        }

        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            notificationTokens.append(
                workspace.notificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshRunningApplications()
                    }
                }
            )
        }

        notificationTokens.append(
            workspace.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.screenIsSleeping = true
                    self?.state.isSamplingPaused = true
                }
            }
        )
        notificationTokens.append(
            workspace.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.screenIsSleeping = false
                    self?.state.isSamplingPaused = false
                    self?.scheduleSample()
                }
            }
        )

        refreshRunningApplications()
        configureTimer()
    }

    public func stop() {
        started = false
        timer?.cancel()
        timer = nil
        sampleTask?.cancel()
        sampleTask = nil
        observation?.invalidate()
        observation = nil
        for token in notificationTokens {
            workspace.notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    public func setPanelExpanded(_ isExpanded: Bool) {
        guard panelIsExpanded != isExpanded else { return }
        panelIsExpanded = isExpanded
        configureTimer()
    }

    private func refreshRunningApplications() {
        seeds = workspace.runningApplications.compactMap { application in
            guard application.processIdentifier > 0 else { return nil }
            let kind = ApplicationKind(activationPolicy: application.activationPolicy)
            guard kind == .regular
                || (kind == .accessory && includesAccessoryApplications)
                || (kind == .background && includesBackgroundApplications)
            else { return nil }

            return MonitoredApplicationSeed(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName ?? application.bundleIdentifier ?? "Process \(application.processIdentifier)",
                executableURL: application.executableURL,
                kind: kind,
                isActive: application.isActive
            )
        }
        .sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending
        }
        scheduleSample()
    }

    private func configureTimer() {
        timer?.cancel()
        // The event handler is created in this @MainActor type, so dispatch it
        // on the main queue. Sampling itself remains asynchronous below.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval: DispatchTimeInterval = panelIsExpanded ? .seconds(2) : .seconds(8)
        timer.schedule(
            deadline: .now(),
            repeating: interval,
            leeway: panelIsExpanded ? .milliseconds(250) : .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleSample()
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func scheduleSample() {
        guard !screenIsSleeping else { return }
        guard sampleTask == nil else { return }

        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .null
        )
        state.secondsSinceUserInput = idleSeconds

        let pauseForLongIdle = !panelIsExpanded && idleSeconds >= 5 * 60
        state.isSamplingPaused = pauseForLongIdle
        guard !pauseForLongIdle else { return }

        let seeds = seeds
        sampleTask = Task { [weak self, sampler] in
            let applications = await sampler.sample(applications: seeds)
            guard !Task.isCancelled else { return }
            self?.state.applications = applications.sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                return ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0)
            }
            self?.state.lastUpdatedAt = .now
            self?.sampleTask = nil
        }
    }
}
