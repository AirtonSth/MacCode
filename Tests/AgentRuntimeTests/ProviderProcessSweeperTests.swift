import XCTest
@testable import AgentRuntime

final class ProviderProcessSweeperTests: XCTestCase {
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

}
