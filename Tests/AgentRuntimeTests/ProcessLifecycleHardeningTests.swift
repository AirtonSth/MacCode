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

    func test_ownershipLedgerDropsOldestRowsInsteadOfRefusingSpawn() throws {
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
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.pgid), [2, 3],
                       "overflow must keep the newest ownership rows and never refuse spawn")
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

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 700,
            minAge: 0,
            ownerIsAlive: { _ in true },
            ownerStartIdentity: { _ in ownerIdentity },
            processCommand: { _ in nil },
            processStartIdentity: { _ in nil },
            descendantPIDs: { _ in [] },
            processGroupMembers: { $0 == 42 ? [420] : [] },
            processIsAlive: { _ in false },
            graceInterval: 0,
            wait: { _ in },
            sendSignal: { _, _ in XCTFail("current-owner rows must never be signalled"); return false }
        )

        XCTAssertEqual(result, ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: []))
        XCTAssertEqual(try store.load(), [lateGroup],
                       "drained rows must not consume the bounded ledger, while late group descendants retain exact ownership")
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
}
