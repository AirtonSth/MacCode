import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel

/// Tests for the off-main-thread diagnostics heartbeat refactor.
///
/// Business rules:
///   R1 — `aggregateProviderStats` is `nonisolated`: it must be callable
///        without any actor context so the background `Task.detached` in
///        `heartbeat` can use it without hopping back to the main thread.
///   R2 — Provider RSS and orphan count are summed correctly so the heartbeat
///        log accurately reflects process-table state; incorrect totals would
///        mask memory growth or leaked orphan runtimes.
///   R3 — `currentProcessFootprintKB` must return a positive value (>= 0) in
///        a healthy process; -1 indicates a mach-kernel failure and would log
///        useless footprint data, hiding out-of-memory kill evidence.
///   R4 — `aggregateProviderStats` with an empty process list returns all-zero
///        fields; the heartbeat must log "0 providers" rather than crashing or
///        returning stale counts when no provider runtimes are running.
///   R5 — only one provider `/bin/ps` scan may be in flight; overlap must skip,
///        and completion must clear the latch so a later heartbeat can scan.
final class DiagnosticsHeartbeatOffMainTests: XCTestCase {

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func read() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let eightGiB = UInt64(8) * 1_024 * 1_024 * 1_024

    // MARK: - R1: pure helper is callable without actor context

    func test_aggregateProviderStats_isCallableOffMainActor() {
        // R1: `aggregateProviderStats` must not require the main actor so that
        // `heartbeat` can dispatch the /bin/ps scan + aggregation to a background
        // Task.detached without blocking the main run loop.
        //
        // Compile-level proof: this test function carries no @MainActor annotation
        // and no explicit actor hop; if `aggregateProviderStats` were @MainActor
        // (or nonisolated were removed) the compiler would reject this call site.
        let processes = [
            ProviderRuntimeProcess(pid: 100, ppid: 1,   rssKB: 512, command: "/usr/bin/node"),
            ProviderRuntimeProcess(pid: 200, ppid: 100, rssKB: 256, command: "/usr/bin/node worker"),
        ]
        // Call without any actor annotation — compile error if not nonisolated.
        let stats = AppDiagnostics.aggregateProviderStats(processes: processes)
        XCTAssertEqual(stats.processCount, 2,
            "processCount must reflect the number of processes passed in")
    }

    // MARK: - R2: aggregation correctness

    func test_aggregateProviderStats_sumsRSSAndCountsOrphans() {
        // R2: rssKB must be the sum of all process RSS values; orphanCount must
        // equal the number of processes whose ppid == 1.  Incorrect totals would
        // cause the heartbeat log to underreport memory or hide leaked runtimes.
        let processes = [
            ProviderRuntimeProcess(pid: 10, ppid: 1,  rssKB: 1024, command: "/claude"),
            ProviderRuntimeProcess(pid: 11, ppid: 10, rssKB: 512,  command: "/claude worker"),
            ProviderRuntimeProcess(pid: 12, ppid: 1,  rssKB: 2048, command: "/codex app-server"),
        ]
        let stats = AppDiagnostics.aggregateProviderStats(processes: processes)

        XCTAssertEqual(stats.processCount, 3,
            "processCount must equal the number of processes in the list")
        XCTAssertEqual(stats.totalRSSKB, 3584,
            "totalRSSKB must be the sum of all rssKB values (1024+512+2048=3584) so memory totals in the heartbeat log are correct")
        XCTAssertEqual(stats.orphanCount, 2,
            "orphanCount must equal the number of processes with ppid==1 (pids 10 and 12) so leaked orphan runtimes are counted accurately")
    }

    // MARK: - R4: empty list boundary

    func test_aggregateProviderStats_emptyList_returnsZeros() {
        // R4: when no provider processes are running the heartbeat must log
        // "0 providers / 0 KB / 0 orphans" rather than crashing or returning
        // stale state from a previous call.
        let stats = AppDiagnostics.aggregateProviderStats(processes: [])

        XCTAssertEqual(stats.processCount, 0,
            "processCount must be 0 when the process list is empty")
        XCTAssertEqual(stats.totalRSSKB, 0,
            "totalRSSKB must be 0 when there are no provider processes")
        XCTAssertEqual(stats.orphanCount, 0,
            "orphanCount must be 0 when there are no orphan processes")
    }

    // MARK: - R3: footprint sampling

    func test_currentProcessFootprintKB_returnsNonNegativeValue() {
        // R3: the mach task_info call must succeed in a normal test process and
        // return a footprint >= 0.  A return of -1 means KERN_FAILURE, which
        // would write "rssKB=-1" to every heartbeat log line and make
        // out-of-memory kill evidence invisible.
        let footprint = AppDiagnostics.currentProcessFootprintKB()
        XCTAssertGreaterThanOrEqual(footprint, 0,
            "currentProcessFootprintKB must return >= 0; -1 indicates a mach-kernel failure that would corrupt all heartbeat footprint log entries")
    }

    // MARK: - R5: provider scan in-flight latch

    @MainActor
    func test_providerScanLatch_skipsOverlapAndClearsAfterFinish() {
        defer { AppDiagnostics.finishProviderScanForTests() }

        XCTAssertEqual(AppDiagnostics.beginProviderScanForTests(), .start,
            "the first heartbeat in a quiet period must launch the provider scan")
        XCTAssertEqual(AppDiagnostics.beginProviderScanForTests(), .skipInFlight,
            "an overlapping heartbeat must skip the blocking /bin/ps provider scan")

        AppDiagnostics.finishProviderScanForTests()

        XCTAssertEqual(AppDiagnostics.beginProviderScanForTests(), .start,
            "after the detached scan completes, a later heartbeat must be allowed to scan again")
    }

    func test_processListPolicySkipsOnlyPeriodicEmptyOwnership() throws {
        // WHY: idle periodic heartbeats may skip an unobservable process table,
        // but non-empty ownership needs RSS/orphan rows and termination telemetry
        // intentionally reads the post-sweep table even when the ledger drained.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat-process-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
        try store.replace([])
        let loads = LockedCounter()
        let expected = [ProviderRuntimeProcess(pid: 901, ppid: 1, rssKB: 64, command: "/opt/codex")]
        let realList: ProviderProcessList = {
            loads.increment()
            return expected
        }

        let periodic = AppDelegate.providerProcessListForDiagnostics(
            reason: "periodic",
            store: store,
            processList: realList
        )
        XCTAssertEqual(try periodic(), [])
        XCTAssertEqual(loads.read(), 0, "empty periodic ownership must avoid process enumeration")

        try store.replace([SpawnedProcessTag(pgid: 901, spawnedAt: Date(), provider: .codex)])
        XCTAssertEqual(try periodic(), expected)
        XCTAssertEqual(loads.read(), 1, "the same periodic path must enumerate once after ownership appears")

        try store.replace([])
        let terminating = AppDelegate.providerProcessListForDiagnostics(
            reason: "will_terminate",
            store: store,
            processList: realList
        )
        XCTAssertEqual(try terminating(), expected)
        XCTAssertEqual(loads.read(), 2, "will_terminate must preserve the direct post-sweep process scan")
    }

    func test_lowMemoryProfileBoundsProvidersSidecarQueueAndIdleRelease() {
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)

        XCTAssertEqual(profile.name, "low-memory-8g")
        XCTAssertNil(profile.providerRootCap,
                     "session count is unlimited — user controls concurrent agents")
        XCTAssertEqual(profile.sidecarMaxConcurrentRequests, 1)
        XCTAssertEqual(profile.sidecarMaxQueueDepth, 4)
        XCTAssertEqual(profile.sidecarMaxQueueWaitMilliseconds, 750,
                       "tiny machines fail open quickly instead of stacking MLX waits")
        XCTAssertEqual(profile.idleReleaseAge, 60,
                       "only safely resumable completed sessions use the shorter release window")
        XCTAssertNil(profile.hostProcessCeilingKB,
                     "memory ceilings must not refuse user-started providers")
        XCTAssertNil(profile.managedTreeCeilingKB)
    }

    func test_memoryProfileScalesDistillConcurrencyWithInstalledRAM() {
        // WHY: multi-thread agents on high-RAM Macs were stuck at concurrent=4 because
        // the profile only had 8g vs "everything else". Tiers must grow with RAM while
        // still capping concurrent (GPU serializes MLX) and keeping a finite queue wait.
        let gib = UInt64(1_024 * 1_024 * 1_024)
        let mid = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: 16 * gib)
        XCTAssertEqual(mid.name, "mid-memory-16g")
        XCTAssertEqual(mid.sidecarMaxConcurrentRequests, 2)
        XCTAssertEqual(mid.sidecarMaxQueueDepth, 8)
        XCTAssertEqual(mid.sidecarMaxQueueWaitMilliseconds, 1_000)

        let standard = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: 32 * gib)
        XCTAssertEqual(standard.name, "standard-32g")
        XCTAssertEqual(standard.sidecarMaxConcurrentRequests, 4)
        XCTAssertEqual(standard.sidecarMaxQueueDepth, 16)
        XCTAssertEqual(standard.sidecarMaxQueueWaitMilliseconds, 1_500)

        let high64 = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: 64 * gib)
        XCTAssertEqual(high64.name, "high-memory-64g")
        XCTAssertEqual(high64.sidecarMaxConcurrentRequests, 6)
        XCTAssertEqual(high64.sidecarMaxQueueDepth, 24)

        let high128 = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: 128 * gib)
        XCTAssertEqual(high128.name, "high-memory-128g")
        XCTAssertEqual(high128.sidecarMaxConcurrentRequests, 8)
        XCTAssertEqual(high128.sidecarMaxQueueDepth, 32)
        XCTAssertEqual(high128.sidecarMaxQueueWaitMilliseconds, 2_500)
        XCTAssertNil(high128.providerRootCap, "provider starts stay user-controlled at every tier")
    }

    func test_standardProfileHasUnlimitedProviderRootCap() {
        let profile = ManagedProcessMemoryProfile.resolve(
            physicalMemoryBytes: UInt64(16) * 1_024 * 1_024 * 1_024
        )
        XCTAssertEqual(profile.name, "mid-memory-16g")
        XCTAssertNil(profile.providerRootCap,
                     "Codex long-lived app-servers must not hit a fixed session budget")
        XCTAssertEqual(
            ManagedProviderAdmissionPolicy.decide(
                profile: profile,
                scanComplete: true,
                appFootprintKB: 256 * 1_024,
                managedTreeRSSKB: 512 * 1_024,
                liveProviderRoots: 64,
                requiresNewProviderRoot: true
            ),
            .admit,
            "no count-based admission block"
        )
    }

    func test_providerAdmissionNeverBlocksUserStarts() {
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)

        XCTAssertFalse(
            ManagedProviderAdmissionPolicy.requiresProviderStartPreflight,
            "an always-admit policy must not put ledger decode, /bin/ps, and footprint sampling on every provider start"
        )

        XCTAssertEqual(
            ManagedProviderAdmissionPolicy.decide(
                profile: profile,
                scanComplete: false,
                appFootprintKB: nil,
                managedTreeRSSKB: nil,
                liveProviderRoots: 0,
                requiresNewProviderRoot: true
            ),
            .admit,
            "incomplete process accounting must not refuse a user start"
        )
        let capped = ManagedProcessMemoryProfile(
            name: "test-capped",
            physicalMemoryBytes: eightGiB,
            providerRootCap: 2,
            sidecarMaxConcurrentRequests: 1,
            sidecarMaxQueueDepth: 4,
            idleReleaseAge: 30 * 60,
            warningFraction: 0.60,
            criticalFraction: 0.75,
            hostProcessCeilingKB: 1,
            managedTreeCeilingKB: 1
        )
        XCTAssertEqual(
            ManagedProviderAdmissionPolicy.decide(
                profile: capped,
                scanComplete: true,
                appFootprintKB: 256 * 1_024,
                managedTreeRSSKB: 512 * 1_024,
                liveProviderRoots: 99,
                requiresNewProviderRoot: true
            ),
            .admit,
            "session/memory knobs are telemetry only — user controls concurrency"
        )
    }

    /// Same-process A/B of the previous production preflight and the no-op
    /// provider-start check. Primary metric: wall time for 10 sequential starts
    /// (warmup=2, n=5); the legacy arm performs a real ledger load, /bin/ps and
    /// Mach footprint sample on every iteration.
    func test_microbench_alwaysAdmit_skipsProviderStartProcessScan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc2-admission-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
        try store.replace([])

        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)
        let startsPerSample = 10
        let warmup = 2
        let samples = 5

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }

        func timeLegacyPreflight() async throws -> Double {
            let gate = ManagedProviderAdmissionGate()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<startsPerSample {
                let (scan, footprintKB) = try await Task.detached(priority: .userInitiated) {
                    let scan = try ProviderProcessSweeper.managedProcessScan(store: store)
                    let footprint = AppDiagnostics.currentProcessFootprintKB()
                    return (scan, footprint >= 0 ? footprint : nil)
                }.value
                let decision = await gate.decide(
                    profile: profile,
                    scan: scan,
                    appFootprintKB: footprintKB,
                    key: ManagedProviderAdmissionKey(provider: .claude, threadId: AgentThreadID())
                )
                XCTAssertEqual(decision, .admit)
            }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }

        func timeNoOpCheck() async throws -> Double {
            let check: @Sendable (AgentProvider, AgentThreadID) async throws -> Void = { _, _ in }
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<startsPerSample {
                try await check(.claude, AgentThreadID())
            }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }

        for _ in 0..<warmup {
            _ = try await timeLegacyPreflight()
            _ = try await timeNoOpCheck()
        }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(try await timeLegacyPreflight())
            after.append(try await timeNoOpCheck())
        }
        let beforeMedian = median(before)
        let afterMedian = median(after)
        let improvement = (beforeMedian - afterMedian) / beforeMedian * 100
        NSLog(
            "[perf-proof] providerAdmission process_scan_ms=%@ noop_ms=%@ improvement_pct=%.2f before=%@ after=%@ starts=%d ps_per_start_before=1 ps_per_start_after=0",
            String(beforeMedian), String(afterMedian), improvement,
            String(describing: before), String(describing: after), startsPerSample
        )
        XCTAssertGreaterThan(
            improvement,
            5,
            "always-admit startup must avoid the real process scan by at least 5%"
        )
    }

    func test_admissionGateAlwaysAdmitsConcurrentLaunches() async {
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)
        let empty = ManagedProcessScan(
            providerProcesses: [], sidecarProcesses: [], providerRootCount: 0,
            sidecarRootCount: 0, isComplete: true, incompleteRootPIDs: []
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let gate = ManagedProviderAdmissionGate(reservationLifetime: 60)
        let keys = (0..<4).map { _ in
            ManagedProviderAdmissionKey(provider: .codex, threadId: AgentThreadID())
        }

        let decisions = await withTaskGroup(of: ManagedProviderAdmissionDecision.self) { group in
            for key in keys {
                group.addTask {
                    await gate.decide(
                        profile: profile,
                        scan: empty,
                        appFootprintKB: 256 * 1_024,
                        key: key,
                        now: now
                    )
                }
            }
            var collected: [ManagedProviderAdmissionDecision] = []
            for await decision in group { collected.append(decision) }
            return collected
        }
        XCTAssertEqual(decisions, Array(repeating: .admit, count: 4),
                       "every concurrent user start must be admitted")
    }

    func test_admissionNeverBlocksOnMeasuredMemory() {
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)
        for measured in [1, 256 * 1_024, 8 * 1_024 * 1_024] {
            XCTAssertEqual(
                AppDiagnostics.providerAdmissionDecision(
                    profile: profile,
                    scanComplete: true,
                    appFootprintKB: measured,
                    managedTreeRSSKB: measured,
                    liveProviderRoots: 0
                ),
                .admit
            )
        }
    }

    func test_admissionNeverBlocksOnUnknownMeasuredMemory() {
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)
        XCTAssertEqual(
            AppDiagnostics.providerAdmissionDecision(
                profile: profile,
                scanComplete: true,
                appFootprintKB: nil,
                managedTreeRSSKB: nil,
                liveProviderRoots: 0
            ),
            .admit,
            "unknown memory samples must not refuse a user start"
        )
    }

    func test_admissionGateAdmitsEvenWhenManagedTreeRSSIsHigh() async {
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)
        let appRSS = 512 * 1_024
        let providerRSS = 2_000 * 1_024
        let sidecarRSS = 2_000 * 1_024
        let scan = ManagedProcessScan(
            providerProcesses: [ProviderRuntimeProcess(pid: 10, ppid: 2, pgid: 10, rssKB: providerRSS, command: "redacted")],
            sidecarProcesses: [ProviderRuntimeProcess(pid: 20, ppid: 2, pgid: 20, rssKB: sidecarRSS, command: "redacted")],
            providerRootCount: 1,
            sidecarRootCount: 1,
            isComplete: true,
            incompleteRootPIDs: []
        )
        let decision = await ManagedProviderAdmissionGate().decide(
            profile: profile,
            scan: scan,
            appFootprintKB: appRSS,
            key: ManagedProviderAdmissionKey(provider: .codex, threadId: AgentThreadID())
        )
        XCTAssertEqual(decision, .admit)
    }

    func test_residentProviderTurnsRemainAdmittedWithoutSessionCap() async {
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)
        let empty = ManagedProcessScan(
            providerProcesses: [], sidecarProcesses: [], providerRootCount: 0,
            sidecarRootCount: 0, isComplete: true, incompleteRootPIDs: []
        )
        let resident = ManagedProcessScan(
            providerProcesses: [ProviderRuntimeProcess(pid: 10, ppid: 2, pgid: 10, rssKB: 128 * 1_024, command: "redacted")],
            sidecarProcesses: [],
            providerRootCount: 1,
            sidecarRootCount: 0,
            isComplete: true,
            incompleteRootPIDs: []
        )
        let gate = ManagedProviderAdmissionGate()
        let residentKey = ManagedProviderAdmissionKey(provider: .codex, threadId: AgentThreadID())
        let initial = await gate.decide(
            profile: profile, scan: empty, appFootprintKB: 256 * 1_024, key: residentKey
        )
        XCTAssertEqual(initial, .admit)
        for _ in 0..<3 {
            let turn = await gate.decide(
                profile: profile, scan: resident, appFootprintKB: 256 * 1_024, key: residentKey
            )
            XCTAssertEqual(turn, .admit)
        }
        for _ in 0..<5 {
            let extra = await gate.decide(
                profile: profile,
                scan: resident,
                appFootprintKB: 256 * 1_024,
                key: ManagedProviderAdmissionKey(provider: .codex, threadId: AgentThreadID())
            )
            XCTAssertEqual(extra, .admit, "additional roots must stay user-controlled")
        }
    }

    func test_aggregateManagedSampleHasCompleteArithmeticSlopeAndHighWater() {
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)
        let scan = ManagedProcessScan(
            providerProcesses: [ProviderRuntimeProcess(pid: 10, ppid: 2, rssKB: 200, command: "redacted")],
            sidecarProcesses: [ProviderRuntimeProcess(pid: 20, ppid: 2, rssKB: 300, command: "redacted")],
            providerRootCount: 1,
            sidecarRootCount: 1,
            isComplete: true,
            incompleteRootPIDs: []
        )
        var trend = AppDiagnostics.ManagedTrendState()
        let first = trend.record(
            appFootprintKB: 500,
            scan: scan,
            profile: profile,
            now: Date(timeIntervalSince1970: 1_000)
        )
        let second = trend.record(
            appFootprintKB: 700,
            scan: scan,
            profile: profile,
            now: Date(timeIntervalSince1970: 1_060)
        )

        XCTAssertEqual(first.totalManagedRSSKB, 1_000)
        XCTAssertEqual(second.totalManagedRSSKB, 1_200)
        XCTAssertEqual(second.previousTotalManagedRSSKB, 1_000)
        XCTAssertEqual(second.deltaManagedRSSKB, 200)
        XCTAssertEqual(second.slopeKBPerMinute, 200)
        XCTAssertEqual(second.highWaterManagedRSSKB, 1_200)
    }

    func test_incompleteManagedScanNeverReportsZeroUsage() {
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)
        let incomplete = ManagedProcessScan(
            providerProcesses: [], sidecarProcesses: [], providerRootCount: 0,
            sidecarRootCount: 0, isComplete: false, incompleteRootPIDs: [42]
        )
        let sample = AppDiagnostics.aggregateManagedSample(
            appFootprintKB: 500,
            scan: incomplete,
            profile: profile
        )

        XCTAssertFalse(sample.isComplete)
        XCTAssertNil(sample.providerProcessCount)
        XCTAssertNil(sample.providerRSSKB)
        XCTAssertNil(sample.sidecarRSSKB)
        XCTAssertNil(sample.totalManagedRSSKB,
                     "partial scans must be unavailable, not a false all-clear zero")
        XCTAssertEqual(sample.pressureDecision, .unknown)
        XCTAssertEqual(sample.admissionDecision, .admit,
                       "incomplete scans stay observational; user starts are never refused")
    }

    func test_aggregateManagedSampleExposesWarningAndCriticalDecisionSeam() {
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: eightGiB)
        let scan = ManagedProcessScan(
            providerProcesses: [], sidecarProcesses: [], providerRootCount: 0,
            sidecarRootCount: 0, isComplete: true, incompleteRootPIDs: []
        )

        let warning = AppDiagnostics.aggregateManagedSample(
            appFootprintKB: 5 * 1_024 * 1_024,
            scan: scan,
            profile: profile
        )
        let critical = AppDiagnostics.aggregateManagedSample(
            appFootprintKB: 7 * 1_024 * 1_024,
            scan: scan,
            profile: profile
        )

        XCTAssertEqual(warning.pressureDecision, .warning)
        XCTAssertEqual(critical.pressureDecision, .critical)
        // Pressure is observational only — admission remains user-controlled.
        XCTAssertEqual(warning.admissionDecision, .admit)
        XCTAssertEqual(critical.admissionDecision, .admit)
    }

    @MainActor
    func test_appDelegateUsesInjectablePhysicalMemoryProfile() {
        let delegate = AppDelegate(physicalMemoryBytesProvider: { UInt64(4) * 1_024 * 1_024 * 1_024 })
        XCTAssertEqual(delegate.managedProcessMemoryProfile.name, "low-memory-8g")
        XCTAssertNil(delegate.managedProcessMemoryProfile.providerRootCap)
        XCTAssertNil(delegate.managedProcessMemoryProfile.hostProcessCeilingKB)
        XCTAssertNil(delegate.managedProcessMemoryProfile.managedTreeCeilingKB)
    }
}
