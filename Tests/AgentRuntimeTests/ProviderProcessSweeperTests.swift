import XCTest
@testable import AgentRuntime

final class ProviderProcessSweeperTests: XCTestCase {
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

    func test_processListSnapshotIsLoadedBySweepBeforeTelemetryConsumesIt() throws {
        // WHY: the periodic diagnostics heartbeat and ownership sweep consume the
        // same point-in-time process table. Launching /bin/ps once per consumer
        // doubles idle process churn without making either decision safer.
        let loads = LockedCounter()
        let expected = [
            ProviderRuntimeProcess(pid: 101, ppid: 1, pgid: 101, rssKB: 64, command: "/opt/codex")
        ]
        let snapshot = ProviderProcessListSnapshot {
            loads.increment()
            Thread.sleep(forTimeInterval: 0.02)
            return expected
        }
        let results = NSLock()
        var telemetryRows: [ProviderRuntimeProcess] = []
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            if let rows = try? snapshot.rowsAfterSweepLoad() {
                results.lock()
                telemetryRows = rows
                results.unlock()
            }
            group.leave()
        }
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(loads.read(), 0,
                       "telemetry must wait instead of materializing rows before the sweep starts")

        let sweepRows = try snapshot.rows()
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(loads.read(), 1,
                       "telemetry and sweep must share one immutable process-list load per heartbeat")
        XCTAssertEqual(sweepRows, expected)
        XCTAssertEqual(telemetryRows, expected,
                       "telemetry must consume the exact rows produced by the sweep")
    }

    func test_processListSnapshotRetriesFailureForTelemetry() {
        // WHY: retrying only one half of a heartbeat after ps fails would let
        // telemetry and ownership decisions describe different process tables.
        enum ListFailure: Error { case failed }
        let loads = LockedCounter()
        let expected = [
            ProviderRuntimeProcess(pid: 202, ppid: 1, rssKB: 32, command: "/opt/grok")
        ]
        let snapshot = ProviderProcessListSnapshot {
            loads.increment()
            if loads.read() == 1 { throw ListFailure.failed }
            return expected
        }

        XCTAssertThrowsError(try snapshot.rows())
        XCTAssertEqual(try snapshot.rowsAfterSweepLoad(), expected)
        XCTAssertEqual(loads.read(), 2,
                       "telemetry must retain its independent retry after a transient sweep ps failure")
    }

    func test_persistedOwnershipRowsSkipsProcessListWhenLedgerIsEmpty() throws {
        // WHY: an empty ownership ledger is authoritative: command text never
        // grants ownership. Launching /bin/ps in this state can only produce rows
        // that the managed scan will discard, adding idle CPU once per heartbeat.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat-empty-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
        try store.replace([])
        let loads = LockedCounter()

        let rows = try ProviderProcessSweeper.persistedOwnershipRows(store: store) {
            loads.increment()
            return [ProviderRuntimeProcess(pid: 901, ppid: 1, rssKB: 64, command: "/opt/codex")]
        }

        XCTAssertEqual(rows, [], "zero durable ownership must yield the same complete empty telemetry input")
        XCTAssertEqual(loads.read(), 0, "an empty ledger must not execute the process-list provider")
    }

    func test_persistedOwnershipRowsListsProcessesWhenLedgerIsNonEmpty() throws {
        // WHY: the fast path must not suppress live provider memory telemetry or
        // orphan cleanup once any durable ownership row exists.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat-owned-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
        try store.replace([SpawnedProcessTag(pgid: 901, spawnedAt: Date(), provider: .codex)])
        let loads = LockedCounter()
        let expected = [ProviderRuntimeProcess(pid: 901, ppid: 1, rssKB: 64, command: "/opt/codex")]

        let rows = try ProviderProcessSweeper.persistedOwnershipRows(store: store) {
            loads.increment()
            return expected
        }

        XCTAssertEqual(rows, expected)
        XCTAssertEqual(loads.read(), 1, "non-empty ownership must preserve exactly one process-table load")
    }

    func test_persistedOwnershipRowsFailsClosedOnCorruptLedgerWithoutScanning() throws {
        // WHY: corrupt ownership is evidence, not an empty all-clear. Preserve the
        // decode failure and bytes; a speculative process scan cannot restore the
        // missing lifetime identities and must not change the failure outcome.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat-corrupt-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ownership.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: file)
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let loads = LockedCounter()

        XCTAssertThrowsError(
            try ProviderProcessSweeper.persistedOwnershipRows(store: store) {
                loads.increment()
                return []
            }
        )
        XCTAssertEqual(loads.read(), 0, "corrupt ownership must fail before an irrelevant process scan")
        XCTAssertEqual(try Data(contentsOf: file), corrupt, "the fast path must retain corrupt evidence byte-for-byte")
    }

    func test_persistedOwnershipRowsPreservesSnapshotRetryForNonEmptyLedger() throws {
        // WHY: the empty-ledger preflight must not consume the telemetry retry
        // promised after a transient process-list failure for owned runtimes.
        enum ListFailure: Error { case transient }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat-owned-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
        try store.replace([SpawnedProcessTag(pgid: 902, spawnedAt: Date(), provider: .claude)])
        let loads = LockedCounter()
        let expected = [ProviderRuntimeProcess(pid: 902, ppid: 1, rssKB: 32, command: "/opt/claude")]
        let snapshot = ProviderProcessListSnapshot {
            try ProviderProcessSweeper.persistedOwnershipRows(store: store) {
                loads.increment()
                if loads.read() == 1 { throw ListFailure.transient }
                return expected
            }
        }

        XCTAssertThrowsError(try snapshot.rows())
        XCTAssertEqual(try snapshot.rowsAfterSweepLoad(), expected)
        XCTAssertEqual(loads.read(), 2, "non-empty ownership must retain the independent telemetry retry")
    }

    func test_emptyPreflightThenConcurrentAppendRetainsExactCurrentOwner() throws {
        // WHY: a provider can be tagged after the empty-ledger preflight but
        // before the sweep reloads ownership. The empty process snapshot must
        // fail safe: retain that exact current-owner lifetime and never signal it.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat-empty-append-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
        try store.replace([])
        let loads = LockedCounter()
        let preflightRows = try ProviderProcessSweeper.persistedOwnershipRows(store: store) {
            loads.increment()
            return try ProviderProcessSweeper.psRowsThrowing()
        }
        XCTAssertEqual(loads.read(), 0)

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let identity = try XCTUnwrap(ProviderProcessStartIdentity.read(pid: currentPID))
        let tag = SpawnedProcessTag(
            pgid: currentPID,
            spawnedAt: Date(),
            ownerPID: currentPID,
            ownerStartIdentity: identity,
            provider: .codex,
            managedKind: .provider,
            executablePath: "/current-process",
            startIdentity: identity,
            isolatedProcessGroup: currentPID
        )
        try store.append(tag)

        let result = try ProviderProcessSweeper.terminatePersistedOrphanedProviderRuntimes(
            currentPID: currentPID,
            minAge: 0,
            store: store,
            processList: { preflightRows }
        )

        XCTAssertEqual(result, ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: []))
        XCTAssertEqual(try store.load(), [tag], "the concurrent lifetime must retain its ownership for the next scan")
    }

    func test_sharedSnapshotPreservesTelemetrySweepAndLedgerWhileHalvingLoads() throws {
        // WHY: sharing is valid only if it removes enumeration work without
        // changing either heartbeat accounting or ownership retention.
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let syntheticPID: pid_t = 2_000_000_000
        let tag = SpawnedProcessTag(
            pgid: syntheticPID,
            spawnedAt: Date(timeIntervalSince1970: 100),
            ownerPID: currentPID,
            provider: .claude,
            managedKind: .provider,
            executablePath: "",
            startIdentity: nil,
            isolatedProcessGroup: nil
        )
        let rows = [
            ProviderRuntimeProcess(
                pid: syntheticPID,
                ppid: 1,
                rssKB: 256,
                command: "sudo -u teammate claude"
            )
        ]

        func makeStore(_ suffix: String) throws -> ProviderProcessOwnershipStore {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("heartbeat-snapshot-\(suffix)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
            try store.replace([tag])
            return store
        }

        func runPair(
            store: ProviderProcessOwnershipStore,
            processList: @escaping ProviderProcessList
        ) throws -> (ManagedProcessScan, ProviderProcessSweepResult, [SpawnedProcessTag]) {
            let scan = try ProviderProcessSweeper.managedProcessScan(
                store: store,
                processList: processList,
                processStartIdentity: { _ in nil }
            )
            let sweep = try ProviderProcessSweeper.terminatePersistedOrphanedProviderRuntimes(
                currentPID: currentPID,
                minAge: 0,
                store: store,
                processList: processList
            )
            return (scan, sweep, try store.load())
        }

        let baselineStore = try makeStore("baseline")
        defer { try? FileManager.default.removeItem(at: baselineStore.fileURL.deletingLastPathComponent()) }
        let baselineLoads = LockedCounter()
        let baseline = try runPair(store: baselineStore) {
            baselineLoads.increment()
            return rows
        }

        let sharedStore = try makeStore("shared")
        defer { try? FileManager.default.removeItem(at: sharedStore.fileURL.deletingLastPathComponent()) }
        let sharedLoads = LockedCounter()
        let snapshot = ProviderProcessListSnapshot {
            sharedLoads.increment()
            return rows
        }
        let shared = try runPair(store: sharedStore) { try snapshot.rows() }

        XCTAssertEqual(baselineLoads.read(), 2, "the old heartbeat launched one list per consumer")
        XCTAssertEqual(sharedLoads.read(), 1, "the shared heartbeat must launch exactly one list")
        XCTAssertEqual(shared.0, baseline.0, "managed telemetry must be byte-for-byte equivalent")
        XCTAssertEqual(shared.1, baseline.1, "orphan sweep decisions must be identical")
        XCTAssertEqual(shared.2, baseline.2, "ownership ledger retention must be identical")
        XCTAssertEqual(shared.2, [tag], "a current-owner foreign row remains retained")
    }

    func test_parsePSRowPreservesCommandWithSpaces() {
        let row: Substring = "  101     1  101  22048 /opt/homebrew/bin/node /Users/me/Library/Application Support/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/ClaudeAgentSDKBridge.mjs"

        let process = ProviderProcessSweeper.parsePSRow(row)

        XCTAssertEqual(process, ProviderRuntimeProcess(
            pid: 101,
            ppid: 1,
            pgid: 101,
            rssKB: 22048,
            command: "/opt/homebrew/bin/node /Users/me/Library/Application Support/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/ClaudeAgentSDKBridge.mjs"
        ), "provider cleanup depends on matching full command paths that contain spaces")
    }

    func test_distillServerPolicy_classifiesServerVersusMCP() {
        let server = "/App/RemoteCodeDistillService --auth-token ABC --host 127.0.0.1 --port 0"
        let mcp = "/App/RemoteCodeDistillService mcp"
        XCTAssertTrue(ProviderProcessSweeper.isRemoteCodeDistillService(server))
        XCTAssertTrue(ProviderProcessSweeper.isRemoteCodeDistillServerCommand(server),
                      "MLX HTTP sidecar is the singleton server role")
        XCTAssertFalse(ProviderProcessSweeper.isRemoteCodeDistillMCPCommand(server))
        XCTAssertTrue(ProviderProcessSweeper.isRemoteCodeDistillMCPCommand(mcp),
                      "managed | distill helper is mcp mode")
        XCTAssertFalse(ProviderProcessSweeper.isRemoteCodeDistillServerCommand(mcp),
                       "mcp helpers must not be swept by the single-server policy")
    }

    func test_managedScanRequiresExactOwnershipAndSeparatesProviderFromSidecar() {
        let providerIdentity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let sidecarIdentity = ProviderProcessStartIdentity(seconds: 20, microseconds: 1)
        let tags = [
            SpawnedProcessTag(pgid: 101, spawnedAt: Date(), provider: .codex,
                              managedKind: .provider, executablePath: "/opt/codex",
                              startIdentity: providerIdentity, isolatedProcessGroup: 101),
            SpawnedProcessTag(pgid: 201, spawnedAt: Date(), managedKind: .sidecar,
                              executablePath: "/opt/RemoteCodeDistillService",
                              startIdentity: sidecarIdentity, isolatedProcessGroup: 201)
        ]
        let processes = [
            ProviderRuntimeProcess(pid: 101, ppid: 1, pgid: 101, rssKB: 100, command: "/opt/codex app-server"),
            ProviderRuntimeProcess(pid: 102, ppid: 101, pgid: 101, rssKB: 200, command: "provider-child --secret omitted"),
            ProviderRuntimeProcess(pid: 201, ppid: 1, pgid: 201, rssKB: 300, command: "/opt/RemoteCodeDistillService --auth-token hidden"),
            ProviderRuntimeProcess(pid: 999, ppid: 1, pgid: 999, rssKB: 900, command: "/opt/codex app-server")
        ]

        let scan = ProviderProcessSweeper.managedProcessScan(
            tags: tags,
            processes: processes,
            processStartIdentity: { [101: providerIdentity, 201: sidecarIdentity][$0] }
        )

        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.providerProcesses.map(\.pid), [101, 102])
        XCTAssertEqual(scan.sidecarProcesses.map(\.pid), [201])
        XCTAssertEqual(scan.providerRootCount, 1)
        XCTAssertEqual(scan.sidecarRootCount, 1)
        XCTAssertFalse(scan.providerProcesses.map(\.pid).contains(999),
                       "command text without a persisted lifetime must never grant ownership")
    }

    func test_managedScanRejectsPIDReuseAndKeepsLateGroupDescendant() {
        let oldIdentity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let newIdentity = ProviderProcessStartIdentity(seconds: 30, microseconds: 1)
        let tags = [
            SpawnedProcessTag(pgid: 101, spawnedAt: Date(), provider: .codex,
                              managedKind: .provider, executablePath: "/opt/codex",
                              startIdentity: oldIdentity, isolatedProcessGroup: 101),
            SpawnedProcessTag(pgid: 201, spawnedAt: Date(), managedKind: .sidecar,
                              executablePath: "/opt/RemoteCodeDistillService",
                              startIdentity: oldIdentity, isolatedProcessGroup: 201)
        ]
        let processes = [
            ProviderRuntimeProcess(pid: 101, ppid: 1, pgid: 101, rssKB: 100, command: "/opt/codex app-server"),
            ProviderRuntimeProcess(pid: 202, ppid: 1, pgid: 201, rssKB: 300, command: "late-sidecar-child")
        ]

        let scan = ProviderProcessSweeper.managedProcessScan(
            tags: tags,
            processes: processes,
            processStartIdentity: { $0 == 101 ? newIdentity : nil }
        )

        XCTAssertTrue(scan.isComplete)
        XCTAssertTrue(scan.providerProcesses.isEmpty,
                      "a reused root PID must not inherit the old provider ownership")
        XCTAssertEqual(scan.sidecarProcesses.map(\.pid), [202],
                       "a certified process group retains a late descendant after the root exits")
    }

    func test_managedScanMarksLegacyUnverifiableOwnershipIncomplete() {
        let legacy = SpawnedProcessTag(pgid: 101, spawnedAt: Date(), provider: nil)
        let scan = ProviderProcessSweeper.managedProcessScan(
            tags: [legacy],
            processes: [],
            processStartIdentity: { _ in nil }
        )
        XCTAssertFalse(scan.isComplete)
        XCTAssertEqual(scan.incompleteRootPIDs, [101])
    }

    /// WHY: a run-as-user Claude turn writes an owner-anchored tag with no child
    /// start identity (root `sudo` child metadata is EPERM to a non-root parent).
    /// Before the fix, that single row marked every scan incomplete, so ANY later
    /// provider start failed with processAccountingUnavailable ("Failed to
    /// start") — the exact 2.0.88 field report from the airtonempath profile.
    func test_managedScanAccountsLiveRunAsUserRowWithoutPoisoningCompleteness() {
        let foreign = SpawnedProcessTag(
            pgid: 101, spawnedAt: Date(), provider: .claude,
            managedKind: .provider, executablePath: "",
            startIdentity: nil, isolatedProcessGroup: nil
        )
        let processes = [
            ProviderRuntimeProcess(pid: 101, ppid: 1, pgid: 50, rssKB: 100, command: "sudo -u other claude"),
            ProviderRuntimeProcess(pid: 102, ppid: 101, pgid: 50, rssKB: 200, command: "claude --print"),
            ProviderRuntimeProcess(pid: 999, ppid: 1, pgid: 999, rssKB: 900, command: "unrelated")
        ]

        let scan = ProviderProcessSweeper.managedProcessScan(
            tags: [foreign],
            processes: processes,
            processStartIdentity: { _ in nil }
        )

        XCTAssertTrue(scan.isComplete, "a run-as-user row must never block admission for everyone")
        XCTAssertEqual(scan.providerRootCount, 1)
        XCTAssertEqual(scan.providerProcesses.map(\.pid), [101, 102],
                       "live sudo root and its descendants are accounted conservatively")
        XCTAssertFalse(scan.providerProcesses.map(\.pid).contains(999))
    }

    /// Integration proof of the field failure path: a foreign row persisted in a
    /// REAL on-disk ledger, scanned against the REAL process table with a REAL
    /// live child — end-to-end through JSON decode → ps parse → scan. Locks the
    /// full pipeline the app's admission check uses, not just the pure function.
    func test_endToEnd_realLedgerForeignRowScansCompleteAgainstRealProcessTable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc2-ownership-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProviderProcessOwnershipStore(fileURL: dir.appendingPathComponent("ownership.json"))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }

        try store.append(SpawnedProcessTag(
            pgid: child.processIdentifier, spawnedAt: Date(), provider: .claude,
            managedKind: .provider, executablePath: "",
            startIdentity: nil, isolatedProcessGroup: nil
        ))

        let scan = try ProviderProcessSweeper.managedProcessScan(store: store)

        XCTAssertTrue(scan.isComplete,
                      "a persisted run-as-user row must scan complete against the live process table")
        XCTAssertTrue(scan.providerProcesses.contains { $0.pid == child.processIdentifier },
                      "the live foreign root must be accounted, not ignored")
        XCTAssertEqual(scan.providerRootCount, 1)
    }

    func test_managedScanTreatsExitedRunAsUserRowAsZeroContribution() {
        let foreign = SpawnedProcessTag(
            pgid: 101, spawnedAt: Date(), provider: .claude,
            managedKind: .provider, executablePath: "",
            startIdentity: nil, isolatedProcessGroup: nil
        )

        let scan = ProviderProcessSweeper.managedProcessScan(
            tags: [foreign],
            processes: [ProviderRuntimeProcess(pid: 999, ppid: 1, pgid: 999, rssKB: 900, command: "unrelated")],
            processStartIdentity: { _ in nil }
        )

        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.providerRootCount, 0)
        XCTAssertTrue(scan.providerProcesses.isEmpty,
                      "an exited run-as-user turn contributes nothing and blocks nothing")
    }

    /// WHY: Codex and many Homebrew CLIs are `#!/usr/bin/env node` scripts. The
    /// ownership ledger can store `/usr/bin/env` (or the script path) while `ps`
    /// later shows `node …/codex app-server`. Before this fix that path drift
    /// marked the scan incomplete and blocked every provider start with
    /// processAccountingUnavailable — not just Codex, and on every Mac that
    /// hit the race.
    func test_managedScanAccountsShebangReExecWithoutPoisoningCompleteness() {
        let identity = ProviderProcessStartIdentity(seconds: 50, microseconds: 2)
        let tags = [
            SpawnedProcessTag(
                pgid: 101, spawnedAt: Date(), provider: .codex,
                managedKind: .provider, executablePath: "/usr/bin/env",
                startIdentity: identity, isolatedProcessGroup: 101
            ),
            SpawnedProcessTag(
                pgid: 201, spawnedAt: Date(), provider: .grok,
                managedKind: .provider, executablePath: "/opt/grok",
                startIdentity: ProviderProcessStartIdentity(seconds: 60, microseconds: 1),
                isolatedProcessGroup: 201
            )
        ]
        let processes = [
            ProviderRuntimeProcess(
                pid: 101, ppid: 1, pgid: 101, rssKB: 120,
                command: "node /opt/homebrew/bin/codex app-server"
            ),
            ProviderRuntimeProcess(
                pid: 102, ppid: 101, pgid: 101, rssKB: 80,
                command: "codex-worker --session"
            ),
            ProviderRuntimeProcess(
                pid: 201, ppid: 1, pgid: 201, rssKB: 90,
                command: "/opt/grok agent stdio"
            )
        ]

        let scan = ProviderProcessSweeper.managedProcessScan(
            tags: tags,
            processes: processes,
            processStartIdentity: {
                $0 == 101 ? identity
                    : $0 == 201 ? ProviderProcessStartIdentity(seconds: 60, microseconds: 1)
                    : nil
            }
        )

        XCTAssertTrue(scan.isComplete,
                      "shebang re-exec path drift must never block provider admission")
        XCTAssertEqual(scan.incompleteRootPIDs, [])
        XCTAssertEqual(scan.providerRootCount, 2)
        XCTAssertEqual(scan.providerProcesses.map(\.pid), [101, 102, 201])
    }

    /// WHY: identity still gates ownership — a reused PID with a different start
    /// identity must not inherit the old env-tagged Codex row even after the
    /// shebang fix relaxes executable matching.
    func test_managedScanStillRejectsPIDReuseAfterShebangRelaxation() {
        let oldIdentity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let newIdentity = ProviderProcessStartIdentity(seconds: 99, microseconds: 9)
        let tags = [
            SpawnedProcessTag(
                pgid: 101, spawnedAt: Date(), provider: .codex,
                managedKind: .provider, executablePath: "/usr/bin/env",
                startIdentity: oldIdentity, isolatedProcessGroup: 101
            )
        ]
        let processes = [
            ProviderRuntimeProcess(
                pid: 101, ppid: 1, pgid: 101, rssKB: 50,
                command: "node /opt/homebrew/bin/codex app-server"
            )
        ]

        let scan = ProviderProcessSweeper.managedProcessScan(
            tags: tags,
            processes: processes,
            processStartIdentity: { _ in newIdentity }
        )

        XCTAssertTrue(scan.isComplete)
        XCTAssertTrue(scan.providerProcesses.isEmpty)
        XCTAssertEqual(scan.providerRootCount, 0)
    }

}

final class ProcessSpawnTaggerExecutablePathTests: XCTestCase {
    func test_preferredOwnershipExecutablePathPrefersLiveNonEnvPath() {
        XCTAssertEqual(
            ProcessSpawnTagger.preferredOwnershipExecutablePath(
                livePath: "/opt/homebrew/Cellar/node/26.3.1/bin/node",
                launchedPath: "/opt/homebrew/bin/codex"
            ),
            "/opt/homebrew/Cellar/node/26.3.1/bin/node"
        )
    }

    func test_preferredOwnershipExecutablePathFallsBackFromEnvLauncher() {
        // WHY: tagging during the `env` trampoline would otherwise store
        // `/usr/bin/env` and later poison managed-process scans for every Mac.
        XCTAssertEqual(
            ProcessSpawnTagger.preferredOwnershipExecutablePath(
                livePath: "/usr/bin/env",
                launchedPath: "/opt/homebrew/bin/codex"
            ),
            "/opt/homebrew/bin/codex"
        )
        XCTAssertEqual(
            ProcessSpawnTagger.preferredOwnershipExecutablePath(
                livePath: nil,
                launchedPath: "/opt/homebrew/bin/codex"
            ),
            "/opt/homebrew/bin/codex"
        )
        XCTAssertEqual(
            ProcessSpawnTagger.preferredOwnershipExecutablePath(
                livePath: "/usr/bin/env",
                launchedPath: nil
            ),
            "/usr/bin/env"
        )
        XCTAssertNil(
            ProcessSpawnTagger.preferredOwnershipExecutablePath(
                livePath: nil,
                launchedPath: nil
            )
        )
    }
}
