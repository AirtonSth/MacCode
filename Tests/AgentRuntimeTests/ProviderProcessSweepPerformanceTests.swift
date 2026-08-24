import XCTest
import Darwin
@testable import AgentRuntime

final class ProviderProcessSweepPerformanceTests: XCTestCase {
    private struct Sample {
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
        let groupEnumerations: Int
        let result: ProviderProcessSweepResult
    }

    private struct HeartbeatSample {
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
        let psExecutions: Int
        let scans: [ManagedProcessScan]
        let sweeps: [ProviderProcessSweepResult]
        let ledger: [SpawnedProcessTag]
    }

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

    private final class HeartbeatResults: @unchecked Sendable {
        private let lock = NSLock()
        private var scans: [ManagedProcessScan] = []
        private var sweeps: [ProviderProcessSweepResult] = []
        private var firstError: Error?

        func record(_ result: Result<ManagedProcessScan, Error>) {
            lock.lock()
            defer { lock.unlock() }
            switch result {
            case .success(let scan): scans.append(scan)
            case .failure(let error): firstError = firstError ?? error
            }
        }

        func record(_ result: Result<ProviderProcessSweepResult, Error>) {
            lock.lock()
            defer { lock.unlock() }
            switch result {
            case .success(let sweep): sweeps.append(sweep)
            case .failure(let error): firstError = firstError ?? error
            }
        }

        func values() throws -> ([ManagedProcessScan], [ProviderProcessSweepResult]) {
            lock.lock()
            defer { lock.unlock() }
            if let firstError { throw firstError }
            return (scans, sweeps)
        }
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private func processAndChildrenCPUSeconds() -> Double {
        func seconds(_ who: Int32) -> Double {
            var usage = rusage()
            _ = getrusage(who, &usage)
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            return user + system
        }
        return seconds(RUSAGE_SELF) + seconds(RUSAGE_CHILDREN)
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    /// Same-process A/B for the concurrent heartbeat+sweep pair used in production.
    /// Both arms exercise real `/bin/ps`, ledger load/commit, parsing and aggregation;
    /// the optimized arm changes only process-table executions (warmup=2, n=7).
    func test_microbench_sharedHeartbeatSnapshot_removesRedundantPS() throws {
        let warmup = 2
        let samples = 7
        let ticksPerSample = 4
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat-ps-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
        try store.replace([])

        func measure(shared: Bool) throws -> HeartbeatSample {
            let executions = LockedCounter()
            let realPS: ProviderProcessList = {
                executions.increment()
                return try ProviderProcessSweeper.psRowsThrowing()
            }
            let cpuStart = processAndChildrenCPUSeconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let results = HeartbeatResults()
            for _ in 0..<ticksPerSample {
                let telemetryProcessList: ProviderProcessList
                let sweepProcessList: ProviderProcessList
                if shared {
                    let snapshot = ProviderProcessListSnapshot(loader: realPS)
                    telemetryProcessList = { try snapshot.rowsAfterSweepLoad() }
                    sweepProcessList = { try snapshot.rows() }
                } else {
                    telemetryProcessList = realPS
                    sweepProcessList = realPS
                }
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    results.record(Result {
                        try ProviderProcessSweeper.managedProcessScan(
                            store: store,
                            processList: telemetryProcessList
                        )
                    })
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    results.record(Result {
                        try ProviderProcessSweeper.terminatePersistedOrphanedProviderRuntimes(
                            minAge: 0,
                            store: store,
                            processList: sweepProcessList
                        )
                    })
                    group.leave()
                }
                XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
            }
            let wallEnd = DispatchTime.now().uptimeNanoseconds
            let cpuEnd = processAndChildrenCPUSeconds()
            let (scans, sweeps) = try results.values()
            return HeartbeatSample(
                wallMilliseconds: Double(wallEnd - wallStart) / 1_000_000,
                cpuMilliseconds: (cpuEnd - cpuStart) * 1_000,
                psExecutions: executions.read(),
                scans: scans,
                sweeps: sweeps,
                ledger: try store.load()
            )
        }

        for _ in 0..<warmup {
            _ = try measure(shared: false)
            _ = try measure(shared: true)
        }
        var before: [HeartbeatSample] = []
        var after: [HeartbeatSample] = []
        for sampleIndex in 0..<samples {
            if sampleIndex.isMultiple(of: 2) {
                before.append(try measure(shared: false))
                after.append(try measure(shared: true))
            } else {
                after.append(try measure(shared: true))
                before.append(try measure(shared: false))
            }
        }

        let beforeWall = median(before.map(\.wallMilliseconds))
        let afterWall = median(after.map(\.wallMilliseconds))
        let beforeCPU = median(before.map(\.cpuMilliseconds))
        let afterCPU = median(after.map(\.cpuMilliseconds))
        let wallImprovement = (beforeWall - afterWall) / beforeWall * 100
        let cpuImprovement = (beforeCPU - afterCPU) / beforeCPU * 100
        let emptyScan = ManagedProcessScan(
            providerProcesses: [], sidecarProcesses: [],
            providerRootCount: 0, sidecarRootCount: 0,
            isComplete: true, incompleteRootPIDs: []
        )
        let emptySweep = ProviderProcessSweepResult(
            orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: []
        )

        XCTAssertTrue(before.allSatisfy { $0.psExecutions == ticksPerSample * 2 })
        XCTAssertTrue(after.allSatisfy { $0.psExecutions == ticksPerSample })
        XCTAssertTrue((before + after).allSatisfy {
            $0.scans == Array(repeating: emptyScan, count: ticksPerSample)
                && $0.sweeps == Array(repeating: emptySweep, count: ticksPerSample)
                && $0.ledger.isEmpty
        }, "A/B must produce identical telemetry, sweep results and final ledger")
        NSLog(
            "[perf-proof] heartbeat ticks=%d baseline_ps=%d shared_ps=%d baseline_wall_ms=%@ shared_wall_ms=%@ wall_improvement_pct=%.2f baseline_cpu_ms=%@ shared_cpu_ms=%@ cpu_improvement_pct=%.2f before_wall=%@ after_wall=%@ before_cpu=%@ after_cpu=%@",
            ticksPerSample, ticksPerSample * 2, ticksPerSample,
            String(beforeWall), String(afterWall), wallImprovement,
            String(beforeCPU), String(afterCPU), cpuImprovement,
            String(describing: before.map(\.wallMilliseconds)),
            String(describing: after.map(\.wallMilliseconds)),
            String(describing: before.map(\.cpuMilliseconds)),
            String(describing: after.map(\.cpuMilliseconds))
        )
        XCTAssertGreaterThan(wallImprovement, 5,
                             "one shared ps per heartbeat must improve wall time by >5%")
        XCTAssertGreaterThan(cpuImprovement, 5,
                             "one shared ps per heartbeat must improve process+child CPU by >5%")
    }

    /// Same-machine A/B of the exact shared-snapshot heartbeat with an empty
    /// durable ownership ledger. The legacy arm executes real `/bin/ps`; the
    /// candidate arm first consults the authoritative ledger (warmup=2, n=7).
    func test_microbench_idleHeartbeatEmptyLedger_skipsProcessTable() throws {
        let warmup = 2
        let samples = 7
        let ticksPerSample = 12
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat-empty-ps-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
        try store.replace([])

        func measure(skipEmptyOwnership: Bool) throws -> HeartbeatSample {
            let executions = LockedCounter()
            let realPS: ProviderProcessList = {
                executions.increment()
                return try ProviderProcessSweeper.psRowsThrowing()
            }
            let cpuStart = processAndChildrenCPUSeconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let results = HeartbeatResults()
            for _ in 0..<ticksPerSample {
                let loader: ProviderProcessList
                if skipEmptyOwnership {
                    loader = {
                        try ProviderProcessSweeper.persistedOwnershipRows(
                            store: store,
                            processList: realPS
                        )
                    }
                } else {
                    loader = realPS
                }
                let snapshot = ProviderProcessListSnapshot(loader: loader)
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    results.record(Result {
                        try ProviderProcessSweeper.managedProcessScan(
                            store: store,
                            processList: { try snapshot.rowsAfterSweepLoad() }
                        )
                    })
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    results.record(Result {
                        try ProviderProcessSweeper.terminatePersistedOrphanedProviderRuntimes(
                            minAge: 0,
                            store: store,
                            processList: { try snapshot.rows() }
                        )
                    })
                    group.leave()
                }
                XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
            }
            let wallEnd = DispatchTime.now().uptimeNanoseconds
            let cpuEnd = processAndChildrenCPUSeconds()
            let (scans, sweeps) = try results.values()
            return HeartbeatSample(
                wallMilliseconds: Double(wallEnd - wallStart) / 1_000_000,
                cpuMilliseconds: (cpuEnd - cpuStart) * 1_000,
                psExecutions: executions.read(),
                scans: scans,
                sweeps: sweeps,
                ledger: try store.load()
            )
        }

        for _ in 0..<warmup {
            _ = try measure(skipEmptyOwnership: false)
            _ = try measure(skipEmptyOwnership: true)
        }
        var before: [HeartbeatSample] = []
        var after: [HeartbeatSample] = []
        for sampleIndex in 0..<samples {
            if sampleIndex.isMultiple(of: 2) {
                before.append(try measure(skipEmptyOwnership: false))
                after.append(try measure(skipEmptyOwnership: true))
            } else {
                after.append(try measure(skipEmptyOwnership: true))
                before.append(try measure(skipEmptyOwnership: false))
            }
        }

        let beforeWall = median(before.map(\.wallMilliseconds))
        let afterWall = median(after.map(\.wallMilliseconds))
        let beforeCPU = median(before.map(\.cpuMilliseconds))
        let afterCPU = median(after.map(\.cpuMilliseconds))
        let wallImprovement = (beforeWall - afterWall) / beforeWall * 100
        let cpuImprovement = beforeCPU > 0 ? (beforeCPU - afterCPU) / beforeCPU * 100 : 0
        let emptyScan = ManagedProcessScan(
            providerProcesses: [], sidecarProcesses: [],
            providerRootCount: 0, sidecarRootCount: 0,
            isComplete: true, incompleteRootPIDs: []
        )
        let emptySweep = ProviderProcessSweepResult(
            orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: []
        )

        XCTAssertTrue(before.allSatisfy { $0.psExecutions == ticksPerSample })
        XCTAssertTrue(after.allSatisfy { $0.psExecutions == 0 })
        XCTAssertTrue((before + after).allSatisfy {
            $0.scans == Array(repeating: emptyScan, count: ticksPerSample)
                && $0.sweeps == Array(repeating: emptySweep, count: ticksPerSample)
                && $0.ledger.isEmpty
        }, "skipping ps must preserve complete zero telemetry, empty sweep output and ledger")
        NSLog(
            "[perf-proof] idleHeartbeatEmptyLedger ticks=%d baseline_ps=%d optimized_ps=0 baseline_wall_ms=%@ optimized_wall_ms=%@ wall_improvement_pct=%.2f baseline_cpu_ms=%@ optimized_cpu_ms=%@ cpu_improvement_pct=%.2f before_wall=%@ after_wall=%@ before_cpu=%@ after_cpu=%@",
            ticksPerSample, ticksPerSample,
            String(beforeWall), String(afterWall), wallImprovement,
            String(beforeCPU), String(afterCPU), cpuImprovement,
            String(describing: before.map(\.wallMilliseconds)),
            String(describing: after.map(\.wallMilliseconds)),
            String(describing: before.map(\.cpuMilliseconds)),
            String(describing: after.map(\.cpuMilliseconds))
        )
        XCTAssertGreaterThan(wallImprovement, 5,
                             "empty-ledger heartbeat must improve wall time by >5%")
        XCTAssertGreaterThan(cpuImprovement, 5,
                             "removing real ps child work must improve CPU by >5%")
    }

    /// Regression bound for the non-empty path: the ownership preflight adds one
    /// JSON decode before the unchanged real `/bin/ps`. It must stay below the 5%
    /// qualification threshold at both one row and the 256-row downgrade ceiling.
    func test_microbench_nonEmptyOwnershipPreflight_staysBelowNoiseThreshold() throws {
        let warmup = 2
        let samples = 7
        let ticksPerSample = 4

        for tagCount in [1, ProviderProcessOwnershipStore.downgradeSafeRecordCeiling] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("heartbeat-owned-preflight-\(tagCount)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
            let tags = (0..<tagCount).map { offset in
                SpawnedProcessTag(
                    pgid: pid_t(1_500_000_000 + offset),
                    spawnedAt: Date(timeIntervalSince1970: Double(1_000 + offset)),
                    provider: .codex
                )
            }
            try store.replace(tags)

            func measure(preflight: Bool) throws -> HeartbeatSample {
                let executions = LockedCounter()
                let realPS: ProviderProcessList = {
                    executions.increment()
                    return try ProviderProcessSweeper.psRowsThrowing()
                }
                let cpuStart = processAndChildrenCPUSeconds()
                let wallStart = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<ticksPerSample {
                    if preflight {
                        _ = try ProviderProcessSweeper.persistedOwnershipRows(
                            store: store,
                            processList: realPS
                        )
                    } else {
                        _ = try realPS()
                    }
                }
                let wallEnd = DispatchTime.now().uptimeNanoseconds
                let cpuEnd = processAndChildrenCPUSeconds()
                return HeartbeatSample(
                    wallMilliseconds: Double(wallEnd - wallStart) / 1_000_000,
                    cpuMilliseconds: (cpuEnd - cpuStart) * 1_000,
                    psExecutions: executions.read(),
                    scans: [],
                    sweeps: [],
                    ledger: try store.load()
                )
            }

            for _ in 0..<warmup {
                _ = try measure(preflight: false)
                _ = try measure(preflight: true)
            }
            var before: [HeartbeatSample] = []
            var after: [HeartbeatSample] = []
            for sampleIndex in 0..<samples {
                if sampleIndex.isMultiple(of: 2) {
                    before.append(try measure(preflight: false))
                    after.append(try measure(preflight: true))
                } else {
                    after.append(try measure(preflight: true))
                    before.append(try measure(preflight: false))
                }
            }

            let beforeWall = median(before.map(\.wallMilliseconds))
            let afterWall = median(after.map(\.wallMilliseconds))
            let beforeCPU = median(before.map(\.cpuMilliseconds))
            let afterCPU = median(after.map(\.cpuMilliseconds))
            let wallRegression = (afterWall - beforeWall) / beforeWall * 100
            let cpuRegression = beforeCPU > 0 ? (afterCPU - beforeCPU) / beforeCPU * 100 : 0

            XCTAssertTrue((before + after).allSatisfy {
                $0.psExecutions == ticksPerSample && $0.ledger == tags
            }, "non-empty A/B must preserve one real ps per tick and the exact ledger")
            NSLog(
                "[perf-proof] nonEmptyOwnershipPreflight tags=%d ticks=%d baseline_ps=%d optimized_ps=%d baseline_wall_ms=%@ optimized_wall_ms=%@ wall_regression_pct=%.2f baseline_cpu_ms=%@ optimized_cpu_ms=%@ cpu_regression_pct=%.2f before_wall=%@ after_wall=%@ before_cpu=%@ after_cpu=%@",
                tagCount, ticksPerSample, ticksPerSample, ticksPerSample,
                String(beforeWall), String(afterWall), wallRegression,
                String(beforeCPU), String(afterCPU), cpuRegression,
                String(describing: before.map(\.wallMilliseconds)),
                String(describing: after.map(\.wallMilliseconds)),
                String(describing: before.map(\.cpuMilliseconds)),
                String(describing: after.map(\.cpuMilliseconds))
            )
            XCTAssertLessThan(wallRegression, 5,
                              "non-empty ownership preflight must stay below 5% wall regression")
            XCTAssertLessThan(cpuRegression, 5,
                              "non-empty ownership preflight must stay below 5% CPU regression")
        }
    }

    /// Real APFS A/B of the residual empty-sweep commit. The legacy arm executes
    /// the exact load -> commitSweep -> atomic write/fsync/rename/directory-fsync
    /// sequence; the optimized arm executes the production empty sweep.
    func test_microbench_emptyOwnershipSweep_skipsNoOpLedgerRewrite() throws {
        let warmup = 2
        let samples = 7
        let ticksPerSample = 32
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat-empty-write-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
        try store.replace([])

        func optimizedSweep() throws {
            _ = try ProviderProcessSweeper.sweepPersistedOrphans(
                store: store,
                currentPID: ProcessInfo.processInfo.processIdentifier,
                minAge: 0,
                ownerIsAlive: { _ in false },
                processCommand: { _ in nil },
                processStartIdentity: { _ in nil },
                descendantPIDs: { _ in [] },
                processGroupMembers: { _ in [] },
                processIsAlive: { _ in false },
                graceInterval: 0,
                wait: { _ in },
                sendSignal: { _, _ in false }
            )
        }

        func measure(legacyRewrite: Bool) throws -> Sample {
            let cpuStart = processCPUSeconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<ticksPerSample {
                if legacyRewrite {
                    // Exact empty branch removed from sweepPersistedOrphans:
                    // load `tags`, then commit the unchanged empty snapshot.
                    let tags = try store.load()
                    try store.commitSweep(snapshot: tags, retainedFromSnapshot: [])
                } else {
                    try optimizedSweep()
                }
            }
            let wallEnd = DispatchTime.now().uptimeNanoseconds
            let cpuEnd = processCPUSeconds()
            return Sample(
                wallMilliseconds: Double(wallEnd - wallStart) / 1_000_000,
                cpuMilliseconds: (cpuEnd - cpuStart) * 1_000,
                groupEnumerations: legacyRewrite ? ticksPerSample : 0,
                result: ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
            )
        }

        for _ in 0..<warmup {
            _ = try measure(legacyRewrite: true)
            _ = try measure(legacyRewrite: false)
        }
        var before: [Sample] = []
        var after: [Sample] = []
        for sampleIndex in 0..<samples {
            if sampleIndex.isMultiple(of: 2) {
                before.append(try measure(legacyRewrite: true))
                after.append(try measure(legacyRewrite: false))
            } else {
                after.append(try measure(legacyRewrite: false))
                before.append(try measure(legacyRewrite: true))
            }
        }

        let beforeWall = median(before.map(\.wallMilliseconds))
        let afterWall = median(after.map(\.wallMilliseconds))
        let beforeCPU = median(before.map(\.cpuMilliseconds))
        let afterCPU = median(after.map(\.cpuMilliseconds))
        let wallImprovement = (beforeWall - afterWall) / beforeWall * 100
        let cpuImprovement = beforeCPU > 0 ? (beforeCPU - afterCPU) / beforeCPU * 100 : 0

        XCTAssertTrue(before.allSatisfy { $0.groupEnumerations == ticksPerSample })
        XCTAssertTrue(after.allSatisfy { $0.groupEnumerations == 0 })
        XCTAssertEqual(try store.load(), [])
        NSLog(
            "[perf-proof] emptyOwnershipSweep ticks=%d baseline_ledger_rewrites=%d optimized_ledger_rewrites=0 baseline_wall_ms=%@ optimized_wall_ms=%@ wall_improvement_pct=%.2f baseline_cpu_ms=%@ optimized_cpu_ms=%@ cpu_improvement_pct=%.2f before_wall=%@ after_wall=%@ before_cpu=%@ after_cpu=%@",
            ticksPerSample, ticksPerSample,
            String(beforeWall), String(afterWall), wallImprovement,
            String(beforeCPU), String(afterCPU), cpuImprovement,
            String(describing: before.map(\.wallMilliseconds)),
            String(describing: after.map(\.wallMilliseconds)),
            String(describing: before.map(\.cpuMilliseconds)),
            String(describing: after.map(\.cpuMilliseconds))
        )
        XCTAssertGreaterThan(wallImprovement, 5,
                             "skipping empty atomic rewrites must improve wall time by >5%")
        XCTAssertGreaterThan(cpuImprovement, 5,
                             "skipping empty atomic rewrites must improve CPU by >5%")
    }

    /// Same-process A/B of the pre-checkpoint eager enumeration and production's
    /// lazy sweep. Primary metric: wall time for live exact current-owner rows;
    /// process CPU is reported as a corroborating metric (warmup=2, n=7).
    func test_microbench_liveCurrentOwnerRows_skipPerTagProcessTableEnumeration() throws {
        let warmup = 2
        let samples = 7
        let sweepsPerSample = 8
        let currentPID: pid_t = 700
        let ownerIdentity = ProviderProcessStartIdentity(seconds: 1, microseconds: 1)
        let rootIdentity = ProviderProcessStartIdentity(seconds: 2, microseconds: 1)

        for tagCount in [1, 8, 32] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("provider-sweep-perf-\(tagCount)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
            let tags = (0..<tagCount).map { offset in
                let pid = pid_t(30_000 + offset)
                return SpawnedProcessTag(
                    pgid: pid,
                    spawnedAt: Date(timeIntervalSince1970: 100),
                    ownerPID: currentPID,
                    ownerStartIdentity: ownerIdentity,
                    provider: .codex,
                    managedKind: .provider,
                    executablePath: "/opt/codex",
                    startIdentity: rootIdentity,
                    isolatedProcessGroup: pid
                )
            }
            try store.replace(tags)

            func measure(eagerLegacyEnumeration: Bool) throws -> Sample {
                var enumerations = 0
                let processGroupMembers: (pid_t) -> [pid_t] = { group in
                    enumerations += 1
                    return ProcessTerminator.processGroupPIDs(group)
                }
                let cpuStart = processCPUSeconds()
                let wallStart = DispatchTime.now().uptimeNanoseconds
                var result = ProviderProcessSweepResult(
                    orphanRootPIDs: [],
                    terminatedPIDs: [],
                    failedPIDs: []
                )
                for _ in 0..<sweepsPerSample {
                    if eagerLegacyEnumeration {
                        // Exact removed work: the old loop loaded verified group
                        // members before checking the current owner/root fast path.
                        for tag in tags {
                            _ = processGroupMembers(tag.pgid)
                        }
                    }
                    result = try ProviderProcessSweeper.sweepPersistedOrphans(
                        store: store,
                        currentPID: currentPID,
                        minAge: 0,
                        ownerIsAlive: { _ in true },
                        ownerStartIdentity: { _ in ownerIdentity },
                        processCommand: { _ in nil },
                        processStartIdentity: { _ in rootIdentity },
                        descendantPIDs: { _ in [] },
                        processGroupMembers: processGroupMembers,
                        processIsAlive: { _ in true },
                        graceInterval: 0,
                        wait: { _ in },
                        sendSignal: { _, _ in false }
                    )
                }
                let wallEnd = DispatchTime.now().uptimeNanoseconds
                let cpuEnd = processCPUSeconds()
                return Sample(
                    wallMilliseconds: Double(wallEnd - wallStart) / 1_000_000,
                    cpuMilliseconds: (cpuEnd - cpuStart) * 1_000,
                    groupEnumerations: enumerations,
                    result: result
                )
            }

            for _ in 0..<warmup {
                _ = try measure(eagerLegacyEnumeration: true)
                _ = try measure(eagerLegacyEnumeration: false)
            }
            var before: [Sample] = []
            var after: [Sample] = []
            for sampleIndex in 0..<samples {
                if sampleIndex.isMultiple(of: 2) {
                    before.append(try measure(eagerLegacyEnumeration: true))
                    after.append(try measure(eagerLegacyEnumeration: false))
                } else {
                    after.append(try measure(eagerLegacyEnumeration: false))
                    before.append(try measure(eagerLegacyEnumeration: true))
                }
            }

            let beforeWall = median(before.map(\.wallMilliseconds))
            let afterWall = median(after.map(\.wallMilliseconds))
            let beforeCPU = median(before.map(\.cpuMilliseconds))
            let afterCPU = median(after.map(\.cpuMilliseconds))
            let wallImprovement = (beforeWall - afterWall) / beforeWall * 100
            let cpuImprovement = beforeCPU > 0 ? (beforeCPU - afterCPU) / beforeCPU * 100 : 0
            let expectedLegacyEnumerations = tagCount * sweepsPerSample
            let expectedResult = ProviderProcessSweepResult(
                orphanRootPIDs: [],
                terminatedPIDs: [],
                failedPIDs: []
            )

            XCTAssertTrue(before.allSatisfy { $0.groupEnumerations == expectedLegacyEnumerations })
            XCTAssertTrue(after.allSatisfy { $0.groupEnumerations == 0 })
            XCTAssertTrue(before.allSatisfy { $0.result == expectedResult })
            XCTAssertTrue(after.allSatisfy { $0.result == expectedResult })
            XCTAssertEqual(try store.load(), tags, "A/B sweeps must make identical ledger decisions")
            NSLog(
                "[perf-proof] providerSweep tags=%d sweeps=%d eager_wall_ms=%@ lazy_wall_ms=%@ wall_improvement_pct=%.2f eager_cpu_ms=%@ lazy_cpu_ms=%@ cpu_improvement_pct=%.2f eager_enumerations=%d lazy_enumerations=0 before_wall=%@ after_wall=%@ before_cpu=%@ after_cpu=%@",
                tagCount, sweepsPerSample,
                String(beforeWall), String(afterWall), wallImprovement,
                String(beforeCPU), String(afterCPU), cpuImprovement,
                expectedLegacyEnumerations,
                String(describing: before.map(\.wallMilliseconds)),
                String(describing: after.map(\.wallMilliseconds)),
                String(describing: before.map(\.cpuMilliseconds)),
                String(describing: after.map(\.cpuMilliseconds))
            )
            XCTAssertGreaterThan(
                wallImprovement,
                5,
                "lazy group enumeration must improve the live-root sweep by >5% for \(tagCount) tags"
            )
        }
    }
}
