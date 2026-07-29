import XCTest
import Darwin
import CoreModel
@testable import AgentRuntime

// Tests for the setpgid-based spawn tagging and periodic orphan sweep.
//
// WHY these tests exist:
//   Orphan provider processes were only swept at app launch (ppid==1 heuristic).
//   Processes spawned by claude --print / codex exec that detach mid-run escape
//   that heuristic because their ppid drifts before the next launch sweep.
//   setpgid(pid, 0) makes the child its own process-group leader; a periodic
//   sweeper can match by pgid even after reparenting, and the age gate prevents
//   killing a process that is legitimately still running its first turn.
final class ProviderSpawnTagTests: ProviderProcessTestCase {

    func test_installedProviderRootsAreReapedFromPersistedLedgerAfterForceQuit() throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_PROVIDER_SWEEP_GATE"] == "1" else {
            throw XCTSkip("Set RC_REAL_PROVIDER_SWEEP_GATE=1 to run the installed provider force-quit/relaunch gate.")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let codex = try XCTUnwrap(ProcessLocator.resolve("codex"))
        let node = try XCTUnwrap(ProcessLocator.resolve("node"))
        let grok = try XCTUnwrap(ProcessLocator.resolve("grok"))
        let bridgeCache: URL
        if let override = ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_CACHE"], !override.isEmpty {
            bridgeCache = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            bridgeCache = try XCTUnwrap(
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            )
            .appendingPathComponent("RemoteCode/AgentRuntime/ClaudeAgentSDKBridge", isDirectory: true)
        }
        let bridge = bridgeCache.appendingPathComponent("ClaudeAgentSDKBridge.mjs").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge))
        XCTAssertTrue(ClaudeAgentSDKBridgeAdapter.installedForkProtocolSupported(bridgeScriptPath: bridge))

        let specs: [(AgentProvider, String, [String])] = [
            (.codex, codex, ["app-server"]),
            (.claude, node, [bridge]),
            (.grok, grok, GrokACPClient.launchArguments),
        ]
        let processes = try specs.map { provider, executable, arguments -> (AgentProvider, Process, Pipe, Pipe, Pipe) in
            let process = Process()
            let standardInput = Pipe()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.standardInput = standardInput
            process.standardOutput = standardOutput
            process.standardError = standardError
            try process.run()
            return (provider, process, standardInput, standardOutput, standardError)
        }
        defer {
            for (_, process, _, _, _) in processes where process.isRunning { process.terminate() }
        }
        Thread.sleep(forTimeInterval: 0.5)
        let exitedDiagnostics = processes.compactMap { provider, process, _, _, standardError -> String? in
            guard !process.isRunning else { return nil }
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            return "\(provider.rawValue): exit=\(process.terminationStatus) stderr=\(String(decoding: data, as: UTF8.self))"
        }
        guard exitedDiagnostics.isEmpty else {
            XCTFail("each production provider root must remain alive while waiting on its stdio protocol: \(exitedDiagnostics.joined(separator: " | "))")
            return
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-tags-installed-sweep-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let deadOwnerPID = ProcessInfo.processInfo.processIdentifier + 100_000
        try store.replace(processes.map { provider, process, _, _, _ in
            SpawnedProcessTag(
                pgid: process.processIdentifier,
                spawnedAt: Date(timeIntervalSinceNow: -60),
                ownerPID: deadOwnerPID,
                provider: provider,
                executablePath: try XCTUnwrap(ProviderProcessExecutablePath.read(pid: process.processIdentifier)),
                startIdentity: try XCTUnwrap(ProviderProcessStartIdentity.read(pid: process.processIdentifier))
            )
        })

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: ProcessInfo.processInfo.processIdentifier,
            minAge: 0,
            ownerIsAlive: { _ in false },
            processCommand: { pid in Self.commandLine(pid: pid) },
            processStartIdentity: { ProviderProcessStartIdentity.read(pid: $0) },
            descendantPIDs: { _ in [] },
            processIsAlive: ProcessTerminator.isAlive,
            graceInterval: 0.2,
            wait: Thread.sleep(forTimeInterval:),
            sendSignal: { pid, signal in Darwin.kill(pid, signal) == 0 || errno == ESRCH }
        )

        let deadline = Date().addingTimeInterval(3)
        while processes.contains(where: { $0.1.isRunning }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let providerPIDs = Set(processes.map { $0.1.processIdentifier })
        let processEvidence = processes.map { provider, process, _, _, _ in
            "\(provider.rawValue)=\(process.processIdentifier) expected=\(ProviderProcessExecutablePath.read(pid: process.processIdentifier) ?? "dead") command=\(Self.commandLine(pid: process.processIdentifier) ?? "dead")"
        }.joined(separator: " | ")
        XCTAssertEqual(Set(result.orphanRootPIDs), providerPIDs,
                       "failed=\(result.failedPIDs) \(processEvidence)")
        XCTAssertEqual(Set(result.terminatedPIDs), providerPIDs,
                       "failed=\(result.failedPIDs) \(processEvidence)")
        XCTAssertTrue(processes.allSatisfy { !$0.1.isRunning })
        XCTAssertTrue(try store.load().isEmpty,
                      "relaunch sweep must remove every successfully reaped production-provider ledger row")
    }

    func test_realPersistedSweepTerminatesCodexClaudeAndGrokRootsButLeavesUntaggedProcessAlive() throws {
        let processes = try AgentProvider.allCases.map { provider -> (AgentProvider, Process) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            return (provider, process)
        }
        let untagged = Process()
        untagged.executableURL = URL(fileURLWithPath: "/bin/sleep")
        untagged.arguments = ["30"]
        try untagged.run()
        defer {
            for (_, process) in processes where process.isRunning { process.terminate() }
            if untagged.isRunning { untagged.terminate() }
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-tags-real-sweep-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let deadOwnerPID = ProcessInfo.processInfo.processIdentifier + 100_000
        try store.replace(processes.map { provider, process in
            SpawnedProcessTag(
                pgid: process.processIdentifier,
                spawnedAt: Date(timeIntervalSinceNow: -60),
                ownerPID: deadOwnerPID,
                provider: provider,
                executablePath: "/bin/sleep",
                startIdentity: try XCTUnwrap(ProviderProcessStartIdentity.read(pid: process.processIdentifier))
            )
        })

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: ProcessInfo.processInfo.processIdentifier,
            minAge: 0,
            ownerIsAlive: { _ in false },
            processCommand: { pid in Self.commandLine(pid: pid) },
            processStartIdentity: { ProviderProcessStartIdentity.read(pid: $0) },
            descendantPIDs: { _ in [] },
            processIsAlive: ProcessTerminator.isAlive,
            graceInterval: 0.05,
            wait: Thread.sleep(forTimeInterval:),
            sendSignal: { pid, signal in Darwin.kill(pid, signal) == 0 || errno == ESRCH }
        )

        let deadline = Date().addingTimeInterval(2)
        while processes.contains(where: { $0.1.isRunning }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let taggedPIDs = Set(processes.map { $0.1.processIdentifier })
        XCTAssertEqual(Set(result.orphanRootPIDs), taggedPIDs,
                       "force-quit recovery must recognize persisted roots for every Agent App provider")
        XCTAssertEqual(Set(result.terminatedPIDs), taggedPIDs)
        XCTAssertTrue(processes.allSatisfy { !$0.1.isRunning },
                      "Codex, Claude, and Grok tagged roots must all be dead before relaunch")
        XCTAssertTrue(untagged.isRunning,
                      "the sweep must never kill an untagged user-owned process with the same executable")
        XCTAssertTrue(try store.load().isEmpty,
                      "successfully reaped ownership records must not survive into the relaunched app")
    }

    func test_realTagProcessCapturesAndPersistsKernelStartIdentity() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let tag = try XCTUnwrap(ProcessSpawnTagger.tagProcess(process, provider: .grok))
        let kernelIdentity = try XCTUnwrap(
            ProviderProcessStartIdentity.read(pid: process.processIdentifier),
            "a live provider root must expose a kernel start identity immediately after spawn"
        )
        XCTAssertEqual(tag.startIdentity, kernelIdentity,
                       "the durable ownership tag must identify the exact process lifetime, not only its recyclable PID")
        XCTAssertEqual(tag.executablePath, "/bin/sleep")
        XCTAssertEqual(tag.provider, .grok)

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-tag-identity-roundtrip-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        try store.replace([tag])
        XCTAssertEqual(try store.load(), [tag],
                       "kernel start identity must survive the exact JSON ledger round trip used across app relaunches")
    }

    func test_realSidecarTagPersistsExactManagedKindAndLifetime() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let tag = try ProcessSpawnTagger.tagProcess(process, managedKind: .sidecar)

        XCTAssertEqual(tag.managedKind, .sidecar)
        XCTAssertNil(tag.provider)
        XCTAssertNotNil(tag.startIdentity)
        XCTAssertEqual(tag.isolatedProcessGroup, process.processIdentifier)
        XCTAssertTrue(
            try XCTUnwrap(ProviderProcessOwnership.shared.store()).load().contains(tag),
            "the sidecar must enter the same durable exact-identity ledger used for provider crash recovery"
        )
    }

    func test_foreignUserLaunchStillCapturesRealIdentityWhenChildIsReadable() throws {
        // WHY: the run-as-user relaxation must only DROP TO owner-anchoring when the
        // child is genuinely unreadable. A readable child (same-user, e.g. a dev
        // machine where sudo isn't yet gating uid) must still get its exact kernel
        // identity + exec path recorded, so the flag never silently weakens a row
        // that could have been fully certified.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let tag = try XCTUnwrap(
            ProcessSpawnTagger.tagProcess(process, provider: .claude, foreignUserLaunch: true)
        )
        let kernelIdentity = try XCTUnwrap(
            ProviderProcessStartIdentity.read(pid: process.processIdentifier)
        )
        XCTAssertEqual(tag.startIdentity, kernelIdentity,
                       "a readable child must keep its exact lifetime even under foreignUserLaunch")
        XCTAssertEqual(tag.executablePath, "/bin/sleep")
        XCTAssertNotNil(tag.isolatedProcessGroup,
                        "a readable child's isolated group must still be certified")
    }

    func test_ownerAnchoredForeignUserRowIsRetainedNotReapedAfterOwnerCrash() throws {
        // WHY: a run-as-user (sudo) child yields an owner-anchored row with no child
        // start identity. After an app crash the sweep MUST NOT signal a PID it
        // cannot identify — the recovered lifetime could belong to anyone by then.
        // The guarantee is fail-safe retention, never mis-reap.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("owner-anchored-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let old = Date(timeIntervalSince1970: 100)
        let ownerAnchored = SpawnedProcessTag(
            pgid: 4242,
            spawnedAt: old,
            ownerPID: 900,
            ownerStartIdentity: ProviderProcessStartIdentity(seconds: 5, microseconds: 5),
            provider: .claude,
            executablePath: "",
            startIdentity: nil,
            isolatedProcessGroup: nil
        )
        try store.replace([ownerAnchored])
        var signals: [(pid_t, Int32)] = []

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 1,
            minAge: 30,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { _ in false },              // owner (app) crashed
            ownerStartIdentity: { _ in nil },
            processCommand: { _ in "/usr/bin/sudo -u dev -- claude --print" },
            processStartIdentity: { _ in ProviderProcessStartIdentity(seconds: 42, microseconds: 42) },
            descendantPIDs: { _ in [] },
            processIsAlive: { $0 == 4242 },            // root still alive
            graceInterval: 0,
            wait: { _ in },
            sendSignal: { pid, signal in signals.append((pid, signal)); return true }
        )

        XCTAssertTrue(signals.isEmpty,
                      "an unidentifiable owner-anchored root must never be signalled")
        XCTAssertEqual(result.terminatedPIDs, [])
        XCTAssertEqual(result.failedPIDs, [4242])
        XCTAssertEqual(try store.load(), [ownerAnchored],
                       "the fail-safe row must survive so a later relaunch can retry")
    }

    func test_unconfiguredOwnershipStoreFailsClosed() throws {
        // WHY: launch recovery may spawn a provider before AppDelegate finishes
        // wiring diagnostics. Accepting that spawn without a durable ownership
        // row would make force-quit cleanup impossible.
        let ownership = ProviderProcessOwnership()
        let tag = SpawnedProcessTag(
            pgid: 42,
            spawnedAt: Date(timeIntervalSince1970: 1),
            ownerPID: 7,
            provider: .codex
        )

        XCTAssertThrowsError(try ownership.record(tag)) { error in
            XCTAssertEqual(error as? ProviderProcessOwnershipError, .storeNotConfigured)
        }
    }

    func test_processGroupCertificationFailsClosedWhenRootIsNotGroupLeader() {
        var attemptedPID: pid_t?

        XCTAssertThrowsError(try ProcessSpawnTagger.certifyIsolatedProcessGroup(
            pid: 42,
            setProcessGroup: { pid in
                attemptedPID = pid
                return -1
            },
            processGroup: { _ in 7 }
        )) { error in
            XCTAssertEqual(
                error as? ProviderProcessOwnershipError,
                .isolatedProcessGroupUnavailable(42)
            )
        }
        XCTAssertEqual(attemptedPID, 42,
                       "tagging must attempt isolation before accepting durable ownership")
    }

    func test_processGroupCertificationAcceptsOnlyExactKernelGroupIdentity() throws {
        let group = try ProcessSpawnTagger.certifyIsolatedProcessGroup(
            pid: 42,
            setProcessGroup: { _ in 0 },
            processGroup: { _ in 42 }
        )

        XCTAssertEqual(group, 42)
    }

    func test_persistedOwnershipSweepReapsOnlyDeadRemoteCodeOwnerWithMatchingExecutable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("provider-tags-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let old = Date(timeIntervalSince1970: 100)
        let codexIdentity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let claudeIdentity = ProviderProcessStartIdentity(seconds: 20, microseconds: 2)
        try store.replace([
            SpawnedProcessTag(pgid: 41, spawnedAt: old, ownerPID: 700, provider: .codex, executablePath: "/opt/bin/codex", startIdentity: codexIdentity),
            SpawnedProcessTag(pgid: 42, spawnedAt: old, ownerPID: 900, provider: .claude, executablePath: "/opt/bin/claude", startIdentity: claudeIdentity)
        ])
        var identities: [pid_t: ProviderProcessStartIdentity] = [41: codexIdentity, 42: claudeIdentity]
        var signals: [(pid_t, Int32)] = []

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 900,
            minAge: 30,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { _ in false },
            processCommand: { pid in pid == 41 ? "/opt/bin/codex app-server" : "/opt/bin/claude --print" },
            processStartIdentity: { identities[$0] },
            descendantPIDs: { _ in [] },
            processIsAlive: { identities[$0] != nil },
            graceInterval: 0,
            wait: { _ in },
            sendSignal: { pid, signal in
                signals.append((pid, signal))
                identities[pid] = nil
                return true
            }
        )

        XCTAssertEqual(result.terminatedPIDs, [41],
                       "only a tagged process owned by a dead prior RemoteCode instance may be reaped")
        XCTAssertEqual(signals.map(\.0), [41])
        XCTAssertEqual(signals.map(\.1), [SIGTERM])
        XCTAssertEqual(try store.load().map(\.pgid), [42],
                       "the current app owner's live provider tag must remain registered")
    }

    func test_persistedOwnershipSweepMatchesKernelInterpreterWhenPSUsesBasename() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-tags-interpreter-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let identity = ProviderProcessStartIdentity(seconds: 30, microseconds: 3)
        try store.replace([
            SpawnedProcessTag(
                pgid: 51,
                spawnedAt: Date(timeIntervalSince1970: 100),
                ownerPID: 700,
                provider: .codex,
                executablePath: "/opt/homebrew/Cellar/node/26.3.1/bin/node",
                startIdentity: identity
            )
        ])
        var liveIdentity: ProviderProcessStartIdentity? = identity

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 900,
            minAge: 0,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { _ in false },
            processCommand: { _ in "node /opt/homebrew/bin/codex app-server" },
            processStartIdentity: { _ in liveIdentity },
            descendantPIDs: { _ in [] },
            processIsAlive: { _ in liveIdentity != nil },
            graceInterval: 0,
            wait: { _ in },
            sendSignal: { _, _ in liveIdentity = nil; return true }
        )

        XCTAssertEqual(result.terminatedPIDs, [51],
                       "a shebang provider must match the exact kernel interpreter even when ps renders only its basename")
        XCTAssertTrue(try store.load().isEmpty)
    }

    func test_persistedOwnershipSweepDoesNotKillRecycledPIDWithSameExecutableButDifferentStartIdentity() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("provider-tags-recycled-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let originalIdentity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let recycledIdentity = ProviderProcessStartIdentity(seconds: 20, microseconds: 2)
        try store.replace([
            SpawnedProcessTag(
                pgid: 51,
                spawnedAt: Date(timeIntervalSince1970: 100),
                ownerPID: 700,
                provider: .grok,
                executablePath: "/Users/me/.grok/bin/grok",
                startIdentity: originalIdentity
            )
        ])
        var signals: [(pid_t, Int32)] = []

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 900,
            minAge: 0,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { _ in false },
            processCommand: { _ in "/Users/me/.grok/bin/grok run" },
            processStartIdentity: { _ in recycledIdentity },
            descendantPIDs: { _ in [] },
            processIsAlive: { _ in true },
            graceInterval: 0,
            wait: { _ in },
            sendSignal: { signals.append(($0, $1)); return true }
        )

        XCTAssertTrue(result.orphanRootPIDs.isEmpty)
        XCTAssertTrue(signals.isEmpty,
                      "a stale tag must never kill a recycled pid even when its executable path is identical")
        XCTAssertTrue(try store.load().isEmpty,
                      "mismatched stale tags should be discarded instead of retried forever")
    }

    func test_persistedOwnershipSweepPreservesTagAppendedWhileSweepIsInFlight() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("provider-tags-concurrent-append-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let oldIdentity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let newIdentity = ProviderProcessStartIdentity(seconds: 20, microseconds: 2)
        let oldTag = SpawnedProcessTag(
            pgid: 51,
            spawnedAt: Date(timeIntervalSince1970: 100),
            ownerPID: 700,
            provider: .codex,
            executablePath: "/opt/bin/codex",
            startIdentity: oldIdentity
        )
        let newTag = SpawnedProcessTag(
            pgid: 52,
            spawnedAt: Date(timeIntervalSince1970: 199),
            ownerPID: 900,
            provider: .claude,
            executablePath: "/opt/bin/claude",
            startIdentity: newIdentity
        )
        try store.replace([oldTag])
        var liveIdentities: [pid_t: ProviderProcessStartIdentity] = [51: oldIdentity, 52: newIdentity]
        var appended = false

        _ = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 900,
            minAge: 0,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { _ in false },
            processCommand: { pid in pid == 51 ? "/opt/bin/codex app-server" : "/opt/bin/claude --print" },
            processStartIdentity: { liveIdentities[$0] },
            descendantPIDs: { _ in [] },
            processIsAlive: { liveIdentities[$0] != nil },
            graceInterval: 0,
            wait: { _ in
                guard !appended else { return }
                appended = true
                try? store.append(newTag)
            },
            sendSignal: { pid, _ in liveIdentities[pid] = nil; return true }
        )

        XCTAssertEqual(try store.load(), [newTag],
                       "committing an old sweep snapshot must not erase a process recorded during that sweep")
    }

    func test_persistedOwnershipSweepPreservesReusedPIDTagRecordedWhileSweepIsInFlight() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("provider-tags-concurrent-reuse-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let oldIdentity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let replacementIdentity = ProviderProcessStartIdentity(seconds: 30, microseconds: 3)
        let oldTag = SpawnedProcessTag(
            pgid: 61,
            spawnedAt: Date(timeIntervalSince1970: 100),
            ownerPID: 700,
            provider: .grok,
            executablePath: "/opt/bin/grok",
            startIdentity: oldIdentity
        )
        let replacementTag = SpawnedProcessTag(
            pgid: 61,
            spawnedAt: Date(timeIntervalSince1970: 199),
            ownerPID: 900,
            provider: .grok,
            executablePath: "/opt/bin/grok",
            startIdentity: replacementIdentity
        )
        try store.replace([oldTag])
        var liveIdentity: ProviderProcessStartIdentity? = oldIdentity
        var appended = false

        _ = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 900,
            minAge: 0,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { _ in false },
            processCommand: { _ in "/opt/bin/grok agent" },
            processStartIdentity: { _ in liveIdentity },
            descendantPIDs: { _ in [] },
            processIsAlive: { _ in liveIdentity != nil },
            graceInterval: 0,
            wait: { _ in
                guard !appended else { return }
                appended = true
                liveIdentity = replacementIdentity
                try? store.append(replacementTag)
            },
            sendSignal: { _, _ in return true }
        )

        XCTAssertEqual(try store.load(), [replacementTag],
                       "a new process lifetime that reuses the swept PID must remain owned")
    }

    func test_persistedOwnershipSweepEscalatesTermIgnoringTreeAndClearsLedgerOnlyAfterEveryIdentityDies() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("provider-tags-escalation-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let rootIdentity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let childIdentity = ProviderProcessStartIdentity(seconds: 11, microseconds: 1)
        let grandchildIdentity = ProviderProcessStartIdentity(seconds: 12, microseconds: 1)
        try store.replace([
            SpawnedProcessTag(
                pgid: 61,
                spawnedAt: Date(timeIntervalSince1970: 100),
                ownerPID: 700,
                provider: .claude,
                executablePath: "/opt/bin/claude",
                startIdentity: rootIdentity
            )
        ])
        var identities: [pid_t: ProviderProcessStartIdentity] = [
            61: rootIdentity,
            62: childIdentity,
            63: grandchildIdentity,
            99: ProviderProcessStartIdentity(seconds: 99, microseconds: 1)
        ]
        var signals: [(pid_t, Int32)] = []
        var waitCount = 0

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 900,
            minAge: 0,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { _ in false },
            processCommand: { _ in "/opt/bin/claude --print" },
            processStartIdentity: { identities[$0] },
            descendantPIDs: { _ in [62, 63] },
            processIsAlive: { identities[$0] != nil },
            graceInterval: 0.25,
            wait: { _ in
                waitCount += 1
                if waitCount == 1 {
                    identities[62] = nil // cooperative child exits during TERM grace
                }
            },
            sendSignal: { pid, signal in
                signals.append((pid, signal))
                if signal == SIGKILL { identities[pid] = nil }
                return true
            }
        )

        XCTAssertEqual(result.orphanRootPIDs, [61])
        XCTAssertEqual(result.terminatedPIDs, [61])
        XCTAssertTrue(result.failedPIDs.isEmpty)
        XCTAssertEqual(signals.filter { $0.1 == SIGTERM }.map(\.0), [63, 62, 61],
                       "TERM must cover descendants children-first before the owned root")
        XCTAssertEqual(signals.filter { $0.1 == SIGKILL }.map(\.0), [63, 61],
                       "only TERM survivors with the same start identity may receive KILL")
        XCTAssertFalse(signals.contains { $0.0 == 99 },
                       "an unrelated live process outside the persisted root tree must survive every signal phase")
        XCTAssertNotNil(identities[99])
        XCTAssertEqual(waitCount, 2, "the sweep must bound both TERM grace and post-KILL confirmation")
        XCTAssertTrue(try store.load().isEmpty,
                      "the ownership row may be removed only after root and descendants are confirmed dead")
    }

    func test_persistedOwnershipSweepRetainsLedgerWhenSigkillSurvivorStillHasSameIdentity() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("provider-tags-survivor-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let identity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let tag = SpawnedProcessTag(
            pgid: 71,
            spawnedAt: Date(timeIntervalSince1970: 100),
            ownerPID: 700,
            provider: .codex,
            executablePath: "/opt/bin/codex",
            startIdentity: identity
        )
        try store.replace([tag])
        var signals: [(pid_t, Int32)] = []

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 900,
            minAge: 0,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { _ in false },
            processCommand: { _ in "/opt/bin/codex app-server" },
            processStartIdentity: { _ in identity },
            descendantPIDs: { _ in [] },
            processIsAlive: { _ in true },
            graceInterval: 0,
            wait: { _ in },
            sendSignal: { signals.append(($0, $1)); return true }
        )

        XCTAssertEqual(signals.map(\.1), [SIGTERM, SIGKILL])
        XCTAssertEqual(result.failedPIDs, [71])
        XCTAssertTrue(result.terminatedPIDs.isEmpty)
        XCTAssertEqual(try store.load(), [tag],
                       "a still-live owned identity must remain in the ledger for a later retry")
    }

    func test_persistedOwnershipSweepReapsVerifiedGroupMembersAfterLeaderExit() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("provider-tags-dead-leader-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let leaderIdentity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let childIdentity = ProviderProcessStartIdentity(seconds: 11, microseconds: 1)
        let tag = SpawnedProcessTag(
            pgid: 81,
            spawnedAt: Date(timeIntervalSince1970: 100),
            ownerPID: 700,
            provider: .claude,
            executablePath: "/opt/bin/node",
            startIdentity: leaderIdentity,
            isolatedProcessGroup: 81
        )
        try store.replace([tag])
        var identities: [pid_t: ProviderProcessStartIdentity] = [82: childIdentity]
        var signals: [(pid_t, Int32)] = []

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 900,
            minAge: 0,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { _ in false },
            processCommand: { _ in nil },
            processStartIdentity: { identities[$0] },
            descendantPIDs: { _ in [] },
            processGroupMembers: { $0 == 81 ? [82] : [] },
            processIsAlive: { identities[$0] != nil },
            graceInterval: 0,
            wait: { _ in },
            sendSignal: { pid, signal in
                signals.append((pid, signal))
                identities[pid] = nil
                return true
            }
        )

        XCTAssertEqual(signals.map(\.0), [82],
                       "a verified provider group must remain recoverable after its leader exits and its child reparents")
        XCTAssertEqual(signals.map(\.1), [SIGTERM])
        XCTAssertEqual(result.terminatedPIDs, [81])
        XCTAssertTrue(try store.load().isEmpty,
                      "the group ownership row may clear only after every surviving member is confirmed dead")
    }

    func test_persistedOwnershipSweepRetainsLedgerWhenIdentityReadFailsForLiveRoot() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("provider-tags-unverified-\(UUID().uuidString).json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let identity = ProviderProcessStartIdentity(seconds: 10, microseconds: 1)
        let tag = SpawnedProcessTag(
            pgid: 81,
            spawnedAt: Date(timeIntervalSince1970: 100),
            ownerPID: 700,
            provider: .grok,
            executablePath: "/opt/bin/grok",
            startIdentity: identity
        )
        try store.replace([tag])
        var signals: [(pid_t, Int32)] = []

        let result = try ProviderProcessSweeper.sweepPersistedOrphans(
            store: store,
            currentPID: 900,
            minAge: 0,
            now: Date(timeIntervalSince1970: 200),
            ownerIsAlive: { _ in false },
            processCommand: { _ in "/opt/bin/grok run" },
            processStartIdentity: { _ in nil },
            descendantPIDs: { _ in [] },
            processIsAlive: { _ in true },
            graceInterval: 0,
            wait: { _ in },
            sendSignal: { signals.append(($0, $1)); return true }
        )

        XCTAssertTrue(signals.isEmpty,
                      "the sweeper must fail safe when it cannot verify a live PID's start identity")
        XCTAssertTrue(result.orphanRootPIDs.isEmpty)
        XCTAssertEqual(result.failedPIDs, [81],
                       "an unverifiable live ownership row must be surfaced for diagnostics and retry")
        XCTAssertEqual(try store.load(), [tag],
                       "a live but temporarily unverifiable root is not confirmed dead and must remain retryable")
    }

    // MARK: - SpawnedProcessTag construction

    func test_spawnedProcessTag_storesFields() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tag = SpawnedProcessTag(pgid: 42, spawnedAt: now)

        XCTAssertEqual(tag.pgid, 42)
        XCTAssertEqual(tag.spawnedAt, now)
    }

    func test_spawnedProcessTag_equality() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = SpawnedProcessTag(pgid: 99, spawnedAt: now)
        let b = SpawnedProcessTag(pgid: 99, spawnedAt: now)
        let c = SpawnedProcessTag(pgid: 100, spawnedAt: now)

        XCTAssertEqual(a, b, "identical pgid+spawnedAt must be equal")
        XCTAssertNotEqual(a, c, "different pgid must not be equal")
    }

    // MARK: - isEligibleForReap: pure decision logic

    func test_eligibility_taggedOldAlive_isReapable() {
        // WHY: the core contract — a process tagged at spawn, older than minAge,
        // and still alive must be flagged for reap so the periodic sweeper kills it.
        let spawnedAt = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 60) // 60 s > 30 s defaultMinAge

        let eligible = ProcessSpawnTagger.isEligibleForReap(
            pgid: 1234,
            spawnedAt: spawnedAt,
            minAge: 30,
            isAlive: { _ in true },
            now: now
        )

        XCTAssertTrue(eligible, "tagged + old + alive must be reapable")
    }

    func test_eligibility_untagged_notReaped() {
        // WHY: processes NOT recorded by tagProcess have no SpawnedProcessTag entry
        // and therefore never appear in the sweeper's tag list — this test documents
        // that the sweeper is opt-in via tagging, not command-line heuristic.
        // The helper itself requires a tag to call, so an empty tag list produces
        // no reap candidates.
        let now = Date(timeIntervalSince1970: 60)

        let result = ProviderProcessSweeper.sweepTaggedOrphans(
            tags: [],   // no tags -> nothing eligible
            minAge: 30,
            isAlive: { _ in true },
            processStartIdentity: { _ in nil },
            now: now,
            terminate: { _ in true }
        )

        XCTAssertTrue(result.orphanRootPIDs.isEmpty, "no tags -> no orphan candidates")
        XCTAssertTrue(result.terminatedPIDs.isEmpty)
    }

    func test_eligibility_fresh_notReaped() {
        // WHY: a process spawned < minAge ago must not be reaped — it may be actively
        // running its first turn. The age gate prevents killing live work.
        let spawnedAt = Date(timeIntervalSince1970: 50)
        let now = Date(timeIntervalSince1970: 60) // only 10 s old < 30 s minAge

        let eligible = ProcessSpawnTagger.isEligibleForReap(
            pgid: 777,
            spawnedAt: spawnedAt,
            minAge: 30,
            isAlive: { _ in true },
            now: now
        )

        XCTAssertFalse(eligible, "fresh process (age < minAge) must NOT be reapable")
    }

    func test_eligibility_dead_notReaped() {
        // WHY: a process that already exited must not be re-signalled — avoids
        // racing a recycled pid that belongs to an unrelated process.
        let spawnedAt = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 120)

        let eligible = ProcessSpawnTagger.isEligibleForReap(
            pgid: 888,
            spawnedAt: spawnedAt,
            minAge: 30,
            isAlive: { _ in false },
            now: now
        )

        XCTAssertFalse(eligible, "dead process must NOT be reapable (avoid pid recycling race)")
    }

    func test_eligibility_exactlyAtMinAge_isReapable() {
        // WHY: boundary condition — a process aged exactly minAge seconds is eligible.
        let spawnedAt = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 30) // exactly 30 s == minAge

        let eligible = ProcessSpawnTagger.isEligibleForReap(
            pgid: 555,
            spawnedAt: spawnedAt,
            minAge: 30,
            isAlive: { _ in true },
            now: now
        )

        XCTAssertTrue(eligible, "process aged exactly minAge must be reapable (>= boundary)")
    }

    // MARK: - sweepTaggedOrphans: periodic sweep integration

    func test_sweep_reapsMixedTagSet() {
        // WHY: validates that the periodic sweeper correctly separates eligible from
        // ineligible tags in a mixed batch (old vs fresh, alive vs dead).
        let base = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 120)
        let identity = ProviderProcessStartIdentity(seconds: 1, microseconds: 1)

        let tags: [SpawnedProcessTag] = [
            SpawnedProcessTag(pgid: 10, spawnedAt: base, startIdentity: identity),
            SpawnedProcessTag(pgid: 20, spawnedAt: Date(timeIntervalSince1970: 110), startIdentity: identity),
            SpawnedProcessTag(pgid: 30, spawnedAt: base, startIdentity: identity),
        ]

        let aliveSet: Set<pid_t> = [10, 20] // 30 is dead
        var terminated: [pid_t] = []

        let result = ProviderProcessSweeper.sweepTaggedOrphans(
            tags: tags,
            minAge: 30,
            isAlive: { aliveSet.contains($0) },
            processStartIdentity: { aliveSet.contains($0) ? identity : nil },
            now: now,
            terminate: { pid in terminated.append(pid); return true }
        )

        XCTAssertEqual(result.orphanRootPIDs, [10],
                       "only the old+alive tag must be an orphan candidate")
        XCTAssertEqual(result.terminatedPIDs, [10],
                       "terminate must be called for the eligible pgid")
        XCTAssertFalse(terminated.contains(20), "fresh process must not be terminated")
        XCTAssertFalse(terminated.contains(30), "dead process must not be terminated (pid recycling guard)")
    }

    func test_sweep_terminateFailureRecordedInFailed() {
        // WHY: if killpg fails (e.g. EPERM) the pgid must appear in failedPIDs so
        // the caller can log/retry; it must NOT appear in terminatedPIDs.
        let base = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 120)
        let identity = ProviderProcessStartIdentity(seconds: 1, microseconds: 1)
        let tags = [SpawnedProcessTag(pgid: 99, spawnedAt: base, startIdentity: identity)]

        let result = ProviderProcessSweeper.sweepTaggedOrphans(
            tags: tags,
            minAge: 30,
            isAlive: { _ in true },
            processStartIdentity: { _ in identity },
            now: now,
            terminate: { _ in false } // simulate killpg failure
        )

        XCTAssertEqual(result.orphanRootPIDs, [99])
        XCTAssertEqual(result.failedPIDs, [99], "failed terminate must be recorded in failedPIDs")
        XCTAssertTrue(result.terminatedPIDs.isEmpty)
    }

    func test_sweep_orphanRootPIDsAreSorted() {
        // WHY: deterministic output simplifies logging and idempotent retry logic.
        let base = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 120)
        let identity = ProviderProcessStartIdentity(seconds: 1, microseconds: 1)
        let tags = [
            SpawnedProcessTag(pgid: 300, spawnedAt: base, startIdentity: identity),
            SpawnedProcessTag(pgid: 100, spawnedAt: base, startIdentity: identity),
            SpawnedProcessTag(pgid: 200, spawnedAt: base, startIdentity: identity),
        ]

        let result = ProviderProcessSweeper.sweepTaggedOrphans(
            tags: tags,
            minAge: 30,
            isAlive: { _ in true },
            processStartIdentity: { _ in identity },
            now: now,
            terminate: { _ in true }
        )

        XCTAssertEqual(result.orphanRootPIDs, [100, 200, 300],
                       "orphan root PIDs must be sorted ascending for deterministic output")
    }

    // MARK: - SpawnedProcessTag does not regress ProcessTerminator

    func test_terminationPlanUnaffectedBySpawnTagAddition() {
        // WHY: regression guard — SpawnedProcessTag/ProcessSpawnTagger additions must
        // not change the SIGTERM->SIGKILL plan used by terminateTree.
        let pids: [Int32] = [10, 20, 30]

        let phase1 = ProcessTerminator.terminationPlan(
            pids: pids,
            isAlive: { _ in true },
            graceElapsed: false
        )
        let phase2 = ProcessTerminator.terminationPlan(
            pids: pids,
            isAlive: { $0 == 20 },
            graceElapsed: true
        )

        XCTAssertEqual(phase1.map(\.signal), [SIGTERM, SIGTERM, SIGTERM],
                       "phase 1 must send SIGTERM to all pids (spawn tag must not affect this)")
        XCTAssertEqual(phase2, [ProcessTerminationStep(pid: 20, signal: SIGKILL)],
                       "phase 2 must SIGKILL only survivors (spawn tag must not affect this)")
    }

    private static func commandLine(pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let command = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}
