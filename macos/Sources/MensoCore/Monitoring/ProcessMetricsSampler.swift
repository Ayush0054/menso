@preconcurrency import AppKit
import ApplicationServices
import Darwin
import Foundation

public actor ProcessMetricsSampler {
    private struct CPUSample: Sendable {
        let rawCPUTime: UInt64
        let sampledAt: ContinuousClock.Instant
    }

    private struct Totals {
        var rawCPUTime: UInt64 = 0
        var physicalFootprint: UInt64 = 0
        var processCount: Int = 0
    }

    private let clock = ContinuousClock()
    private let responsibilityResolver = ProcessResponsibilityResolver()
    private let timeConverter = MachTimeConverter()
    private var previousSamples: [Int32: CPUSample] = [:]

    public init() {}

    public func sample(applications: [MonitoredApplicationSeed]) -> [ApplicationSnapshot] {
        let roots = Set(applications.map(\.processIdentifier))
        var totalsByRoot: [Int32: Totals] = [:]

        for processIdentifier in ProcessInspector.allProcessIdentifiers() {
            guard ProcessInspector.isOwnedByCurrentUser(processIdentifier) else { continue }
            guard let root = responsibilityResolver.rootProcess(
                for: processIdentifier,
                among: roots
            ) else { continue }

            var totals = totalsByRoot[root, default: Totals()]
            if let task = ProcessInspector.taskInfo(processIdentifier) {
                totals.rawCPUTime &+= task.user &+ task.system
            }
            if let footprint = ProcessInspector.physicalFootprint(processIdentifier) {
                totals.physicalFootprint &+= footprint
            }
            totals.processCount += 1
            totalsByRoot[root] = totals
        }

        let now = clock.now
        let activeRoots = Set(totalsByRoot.keys)
        previousSamples = previousSamples.filter { activeRoots.contains($0.key) }

        return applications.map { application in
            let totals = totalsByRoot[application.processIdentifier, default: Totals()]
            let cpuPercent = cpuPercent(
                processIdentifier: application.processIdentifier,
                rawCPUTime: totals.rawCPUTime,
                sampledAt: now
            )
            let title = application.isActive
                ? FrontmostWindowTitleReader.title(processIdentifier: application.processIdentifier)
                : nil

            return ApplicationSnapshot(
                seed: application,
                cpuPercent: cpuPercent,
                physicalFootprintBytes: totals.processCount > 0 ? totals.physicalFootprint : nil,
                groupedProcessCount: totals.processCount,
                frontmostWindowTitle: title
            )
        }
    }

    private func cpuPercent(
        processIdentifier: Int32,
        rawCPUTime: UInt64,
        sampledAt: ContinuousClock.Instant
    ) -> Double? {
        defer {
            previousSamples[processIdentifier] = CPUSample(
                rawCPUTime: rawCPUTime,
                sampledAt: sampledAt
            )
        }
        guard let previous = previousSamples[processIdentifier] else { return nil }
        guard rawCPUTime >= previous.rawCPUTime else { return nil }

        let elapsed = previous.sampledAt.duration(to: sampledAt)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard elapsedSeconds > 0 else { return nil }

        let cpuSeconds = timeConverter.seconds(fromMachUnits: rawCPUTime - previous.rawCPUTime)
        let maximum = Double(max(1, ProcessInfo.processInfo.processorCount)) * 100
        return min(max(cpuSeconds / elapsedSeconds * 100, 0), maximum)
    }
}

private struct MachTimeConverter: Sendable {
    private let numerator: Double
    private let denominator: Double

    init() {
        var information = mach_timebase_info_data_t()
        if mach_timebase_info(&information) == KERN_SUCCESS, information.denom != 0 {
            numerator = Double(information.numer)
            denominator = Double(information.denom)
        } else {
            numerator = 1
            denominator = 1
        }
    }

    func seconds(fromMachUnits value: UInt64) -> Double {
        Double(value) * numerator / denominator / 1_000_000_000
    }
}

private enum ProcessInspector {
    struct TaskTimes {
        let user: UInt64
        let system: UInt64
    }

    static func allProcessIdentifiers() -> [Int32] {
        let count = Int(proc_listallpids(nil, 0))
        guard count > 0 else { return [] }
        var processIdentifiers = [Int32](repeating: 0, count: count)
        let bytes = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }
        return processIdentifiers.prefix(Int(bytes)).filter { $0 > 0 }
    }

    static func isOwnedByCurrentUser(_ processIdentifier: Int32) -> Bool {
        guard let information = bsdInfo(processIdentifier) else { return false }
        return information.pbi_uid == geteuid()
    }

    static func parentProcessIdentifier(_ processIdentifier: Int32) -> Int32? {
        bsdInfo(processIdentifier).map { Int32($0.pbi_ppid) }
    }

    static func taskInfo(_ processIdentifier: Int32) -> TaskTimes? {
        var information = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let bytes = proc_pidinfo(
            processIdentifier,
            PROC_PIDTASKINFO,
            0,
            &information,
            size
        )
        guard bytes == size else { return nil }
        return TaskTimes(
            user: information.pti_total_user,
            system: information.pti_total_system
        )
    }

    static func physicalFootprint(_ processIdentifier: Int32) -> UInt64? {
        var information = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processIdentifier, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return information.ri_phys_footprint
    }

    private static func bsdInfo(_ processIdentifier: Int32) -> proc_bsdinfo? {
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let bytes = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &information,
            size
        )
        return bytes == size ? information : nil
    }
}

private final class ProcessResponsibilityResolver: @unchecked Sendable {
    private typealias ResponsibilityFunction = @convention(c) (Int32) -> Int32

    private let imageHandle: UnsafeMutableRawPointer?
    private let responsibilityFunction: ResponsibilityFunction?

    init() {
        imageHandle = dlopen(nil, RTLD_LAZY)
        if let imageHandle, let symbol = dlsym(imageHandle, "responsibility_get_pid_responsible_for_pid") {
            responsibilityFunction = unsafeBitCast(symbol, to: ResponsibilityFunction.self)
        } else {
            responsibilityFunction = nil
        }
    }

    deinit {
        if let imageHandle {
            dlclose(imageHandle)
        }
    }

    func rootProcess(for processIdentifier: Int32, among roots: Set<Int32>) -> Int32? {
        if roots.contains(processIdentifier) {
            return processIdentifier
        }
        if let responsibilityFunction {
            let responsible = responsibilityFunction(processIdentifier)
            if roots.contains(responsible) {
                return responsible
            }
        }

        var visited = Set<Int32>()
        var current = processIdentifier
        for _ in 0..<12 {
            guard visited.insert(current).inserted else { break }
            guard let parent = ProcessInspector.parentProcessIdentifier(current), parent > 1 else {
                break
            }
            if roots.contains(parent) {
                return parent
            }
            current = parent
        }
        return nil
    }
}

private enum FrontmostWindowTitleReader {
    static func title(processIdentifier: Int32) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else { return nil }

        let focusedWindow = unsafeDowncast(focusedValue as AnyObject, to: AXUIElement.self)
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedWindow,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success else { return nil }
        return titleValue as? String
    }
}
