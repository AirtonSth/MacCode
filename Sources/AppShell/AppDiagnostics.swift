import Foundation
import Darwin
import AgentRuntime
import AppLifecycleSupport
import CoreModel
import Surfaces
import os

private let appDiagnosticsLog = Logger(subsystem: "io.remotecode.app", category: "diagnostics")

public struct ManagedProcessMemoryProfile: Sendable, Equatable {
    public let name: String
    public let physicalMemoryBytes: UInt64
    /// Reserved for telemetry only. Production admission never enforces a
    /// session count — the user decides how many concurrent agents to run.
    public let providerRootCap: Int?
    public let sidecarMaxConcurrentRequests: Int
    public let sidecarMaxQueueDepth: Int
    /// How long a Distill request may wait for an admission slot before the
    /// sidecar fails open (`queue_full` → client keeps original tool output).
    /// 0 means wait until the hard queue depth rejects. Multi-thread bursts
    /// need a finite budget so 4s MLX generations do not stack unbounded.
    public let sidecarMaxQueueWaitMilliseconds: Int
    public let idleReleaseAge: TimeInterval
    public let warningFraction: Double
    public let criticalFraction: Double
    /// Reserved for telemetry only. Never used to refuse a user-started provider.
    public let hostProcessCeilingKB: Int?
    /// Reserved for telemetry only. Never used to refuse a user-started provider.
    public let managedTreeCeilingKB: Int?

    public init(
        name: String,
        physicalMemoryBytes: UInt64,
        providerRootCap: Int?,
        sidecarMaxConcurrentRequests: Int,
        sidecarMaxQueueDepth: Int,
        sidecarMaxQueueWaitMilliseconds: Int = 0,
        idleReleaseAge: TimeInterval,
        warningFraction: Double,
        criticalFraction: Double,
        hostProcessCeilingKB: Int?,
        managedTreeCeilingKB: Int?
    ) {
        self.name = name
        self.physicalMemoryBytes = physicalMemoryBytes
        self.providerRootCap = providerRootCap
        self.sidecarMaxConcurrentRequests = max(1, sidecarMaxConcurrentRequests)
        self.sidecarMaxQueueDepth = max(0, sidecarMaxQueueDepth)
        self.sidecarMaxQueueWaitMilliseconds = max(0, sidecarMaxQueueWaitMilliseconds)
        self.idleReleaseAge = idleReleaseAge
        self.warningFraction = warningFraction
        self.criticalFraction = criticalFraction
        self.hostProcessCeilingKB = hostProcessCeilingKB
        self.managedTreeCeilingKB = managedTreeCeilingKB
    }

    /// Scale Distill admission from installed RAM.
    ///
    /// Concurrent slots grow with memory because each in-flight MLX generation
    /// retains working set; queue depth is deliberately modest so multi-thread
    /// agents fail open instead of stacking multi-second waits. Provider starts
    /// stay unlimited (user-controlled).
    public static func resolve(physicalMemoryBytes: UInt64) -> Self {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        if physicalMemoryBytes <= 8 * gib {
            return Self(
                name: "low-memory-8g",
                physicalMemoryBytes: physicalMemoryBytes,
                providerRootCap: nil,
                sidecarMaxConcurrentRequests: 1,
                sidecarMaxQueueDepth: 4,
                // Fail open quickly on tiny machines — one slow MLX call is enough.
                sidecarMaxQueueWaitMilliseconds: 750,
                idleReleaseAge: 60,
                warningFraction: 0.60,
                criticalFraction: 0.75,
                hostProcessCeilingKB: nil,
                managedTreeCeilingKB: nil
            )
        }
        if physicalMemoryBytes <= 16 * gib {
            return Self(
                name: "mid-memory-16g",
                physicalMemoryBytes: physicalMemoryBytes,
                providerRootCap: nil,
                sidecarMaxConcurrentRequests: 2,
                sidecarMaxQueueDepth: 8,
                sidecarMaxQueueWaitMilliseconds: 1_000,
                idleReleaseAge: 90,
                warningFraction: 0.65,
                criticalFraction: 0.80,
                hostProcessCeilingKB: nil,
                managedTreeCeilingKB: nil
            )
        }
        if physicalMemoryBytes <= 32 * gib {
            return Self(
                name: "standard-32g",
                physicalMemoryBytes: physicalMemoryBytes,
                providerRootCap: nil,
                sidecarMaxConcurrentRequests: 4,
                sidecarMaxQueueDepth: 16,
                sidecarMaxQueueWaitMilliseconds: 1_500,
                idleReleaseAge: 2 * 60,
                warningFraction: 0.70,
                criticalFraction: 0.85,
                hostProcessCeilingKB: nil,
                managedTreeCeilingKB: nil
            )
        }
        if physicalMemoryBytes <= 64 * gib {
            return Self(
                name: "high-memory-64g",
                physicalMemoryBytes: physicalMemoryBytes,
                providerRootCap: nil,
                sidecarMaxConcurrentRequests: 6,
                sidecarMaxQueueDepth: 24,
                sidecarMaxQueueWaitMilliseconds: 2_000,
                idleReleaseAge: 2 * 60,
                warningFraction: 0.72,
                criticalFraction: 0.88,
                hostProcessCeilingKB: nil,
                managedTreeCeilingKB: nil
            )
        }
        // 128 GiB+ workstation class. Concurrent still capped — MLX/GPU serializes
        // generations, and unbounded parallel LLM compress thrash the GPU more
        // than they help multi-thread agents.
        return Self(
            name: "high-memory-128g",
            physicalMemoryBytes: physicalMemoryBytes,
            providerRootCap: nil,
            sidecarMaxConcurrentRequests: 8,
            sidecarMaxQueueDepth: 32,
            sidecarMaxQueueWaitMilliseconds: 2_500,
            idleReleaseAge: 2 * 60,
            warningFraction: 0.75,
            criticalFraction: 0.90,
            hostProcessCeilingKB: nil,
            managedTreeCeilingKB: nil
        )
    }
}

public enum ManagedProviderAdmissionDecision: Sendable, Equatable {
    case admit
    case blockedIncompleteScan
    case blockedUnknownMemory
    case blockedAtProviderCap(limit: Int)
    case blockedAtHostMemoryCeiling(limitKB: Int, measuredKB: Int)
    case blockedAtManagedTreeMemoryCeiling(limitKB: Int, measuredKB: Int)

    var telemetryReason: String {
        switch self {
        case .admit: "admit"
        case .blockedIncompleteScan: "blocked_incomplete_scan"
        case .blockedUnknownMemory: "blocked_unknown_memory"
        case .blockedAtProviderCap: "blocked_provider_cap"
        case .blockedAtHostMemoryCeiling: "blocked_host_memory_ceiling"
        case .blockedAtManagedTreeMemoryCeiling: "blocked_managed_tree_memory_ceiling"
        }
    }
}

public enum ManagedProviderAdmissionError: Error, LocalizedError, Sendable, Equatable {
    case processAccountingUnavailable
    case providerLimitReached(Int)
    case hostMemoryLimitReached(Int)
    case managedTreeMemoryLimitReached(Int)

    public var errorDescription: String? {
        switch self {
        case .processAccountingUnavailable:
            return "A new provider could not start because managed-process accounting is incomplete. Try again after the next diagnostics scan."
        case .providerLimitReached(let limit):
            return "This Mac is already running the safe limit of \(limit) managed provider sessions. Finish or release an idle session, then try again."
        case .hostMemoryLimitReached(let limitKB):
            return "A new provider could not start because RemoteCode reached its low-memory host limit of \(limitKB / 1_024) MiB. Finish or release an idle session, then try again."
        case .managedTreeMemoryLimitReached(let limitKB):
            return "A new provider could not start because managed runtimes reached their low-memory limit of \(limitKB / 1_024) MiB. Finish or release an idle session, then try again."
        }
    }
}

public enum ManagedProviderAdmissionPolicy {
    /// Provider starts are user-controlled. Resource ceilings, session counts,
    /// incomplete process scans, and unknown memory samples must never refuse a
    /// start — they remain available only as telemetry enums for diagnostics.
    public static func decide(
        profile: ManagedProcessMemoryProfile,
        scanComplete: Bool,
        appFootprintKB: Int?,
        managedTreeRSSKB: Int?,
        liveProviderRoots: Int,
        requiresNewProviderRoot: Bool
    ) -> ManagedProviderAdmissionDecision {
        _ = profile
        _ = scanComplete
        _ = appFootprintKB
        _ = managedTreeRSSKB
        _ = liveProviderRoots
        _ = requiresNewProviderRoot
        return .admit
    }
}

public struct ManagedProviderAdmissionKey: Hashable, Sendable {
    public let provider: AgentProvider
    public let threadId: AgentThreadID

    public init(provider: AgentProvider, threadId: AgentThreadID) {
        self.provider = provider
        self.threadId = threadId
    }
}

public actor ManagedProviderAdmissionGate {
    private var pendingAdmissionDates: [ManagedProviderAdmissionKey: Date] = [:]
    private var residentRootByKey: [ManagedProviderAdmissionKey: pid_t] = [:]
    private var lastProviderRootPIDs: Set<pid_t> = []
    private let reservationLifetime: TimeInterval

    public init(reservationLifetime: TimeInterval = 60) {
        self.reservationLifetime = max(1, reservationLifetime)
    }

    public func decide(
        profile: ManagedProcessMemoryProfile,
        scan: ManagedProcessScan,
        appFootprintKB: Int?,
        key: ManagedProviderAdmissionKey,
        now: Date = Date()
    ) -> ManagedProviderAdmissionDecision {
        pendingAdmissionDates = pendingAdmissionDates.filter {
            now.timeIntervalSince($0.value) < reservationLifetime
        }
        let currentRootPIDs = Set(scan.providerProcesses.compactMap(\.pgid).filter { $0 > 0 })
        residentRootByKey = residentRootByKey.filter { currentRootPIDs.contains($0.value) }
        let appearedRootPIDs = currentRootPIDs.subtracting(lastProviderRootPIDs).sorted()
        let pendingKeys = pendingAdmissionDates.sorted {
            if $0.value == $1.value {
                return $0.key.threadId.value.uuidString < $1.key.threadId.value.uuidString
            }
            return $0.value < $1.value
        }.map(\.key)
        for (pendingKey, rootPID) in zip(pendingKeys, appearedRootPIDs) {
            residentRootByKey[pendingKey] = rootPID
            pendingAdmissionDates.removeValue(forKey: pendingKey)
        }
        lastProviderRootPIDs = currentRootPIDs

        let alreadyOwnsRootOrReservation = residentRootByKey[key] != nil
            || pendingAdmissionDates[key] != nil
        let effectiveRoots = scan.providerRootCount + pendingAdmissionDates.count
        let decision = ManagedProviderAdmissionPolicy.decide(
            profile: profile,
            scanComplete: scan.isComplete,
            appFootprintKB: appFootprintKB,
            managedTreeRSSKB: Self.totalManagedRSSKB(appFootprintKB: appFootprintKB, scan: scan),
            liveProviderRoots: effectiveRoots,
            requiresNewProviderRoot: !alreadyOwnsRootOrReservation
        )
        if decision == .admit, !alreadyOwnsRootOrReservation {
            pendingAdmissionDates[key] = now
        }
        return decision
    }

    private static func totalManagedRSSKB(
        appFootprintKB: Int?,
        scan: ManagedProcessScan
    ) -> Int? {
        guard scan.isComplete, let appFootprintKB, appFootprintKB >= 0 else { return nil }
        let values = [appFootprintKB]
            + scan.providerProcesses.map(\.rssKB)
            + scan.sidecarProcesses.map(\.rssKB)
        var total = 0
        for value in values {
            guard value >= 0 else { return nil }
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }
}

public enum ManagedMemoryPressureDecision: String, Sendable, Equatable {
    case unknown
    case normal
    case warning
    case critical
}

enum AppDiagnostics {
    struct SurfaceSnapshot: Sendable {
        let surfaceCount: Int
        let terminalCount: Int
        let runningTerminals: Int
        let pendingBytes: Int
        let droppedBytes: Int
        let historyFailures: Int
    }

    struct ProviderStats: Sendable, Equatable {
        let processCount: Int
        let totalRSSKB: Int
        let orphanCount: Int
    }

    struct ManagedAggregateSample: Sendable, Equatable {
        let appFootprintKB: Int?
        let providerProcessCount: Int?
        let providerRootCount: Int?
        let providerRSSKB: Int?
        let sidecarProcessCount: Int?
        let sidecarRootCount: Int?
        let sidecarRSSKB: Int?
        let totalManagedRSSKB: Int?
        let previousTotalManagedRSSKB: Int?
        let sampleIntervalSeconds: TimeInterval?
        let deltaManagedRSSKB: Int?
        let slopeKBPerMinute: Double?
        let highWaterManagedRSSKB: Int?
        let isComplete: Bool
        let pressureDecision: ManagedMemoryPressureDecision
        let admissionDecision: ManagedProviderAdmissionDecision
        let profile: ManagedProcessMemoryProfile
    }

    struct ManagedTrendState: Sendable, Equatable {
        private(set) var previousTotalManagedRSSKB: Int?
        private(set) var previousDate: Date?
        private(set) var highWaterManagedRSSKB: Int?

        mutating func record(
            appFootprintKB: Int?,
            scan: ManagedProcessScan?,
            profile: ManagedProcessMemoryProfile,
            now: Date
        ) -> ManagedAggregateSample {
            let interval = previousDate.map { now.timeIntervalSince($0) }
            let sample = aggregateManagedSample(
                appFootprintKB: appFootprintKB,
                scan: scan,
                profile: profile,
                previousTotalManagedRSSKB: previousTotalManagedRSSKB,
                sampleIntervalSeconds: interval,
                previousHighWaterManagedRSSKB: highWaterManagedRSSKB
            )
            if let total = sample.totalManagedRSSKB {
                previousTotalManagedRSSKB = total
                previousDate = now
                highWaterManagedRSSKB = sample.highWaterManagedRSSKB
            }
            return sample
        }
    }

    @MainActor
    static func aggregateSurfaceSnapshot(_ surfaces: [any Surface]) -> SurfaceSnapshot {
        let terminalHealth = surfaces.compactMap {
            ($0 as? TerminalRuntimeRoutingSurface)?.routedRuntimeHealth()
        }
        return SurfaceSnapshot(
            surfaceCount: surfaces.count,
            terminalCount: terminalHealth.count,
            runningTerminals: terminalHealth.filter(\.processAlive).count,
            pendingBytes: terminalHealth.reduce(0) { $0 + $1.outputPendingBytes },
            droppedBytes: terminalHealth.reduce(0) { $0 + $1.droppedOutputBytes },
            historyFailures: terminalHealth.reduce(0) { $0 + $1.historyWriteFailures }
        )
    }

    nonisolated static func aggregateProviderStats(
        processes: [ProviderRuntimeProcess]
    ) -> ProviderStats {
        ProviderStats(
            processCount: processes.count,
            totalRSSKB: processes.reduce(0) { $0 + $1.rssKB },
            orphanCount: processes.filter { $0.ppid == 1 }.count
        )
    }

    nonisolated static func providerAdmissionDecision(
        profile: ManagedProcessMemoryProfile,
        scanComplete: Bool,
        appFootprintKB: Int?,
        managedTreeRSSKB: Int?,
        liveProviderRoots: Int,
        requiresNewProviderRoot: Bool = true
    ) -> ManagedProviderAdmissionDecision {
        ManagedProviderAdmissionPolicy.decide(
            profile: profile,
            scanComplete: scanComplete,
            appFootprintKB: appFootprintKB,
            managedTreeRSSKB: managedTreeRSSKB,
            liveProviderRoots: liveProviderRoots,
            requiresNewProviderRoot: requiresNewProviderRoot
        )
    }

    nonisolated static func aggregateManagedSample(
        appFootprintKB: Int?,
        scan: ManagedProcessScan?,
        profile: ManagedProcessMemoryProfile,
        previousTotalManagedRSSKB: Int? = nil,
        sampleIntervalSeconds: TimeInterval? = nil,
        previousHighWaterManagedRSSKB: Int? = nil
    ) -> ManagedAggregateSample {
        let validApp = appFootprintKB.flatMap { $0 >= 0 ? $0 : nil }
        let complete = validApp != nil && scan?.isComplete == true
        guard complete, let validApp, let scan else {
            return ManagedAggregateSample(
                appFootprintKB: validApp,
                providerProcessCount: nil,
                providerRootCount: nil,
                providerRSSKB: nil,
                sidecarProcessCount: nil,
                sidecarRootCount: nil,
                sidecarRSSKB: nil,
                totalManagedRSSKB: nil,
                previousTotalManagedRSSKB: previousTotalManagedRSSKB,
                sampleIntervalSeconds: sampleIntervalSeconds,
                deltaManagedRSSKB: nil,
                slopeKBPerMinute: nil,
                highWaterManagedRSSKB: previousHighWaterManagedRSSKB,
                isComplete: false,
                pressureDecision: .unknown,
                admissionDecision: ManagedProviderAdmissionPolicy.decide(
                    profile: profile,
                    scanComplete: scan?.isComplete == true,
                    appFootprintKB: validApp,
                    managedTreeRSSKB: nil,
                    liveProviderRoots: scan?.providerRootCount ?? 0,
                    requiresNewProviderRoot: true
                ),
                profile: profile
            )
        }

        let providerStats = aggregateProviderStats(processes: scan.providerProcesses)
        let sidecarStats = aggregateProviderStats(processes: scan.sidecarProcesses)
        let total = validApp + providerStats.totalRSSKB + sidecarStats.totalRSSKB
        let delta = previousTotalManagedRSSKB.map { total - $0 }
        let slope = delta.flatMap { delta -> Double? in
            guard let sampleIntervalSeconds, sampleIntervalSeconds > 0 else { return nil }
            return Double(delta) * 60 / sampleIntervalSeconds
        }
        let highWater = max(previousHighWaterManagedRSSKB ?? total, total)
        let physicalKB = Double(profile.physicalMemoryBytes) / 1_024
        let fraction = physicalKB > 0 ? Double(total) / physicalKB : 0
        let pressure: ManagedMemoryPressureDecision
        if fraction >= profile.criticalFraction {
            pressure = .critical
        } else if fraction >= profile.warningFraction {
            pressure = .warning
        } else {
            pressure = .normal
        }
        return ManagedAggregateSample(
            appFootprintKB: validApp,
            providerProcessCount: providerStats.processCount,
            providerRootCount: scan.providerRootCount,
            providerRSSKB: providerStats.totalRSSKB,
            sidecarProcessCount: sidecarStats.processCount,
            sidecarRootCount: scan.sidecarRootCount,
            sidecarRSSKB: sidecarStats.totalRSSKB,
            totalManagedRSSKB: total,
            previousTotalManagedRSSKB: previousTotalManagedRSSKB,
            sampleIntervalSeconds: sampleIntervalSeconds,
            deltaManagedRSSKB: delta,
            slopeKBPerMinute: slope,
            highWaterManagedRSSKB: highWater,
            isComplete: true,
            pressureDecision: pressure,
            admissionDecision: ManagedProviderAdmissionPolicy.decide(
                profile: profile,
                scanComplete: true,
                appFootprintKB: validApp,
                managedTreeRSSKB: total,
                liveProviderRoots: scan.providerRootCount,
                requiresNewProviderRoot: true
            ),
            profile: profile
        )
    }

    @MainActor private static var providerScanInFlight = false
    @MainActor private static var managedTrendState = ManagedTrendState()

    enum ProviderScanDecision: Equatable {
        case start
        case skipInFlight
    }

    @MainActor static func beginProviderScanForTests() -> ProviderScanDecision { beginProviderScan() }
    @MainActor static func finishProviderScanForTests() { finishProviderScan() }

    @MainActor
    private static func beginProviderScan() -> ProviderScanDecision {
        guard !providerScanInFlight else { return .skipInFlight }
        providerScanInFlight = true
        return .start
    }

    @MainActor private static func finishProviderScan() { providerScanInFlight = false }

    @MainActor
    static func heartbeat(
        reason: String,
        activeAgentThreads: Int,
        profile: ManagedProcessMemoryProfile,
        lifecycleRecorder: AppLifecycleRecorder? = nil
    ) {
        let snapshot = aggregateSurfaceSnapshot(SurfaceRegistry.shared.all())
        let footprint = currentProcessFootprintKB()
        let appFootprint = footprint >= 0 ? footprint : nil
        let pid = ProcessInfo.processInfo.processIdentifier

        guard beginProviderScan() == .start else {
            let sample = managedTrendState.record(
                appFootprintKB: appFootprint,
                scan: nil,
                profile: profile,
                now: Date()
            )
            logHeartbeat(
                reason: reason,
                pid: pid,
                activeAgentThreads: activeAgentThreads,
                surface: snapshot,
                sample: sample,
                scanState: "skipped_in_flight"
            )
            return
        }

        Task.detached(priority: .utility) {
            let scan: ManagedProcessScan?
            let scanState: String
            do {
                guard let store = ProviderProcessOwnership.shared.store() else {
                    throw ProviderProcessOwnershipError.storeNotConfigured
                }
                scan = try ProviderProcessSweeper.managedProcessScan(store: store)
                scanState = scan?.isComplete == true ? "complete" : "incomplete_ownership"
            } catch {
                scan = nil
                scanState = "failed"
            }
            await MainActor.run {
                finishProviderScan()
                let sample = managedTrendState.record(
                    appFootprintKB: appFootprint,
                    scan: scan,
                    profile: profile,
                    now: Date()
                )
                logHeartbeat(
                    reason: reason,
                    pid: pid,
                    activeAgentThreads: activeAgentThreads,
                    surface: snapshot,
                    sample: sample,
                    scanState: scanState
                )
                if sample.isComplete,
                   let providerProcesses = sample.providerProcessCount,
                   let providerRSSKB = sample.providerRSSKB,
                   let sidecarProcesses = sample.sidecarProcessCount,
                   let sidecarRSSKB = sample.sidecarRSSKB {
                    lifecycleRecorder?.recordHeartbeat(
                        reason: reason,
                        providerProcesses: providerProcesses,
                        providerRSSKB: providerRSSKB,
                        orphanProviders: scan.map { aggregateProviderStats(processes: $0.providerProcesses).orphanCount } ?? 0,
                        sidecarProcesses: sidecarProcesses,
                        sidecarRSSKB: sidecarRSSKB,
                        orphanSidecars: scan.map { aggregateProviderStats(processes: $0.sidecarProcesses).orphanCount } ?? 0
                    )
                }
            }
        }
    }

    @MainActor
    private static func logHeartbeat(
        reason: String,
        pid: Int32,
        activeAgentThreads: Int,
        surface: SurfaceSnapshot,
        sample: ManagedAggregateSample,
        scanState: String
    ) {
        let value: (Int?) -> String = { $0.map(String.init) ?? "unavailable" }
        let doubleValue: (Double?) -> String = { $0.map { String(format: "%.2f", $0) } ?? "unavailable" }
        appDiagnosticsLog.info(
            "app.heartbeat reason=\(reason, privacy: .public) pid=\(pid, privacy: .public) managedScan=\(scanState, privacy: .public) complete=\(sample.isComplete, privacy: .public) appRSSKB=\(value(sample.appFootprintKB), privacy: .public) providerProcesses=\(value(sample.providerProcessCount), privacy: .public) providerRoots=\(value(sample.providerRootCount), privacy: .public) providerRSSKB=\(value(sample.providerRSSKB), privacy: .public) sidecarProcesses=\(value(sample.sidecarProcessCount), privacy: .public) sidecarRoots=\(value(sample.sidecarRootCount), privacy: .public) sidecarRSSKB=\(value(sample.sidecarRSSKB), privacy: .public) totalManagedRSSKB=\(value(sample.totalManagedRSSKB), privacy: .public) previousManagedRSSKB=\(value(sample.previousTotalManagedRSSKB), privacy: .public) sampleIntervalSeconds=\(doubleValue(sample.sampleIntervalSeconds), privacy: .public) deltaManagedRSSKB=\(value(sample.deltaManagedRSSKB), privacy: .public) slopeKBPerMinute=\(doubleValue(sample.slopeKBPerMinute), privacy: .public) highWaterManagedRSSKB=\(value(sample.highWaterManagedRSSKB), privacy: .public) memoryProfile=\(sample.profile.name, privacy: .public) physicalMemoryBytes=\(sample.profile.physicalMemoryBytes, privacy: .public) providerRootCap=\(value(sample.profile.providerRootCap), privacy: .public) hostProcessCeilingKB=\(value(sample.profile.hostProcessCeilingKB), privacy: .public) managedTreeCeilingKB=\(value(sample.profile.managedTreeCeilingKB), privacy: .public) admission=\(sample.admissionDecision.telemetryReason, privacy: .public) sidecarRequestCap=\(sample.profile.sidecarMaxConcurrentRequests, privacy: .public) sidecarQueueCap=\(sample.profile.sidecarMaxQueueDepth, privacy: .public) ownershipLedgerCap=\(ProviderProcessOwnershipStore.defaultMaxRecords, privacy: .public) pressure=\(sample.pressureDecision.rawValue, privacy: .public) surfaces=\(surface.surfaceCount, privacy: .public) terminals=\(surface.terminalCount, privacy: .public) runningTerminals=\(surface.runningTerminals, privacy: .public) activeAgentThreads=\(activeAgentThreads, privacy: .public) terminalPendingBytes=\(surface.pendingBytes, privacy: .public) terminalDroppedBytes=\(surface.droppedBytes, privacy: .public) terminalHistoryFailures=\(surface.historyFailures, privacy: .public)"
        )
    }

    static func currentProcessFootprintKB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1_024)
    }
}
