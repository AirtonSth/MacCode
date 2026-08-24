import XCTest
import Darwin
@testable import AgentRuntime
import CoreModel

final class ProcessLifecycleHardeningTests: XCTestCase {
    func test_exactOwnedDispositionDoesNotEraseReusedPIDLifetime() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-ledger-exact-disposition-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let old = SpawnedProcessTag(
            pgid: 40, spawnedAt: Date(timeIntervalSince1970: 1), managedKind: .sidecar,
            startIdentity: ProviderProcessStartIdentity(seconds: 1, microseconds: 1)
        )
        let reused = SpawnedProcessTag(
            pgid: 40, spawnedAt: Date(timeIntervalSince1970: 2), managedKind: .sidecar,
            startIdentity: ProviderProcessStartIdentity(seconds: 2, microseconds: 1)
        )
        try store.replace([reused])

        try store.removeExact(old)

        XCTAssertEqual(try store.load(), [reused],
                       "sidecar exit disposition must not erase a newer lifetime that reused its PID")
    }

    func test_ownershipLedgerNeverSuffixEvictsLiveRowsAndNeverRefusesSpawn() throws {
        // S4: live/unknown ownership is proportional to live roots — never
        // suffix-evicted at 256 (or any maxRecords soft ceiling). Spawns must
        // never be refused solely due to row count.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-ledger-capacity-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file, maxRecords: 2)
        let identity = ProviderProcessStartIdentity(seconds: 1, microseconds: 1)
        let base = Date(timeIntervalSince1970: 1_000)
        let tags = (1...3).map { pid in
            SpawnedProcessTag(
                pgid: pid_t(pid),
                spawnedAt: base.addingTimeInterval(TimeInterval(pid)),
                ownerStartIdentity: identity,
                provider: .codex,
                managedKind: .provider,
                executablePath: "/opt/codex",
                startIdentity: identity,
                isolatedProcessGroup: pid_t(pid)
            )
        }
        try store.append(tags[0])
        try store.append(tags[1])
        try store.append(tags[2])

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 3, "append must retain all live ownership rows past soft ceiling")
        XCTAssertEqual(Set(loaded.map(\.pgid)), Set([1, 2, 3]))
        // Still within downgrade ceiling (256) with 3 rows.
        XCTAssertTrue(try store.isWithinDowngradeSafeCeiling())
    }

    func test_ownershipLedgerRetains257LiveRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-ledger-257-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ownership.json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let identity = ProviderProcessStartIdentity(seconds: 1, microseconds: 1)
        let base = Date(timeIntervalSince1970: 2_000)
        for pid in 1...257 {
            try store.append(SpawnedProcessTag(
                pgid: pid_t(pid),
                spawnedAt: base.addingTimeInterval(TimeInterval(pid)),
                ownerStartIdentity: identity,
                provider: .codex,
                managedKind: .provider,
                executablePath: "/opt/codex",
                startIdentity: identity,
                isolatedProcessGroup: pid_t(pid)
            ))
        }
        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 257)
        XCTAssertFalse(try store.isWithinDowngradeSafeCeiling(),
                       "257 live rows must fail downgrade preflight until swept")
        // File mode must stay owner-only.
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func test_periodicSweepPrunesExitedCurrentOwnerRowsButRetainsLateGroupMembers() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-ledger-current-owner-prune-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let ownerIdentity = ProviderProcessStartIdentity(seconds: 1, microseconds: 1)
        let rootIdentity = ProviderProcessStartIdentity(seconds: 2, microseconds: 1)
        let drained = SpawnedProcessTag(
            pgid: 41, spawnedAt: Date(), ownerPID: 700, ownerStartIdentity: ownerIdentity,
            provider: .codex, managedKind: .provider, executablePath: "/opt/codex",
            startIdentity: rootIdentity, isolatedProcessGroup: 41
        )
        let lateGroup = SpawnedProcessTag(
            pgid: 42, spawnedAt: Date(), ownerPID: 700, ownerStartIdentity: ownerIdentity,
            managedKind: .sidecar, executablePath: "/opt/RemoteCodeDistillService",
            startIdentity: rootIdentity, isolatedProcessGroup: 42
        )
        try store.replace([drained, lateGroup])

        var enumeratedGroups: [pid_t] = []
        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 700,
            minAge: 0,
            ownerIsAlive: { _ in true },
            ownerStartIdentity: { _ in ownerIdentity },
            processCommand: { _ in nil },
            processStartIdentity: { _ in nil },
            descendantPIDs: { _ in [] },
            processGroupMembers: { group in
                enumeratedGroups.append(group)
                return group == 42 ? [420] : []
            },
            processIsAlive: { _ in false },
            graceInterval: 0,
            wait: { _ in },
            sendSignal: { _, _ in XCTFail("current-owner rows must never be signalled"); return false }
        )

        XCTAssertEqual(result, ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: []))
        XCTAssertEqual(
            enumeratedGroups,
            [41, 42],
            "a dead current-owner root still requires exactly one group check before its row can be removed or retained"
        )
        XCTAssertEqual(try store.load(), [lateGroup],
                       "drained rows must not consume the bounded ledger, while late group descendants retain exact ownership")
    }

    func test_periodicSweepSkipsGroupEnumerationForLiveExactCurrentOwnerRoots() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-ledger-live-current-owner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let currentPID: pid_t = 700
        let ownerIdentity = ProviderProcessStartIdentity(seconds: 1, microseconds: 1)
        let rootIdentity = ProviderProcessStartIdentity(seconds: 2, microseconds: 1)
        let tags = (0..<32).map { offset in
            let pid = pid_t(10_000 + offset)
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
        var groupEnumerationCount = 0

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: currentPID,
            minAge: 0,
            ownerIsAlive: { _ in true },
            ownerStartIdentity: { pid in
                XCTAssertEqual(pid, currentPID)
                return ownerIdentity
            },
            processCommand: { _ in
                XCTFail("a live current-owner root needs no orphan command validation")
                return nil
            },
            processStartIdentity: { _ in rootIdentity },
            descendantPIDs: { _ in
                XCTFail("a live current-owner root needs no descendant enumeration")
                return []
            },
            processGroupMembers: { _ in
                groupEnumerationCount += 1
                return []
            },
            processIsAlive: { _ in true },
            graceInterval: 0,
            wait: { _ in XCTFail("a current-owner row must never enter signal grace") },
            sendSignal: { _, _ in
                XCTFail("a current-owner row must never be signalled")
                return false
            }
        )

        XCTAssertEqual(result, ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: []))
        XCTAssertEqual(
            groupEnumerationCount,
            0,
            "verified live roots are retained from their exact lifetime; scanning every system PID cannot affect that decision"
        )
        XCTAssertEqual(try store.load(), tags)
    }

    func test_periodicSweepSkipsGroupEnumerationWhileAnotherExactOwnerIsAlive() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-ledger-live-other-owner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let ownerIdentity = ProviderProcessStartIdentity(seconds: 3, microseconds: 1)
        let rootIdentity = ProviderProcessStartIdentity(seconds: 4, microseconds: 1)
        let tag = SpawnedProcessTag(
            pgid: 20_001,
            spawnedAt: Date(timeIntervalSince1970: 100),
            ownerPID: 701,
            ownerStartIdentity: ownerIdentity,
            provider: .claude,
            managedKind: .provider,
            executablePath: "/opt/claude",
            startIdentity: rootIdentity,
            isolatedProcessGroup: 20_001
        )
        try store.replace([tag])
        var groupEnumerationCount = 0

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 700,
            minAge: 0,
            ownerIsAlive: { $0 == tag.ownerPID },
            ownerStartIdentity: { $0 == tag.ownerPID ? ownerIdentity : nil },
            processCommand: { _ in
                XCTFail("a row protected by its exact live owner needs no orphan command validation")
                return nil
            },
            processStartIdentity: { _ in
                XCTFail("a row protected by its exact live owner needs no root validation")
                return nil
            },
            descendantPIDs: { _ in
                XCTFail("a row protected by its exact live owner needs no descendant enumeration")
                return []
            },
            processGroupMembers: { _ in
                groupEnumerationCount += 1
                return []
            },
            processIsAlive: { _ in true },
            graceInterval: 0,
            wait: { _ in XCTFail("a live-owner row must never enter signal grace") },
            sendSignal: { _, _ in
                XCTFail("a live-owner row must never be signalled")
                return false
            }
        )

        XCTAssertEqual(result, ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: []))
        XCTAssertEqual(groupEnumerationCount, 0)
        XCTAssertEqual(try store.load(), [tag])
    }

    private enum TestSessionGone: Error { case gone }
    private enum TestListFailure: Error { case failed }

    override func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    func test_largeWriteToLivePeerThatDoesNotReadTimesOutBoundedly() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let payload = Data(repeating: 0x78, count: 2 * 1_024 * 1_024)
        let startedAt = Date()
        XCTAssertThrowsError(
            try GuardedStdinWrite.write(
                payload,
                to: stdin.fileHandleForWriting,
                process: process,
                timeout: 0.05,
                notFound: { TestSessionGone.gone }
            )
        ) { error in
            guard case GuardedStdinWriteError.timedOut = error else {
                return XCTFail("a live non-reading peer must surface the bounded write timeout, got \(error)")
            }
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            0.75,
            "a payload larger than pipe capacity must not block the Agent App thread indefinitely"
        )
        XCTAssertTrue(process.isRunning, "the proof requires an alive peer that simply does not read stdin")
    }

    func test_boundedDrainReturnsAfterSIGABRTWhenDescendantKeepsPipeOpen() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30 & echo $!; kill -ABRT $$"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGABRT)
        let startedAt = Date()
        let tail = BoundedPipeDrain.readRemaining(
            from: stdout.fileHandleForReading,
            timeout: 0.05
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            0.75,
            "a crashed root must not wait for EOF from a descendant that inherited stdout"
        )

        let childPID = String(decoding: tail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \Character.isWhitespace)
            .compactMap { pid_t($0) }
            .first
        if let childPID { _ = Darwin.kill(childPID, SIGKILL) }
        XCTAssertNotNil(childPID, "the drain must preserve bytes written immediately before SIGABRT")
    }

    func test_corruptLedgerAppendFailsWithoutOverwritingEvidence() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-ledger-corrupt-\(UUID().uuidString).json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: file)
        let store = ProviderProcessOwnershipStore(fileURL: file)

        XCTAssertThrowsError(
            try store.append(SpawnedProcessTag(pgid: 41, spawnedAt: Date()))
        )
        XCTAssertEqual(
            try Data(contentsOf: file),
            corrupt,
            "append must retain the corrupt ledger byte-for-byte for diagnosis and recovery"
        )
    }

    func test_productionSweepPropagatesProcessListFailureAndRetainsLedger() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-ledger-list-failure-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let tag = SpawnedProcessTag(
            pgid: 42,
            spawnedAt: Date(timeIntervalSinceNow: -60),
            ownerPID: 700,
            executablePath: "/opt/provider"
        )
        try store.replace([tag])

        XCTAssertThrowsError(
            try ProviderProcessSweeper.terminatePersistedOrphanedProviderRuntimes(
                currentPID: 900,
                minAge: 0,
                store: store,
                processList: { throw TestListFailure.failed }
            )
        ) { error in
            XCTAssertTrue(error is TestListFailure)
        }
        XCTAssertEqual(try store.load(), [tag], "a failed process listing must not consume ownership rows")
    }

    func test_recycledOwnerPIDDoesNotProtectMatchingProviderLifetime() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-ledger-owner-reuse-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let oldOwner = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let newOwner = ProviderProcessStartIdentity(seconds: 20, microseconds: 1)
        let providerIdentity = ProviderProcessStartIdentity(seconds: 30, microseconds: 1)
        let tag = SpawnedProcessTag(
            pgid: 43,
            spawnedAt: Date(timeIntervalSince1970: 100),
            ownerPID: 700,
            ownerStartIdentity: oldOwner,
            provider: .grok,
            executablePath: "/opt/grok",
            startIdentity: providerIdentity
        )
        try store.replace([tag])
        var liveIdentity: ProviderProcessStartIdentity? = providerIdentity

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 900,
            minAge: 0,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { $0 == 700 },
            ownerStartIdentity: { _ in newOwner },
            processCommand: { _ in "/opt/grok agent" },
            processStartIdentity: { _ in liveIdentity },
            descendantPIDs: { _ in [] },
            processIsAlive: { _ in liveIdentity != nil },
            graceInterval: 0,
            wait: { _ in },
            sendSignal: { _, _ in liveIdentity = nil; return true }
        )

        XCTAssertEqual(result.terminatedPIDs, [43])
        XCTAssertTrue(try store.load().isEmpty)
    }

    func test_liveRootWithUnavailableCommandIsRetainedAndReported() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-ledger-command-failure-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let identity = ProviderProcessStartIdentity(seconds: 30, microseconds: 1)
        let tag = SpawnedProcessTag(
            pgid: 44,
            spawnedAt: Date(timeIntervalSince1970: 100),
            ownerPID: 700,
            ownerStartIdentity: ProviderProcessStartIdentity(seconds: 10, microseconds: 1),
            provider: .claude,
            executablePath: "/opt/claude",
            startIdentity: identity
        )
        try store.replace([tag])

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 900,
            minAge: 0,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { _ in false },
            processCommand: { _ in nil },
            processStartIdentity: { _ in identity },
            descendantPIDs: { _ in [] },
            processIsAlive: { _ in true },
            graceInterval: 0,
            wait: { _ in },
            sendSignal: { _, _ in XCTFail("unverified executable must not be signalled"); return false }
        )

        XCTAssertEqual(result.failedPIDs, [44])
        XCTAssertEqual(try store.load(), [tag])
    }

    func test_treeTrackerRetainsLateDescendantsAfterReparenting() {
        let rootIdentity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let childIdentity = ProviderProcessStartIdentity(seconds: 11, microseconds: 1)
        let lateIdentity = ProviderProcessStartIdentity(seconds: 12, microseconds: 1)
        let reparentedIdentity = ProviderProcessStartIdentity(seconds: 13, microseconds: 1)
        var identities: [pid_t: ProviderProcessStartIdentity] = [10: rootIdentity, 11: childIdentity]
        var descendants: [pid_t] = [10, 11]
        var groupMembers: [pid_t] = [10, 11]
        var tracker = ProcessTerminator.TreeTracker(
            root: 10,
            isolatedProcessGroup: 10,
            initialPIDs: [10, 11],
            identity: { identities[$0] }
        )

        identities[12] = lateIdentity
        identities[13] = reparentedIdentity
        descendants = [10, 12]
        groupMembers = [10, 11, 12, 13]
        tracker.refresh(
            descendants: { _ in descendants },
            processGroupMembers: { _ in groupMembers },
            identity: { identities[$0] }
        )

        identities[10] = nil
        descendants = []
        groupMembers = [11, 12, 13]
        tracker.refresh(
            descendants: { _ in descendants },
            processGroupMembers: { _ in groupMembers },
            identity: { identities[$0] }
        )

        XCTAssertEqual(
            tracker.survivingPIDs(identity: { identities[$0] }),
            [11, 12, 13],
            "deletion must retain known children and discover process-group members after the root is reparented away"
        )
    }

    func test_grokDiscoveryEnablesDurableProcessOwnershipTagging() {
        XCTAssertTrue(
            GrokACPAdapter.discoveryProcessOwnershipTaggingEnabled,
            "Grok model discovery must not opt out of the crash-recovery ownership ledger"
        )
    }

    func test_ownershipLedger_flockSerializesConcurrentAppendsWithoutLostUpdates() throws {
        // Differential proof: independent store instances share one ledger file and
        // must contend on flock (not a single NSLock). Every distinct pgid is retained.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-ledger-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ownership.json")
        let identity = ProviderProcessStartIdentity(seconds: 1, microseconds: 1)
        let base = Date(timeIntervalSince1970: 9_000)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ownership-concurrent", attributes: .concurrent)
        var errors = 0
        let errLock = NSLock()
        for pid in 1...40 {
            group.enter()
            queue.async {
                defer { group.leave() }
                // Independent instances so NSLock does not serialize flock contention.
                let store = ProviderProcessOwnershipStore(fileURL: file)
                let tag = SpawnedProcessTag(
                    pgid: pid_t(pid),
                    spawnedAt: base.addingTimeInterval(TimeInterval(pid)),
                    ownerStartIdentity: identity,
                    provider: .codex,
                    managedKind: .provider,
                    executablePath: "/opt/codex",
                    startIdentity: identity,
                    isolatedProcessGroup: pid_t(pid)
                )
                do {
                    try store.append(tag)
                } catch {
                    errLock.lock(); errors += 1; errLock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(errors, 0, "no concurrent append should fail")
        let loaded = try ProviderProcessOwnershipStore(fileURL: file).load()
        XCTAssertEqual(loaded.count, 40, "concurrent appends under flock must not lose rows")
        XCTAssertEqual(Set(loaded.map(\.pgid)).count, 40)
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }
}
