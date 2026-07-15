import XCTest
import Darwin
@testable import AgentRuntime
import CoreModel

final class ProcessLifecycleHardeningTests: XCTestCase {
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
