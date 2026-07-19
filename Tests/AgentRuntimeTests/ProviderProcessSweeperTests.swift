import XCTest
@testable import AgentRuntime

final class ProviderProcessSweeperTests: XCTestCase {
    func test_parsePSRowPreservesCommandWithSpaces() {
        let row: Substring = "  101     1  22048 /opt/homebrew/bin/node /Users/me/Library/Application Support/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/ClaudeAgentSDKBridge.mjs"

        let process = ProviderProcessSweeper.parsePSRow(row)

        XCTAssertEqual(process, ProviderRuntimeProcess(
            pid: 101,
            ppid: 1,
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

    func test_terminateDistillServers_keepsOnlyOneServerAndLeavesMCPAlone() {
        // WHY: only one multi-GB MLX server may exist; agent `| distill` mcp
        // helpers are multi-instance and must survive the singleton reap.
        let currentPID: Int32 = 500
        let keepPID: Int32 = 801
        let processes = [
            ProviderRuntimeProcess(
                pid: 701,
                ppid: 1,
                rssKB: 4_000_000,
                command: "/App/RemoteCodeDistillService --auth-token OLD --port 0"
            ),
            ProviderRuntimeProcess(
                pid: keepPID,
                ppid: currentPID,
                rssKB: 2_000_000,
                command: "/App/RemoteCodeDistillService --auth-token LIVE --port 0"
            ),
            ProviderRuntimeProcess(
                pid: 901,
                ppid: currentPID,
                rssKB: 25_000,
                command: "/App/RemoteCodeDistillService mcp"
            ),
            ProviderRuntimeProcess(
                pid: 902,
                ppid: 1200,
                rssKB: 25_000,
                command: "/other/RemoteCodeDistillService mcp"
            ),
        ]
        var terminated: [Int32] = []
        let result = ProviderProcessSweeper.terminateDistillServers(
            processes: processes,
            keepPID: keepPID,
            currentPID: currentPID
        ) { pid in
            terminated.append(pid)
            return true
        }
        XCTAssertEqual(result.orphanRootPIDs, [701],
                       "only non-keep Distill servers are singleton reap roots")
        XCTAssertEqual(Set(terminated), Set([701]),
                       "foreign MLX server must be terminated")
        XCTAssertFalse(terminated.contains(keepPID),
                       "controller's live child must survive")
        XCTAssertFalse(terminated.contains(901),
                       "own-tree mcp helper must not be killed as a server")
        XCTAssertFalse(terminated.contains(902),
                       "foreign mcp helpers must not be killed as servers")
    }

    func test_terminateDistillServers_onQuitKillsAllServers() {
        let currentPID: Int32 = 500
        let processes = [
            ProviderRuntimeProcess(
                pid: 801,
                ppid: currentPID,
                rssKB: 2_000_000,
                command: "/App/RemoteCodeDistillService --auth-token LIVE --port 0"
            ),
            ProviderRuntimeProcess(
                pid: 701,
                ppid: 1,
                rssKB: 4_000_000,
                command: "/App/RemoteCodeDistillService --auth-token ORPHAN --port 0"
            ),
            ProviderRuntimeProcess(
                pid: 901,
                ppid: currentPID,
                rssKB: 25_000,
                command: "/App/RemoteCodeDistillService mcp"
            ),
        ]
        var terminated: [Int32] = []
        let result = ProviderProcessSweeper.terminateDistillServers(
            processes: processes,
            keepPID: nil,
            currentPID: currentPID
        ) { pid in
            terminated.append(pid)
            return true
        }
        XCTAssertEqual(Set(result.orphanRootPIDs), Set([701, 801]),
                       "quit must target every Distill MLX server")
        XCTAssertEqual(Set(terminated), Set([701, 801]),
                       "quit must terminate every Distill MLX server")
        XCTAssertFalse(terminated.contains(901),
                       "quit must not kill mcp CLI helpers as servers")
    }

    func test_orphanSidecarSweepTerminatesLaunchdReparentedDistillOnly() {
        // WHY: multi-GB RemoteCodeDistillService processes reparented to launchd
        // after a host crash permanently pin RAM and freeze the Mac. The sweep
        // must kill those orphans without touching the current app's live child
        // or unrelated binaries whose argv merely mentions Distill.
        let currentPID: Int32 = 500
        let processes = [
            ProviderRuntimeProcess(
                pid: 701,
                ppid: 1,
                rssKB: 4_400_000,
                command: "/Users/me/dev/remote-code/macos-app/dist/RemoteCode.app/Contents/MacOS/RemoteCodeDistillService --auth-token ABC --host 127.0.0.1"
            ),
            ProviderRuntimeProcess(
                pid: 702,
                ppid: 701,
                rssKB: 32_000,
                command: "helper-of-orphan-distill"
            ),
            ProviderRuntimeProcess(
                pid: 801,
                ppid: currentPID,
                rssKB: 2_100_000,
                command: "/Users/me/dev/remote-code/macos-app/dist/RemoteCode.app/Contents/MacOS/RemoteCodeDistillService --auth-token LIVE"
            ),
            ProviderRuntimeProcess(
                pid: 901,
                ppid: 1,
                rssKB: 12_000,
                command: "/usr/bin/python3 /tmp/not-a-real-RemoteCodeDistillService-wrapper.py"
            ),
            ProviderRuntimeProcess(
                pid: 902,
                ppid: 1,
                rssKB: 18_000,
                command: "claude --dangerously-skip-permissions"
            ),
        ]
        var terminated: [Int32] = []

        let result = ProviderProcessSweeper.terminateOrphanedSidecarRuntimes(
            processes: processes,
            currentPID: currentPID
        ) { pid in
            terminated.append(pid)
            return true
        }

        XCTAssertEqual(result.orphanRootPIDs, [701],
                       "only launchd-reparented RemoteCodeDistillService roots are sidecar orphan candidates")
        XCTAssertEqual(Set(result.terminatedPIDs), Set([701, 702]),
                       "orphan Distill trees (root + descendants) must be terminated so multi-GB RSS is released")
        XCTAssertEqual(Set(terminated), Set([701, 702]))
        XCTAssertFalse(terminated.contains(801),
                       "the current app's live Distill child must survive the sidecar orphan sweep")
        XCTAssertFalse(terminated.contains(901),
                       "unrelated processes whose command text mentions Distill must not be killed")
        XCTAssertFalse(terminated.contains(902),
                       "user Claude CLI processes must not be swept as Distill sidecars")
    }

    func test_isOrphanSidecarRoot_requiresLaunchdParentAndDistillBinary() {
        let currentPID: Int32 = 42
        let orphan = ProviderRuntimeProcess(
            pid: 10,
            ppid: 1,
            rssKB: 100,
            command: "/App/RemoteCodeDistillService --port 0"
        )
        let liveChild = ProviderRuntimeProcess(
            pid: 11,
            ppid: currentPID,
            rssKB: 100,
            command: "/App/RemoteCodeDistillService --port 0"
        )
        let selfProcess = ProviderRuntimeProcess(
            pid: currentPID,
            ppid: 1,
            rssKB: 100,
            command: "/App/RemoteCodeDistillService --port 0"
        )
        XCTAssertTrue(
            ProviderProcessSweeper.isOrphanSidecarRoot(orphan, currentPID: currentPID),
            "ppid==1 Distill binary is an orphan root"
        )
        XCTAssertFalse(
            ProviderProcessSweeper.isOrphanSidecarRoot(liveChild, currentPID: currentPID),
            "current-app child Distill is not an orphan"
        )
        XCTAssertFalse(
            ProviderProcessSweeper.isOrphanSidecarRoot(selfProcess, currentPID: currentPID),
            "the app process itself must never be classified as a Distill orphan"
        )
    }

    func test_orphanSweepTerminatesRemoteCodeProviderTreesOnly() {
        let currentPID: Int32 = 500
        let processes = [
            ProviderRuntimeProcess(
                pid: 101,
                ppid: 1,
                rssKB: 22_000,
                command: "/opt/homebrew/bin/node /Users/me/Library/Application Support/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/ClaudeAgentSDKBridge.mjs"
            ),
            ProviderRuntimeProcess(
                pid: 102,
                ppid: 101,
                rssKB: 220_000,
                command: "/Users/me/Library/Application Support/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude --output-format stream-json"
            ),
            ProviderRuntimeProcess(
                pid: 201,
                ppid: currentPID,
                rssKB: 25_000,
                command: "/opt/homebrew/bin/node /Users/me/Library/Application Support/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/ClaudeAgentSDKBridge.mjs"
            ),
            ProviderRuntimeProcess(
                pid: 202,
                ppid: 201,
                rssKB: 210_000,
                command: "/Users/me/Library/Application Support/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude --output-format stream-json"
            ),
            ProviderRuntimeProcess(
                pid: 301,
                ppid: 1,
                rssKB: 45_000,
                command: "/opt/homebrew/bin/codex app-server"
            ),
            ProviderRuntimeProcess(
                pid: 401,
                ppid: 1,
                rssKB: 18_000,
                command: "claude --dangerously-skip-permissions"
            )
        ]
        var terminated: [Int32] = []

        let result = ProviderProcessSweeper.terminateOrphanedProviderRuntimes(
            processes: processes,
            currentPID: currentPID
        ) { pid in
            terminated.append(pid)
            return true
        }

        XCTAssertEqual(result.orphanRootPIDs, [101, 301],
                       "only RemoteCode-owned provider roots reparented to launchd should be cleanup candidates")
        XCTAssertEqual(Set(result.terminatedPIDs), Set([101, 102, 301]))
        XCTAssertEqual(Set(terminated), Set([101, 102, 301]))
        XCTAssertFalse(terminated.contains(201),
                       "current app child bridge must survive the orphan sweep")
        XCTAssertFalse(terminated.contains(202),
                       "current app child Claude process must survive the orphan sweep")
        XCTAssertFalse(terminated.contains(401),
                       "user-owned terminal Claude commands must not be killed just because their parent is launchd")
    }

    func test_providerRuntimeDetectionIgnoresPromptTranscriptFalsePositives() {
        let currentPID: Int32 = 500
        let unrelatedComputerUseProcess = ProviderRuntimeProcess(
            pid: 600,
            ppid: 1,
            rssKB: 45_000,
            command: "/Applications/Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient prompt mentions codex app-server and ClaudeAgentSDKBridge.mjs"
        )

        XCTAssertFalse(
            ProviderProcessSweeper.isRemoteCodeProviderRuntime(unrelatedComputerUseProcess, currentPID: currentPID),
            "provider cleanup must not match arbitrary prompt text embedded in another process command line"
        )
    }

    func test_currentProviderProcessesHandlesCyclicProcessSnapshots() {
        let currentPID: Int32 = 500
        let processes = [
            ProviderRuntimeProcess(
                pid: 201,
                ppid: currentPID,
                rssKB: 25_000,
                command: "/opt/homebrew/bin/codex app-server"
            ),
            ProviderRuntimeProcess(
                pid: 202,
                ppid: 201,
                rssKB: 25_000,
                command: "child"
            ),
            ProviderRuntimeProcess(
                pid: 201,
                ppid: 202,
                rssKB: 25_000,
                command: "/opt/homebrew/bin/codex app-server"
            )
        ]

        let providerProcesses = ProviderProcessSweeper.currentProviderProcesses(
            processes: processes,
            currentPID: currentPID
        )

        XCTAssertEqual(providerProcesses.map(\.pid), [201, 201, 202],
                       "telemetry must return bounded results even if a mocked process snapshot contains a cycle")
    }

    func test_currentProviderFilterIncludesCurrentRuntimeButExcludesSelf() {
        let currentPID: Int32 = 500
        let currentApp = ProviderRuntimeProcess(
            pid: currentPID,
            ppid: 1,
            rssKB: 200_000,
            command: "/Applications/RemoteCode.app/Contents/MacOS/RemoteCode"
        )
        let provider = ProviderRuntimeProcess(
            pid: 201,
            ppid: currentPID,
            rssKB: 25_000,
            command: "/opt/homebrew/bin/node /Users/me/Library/Application Support/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/ClaudeAgentSDKBridge.mjs"
        )

        XCTAssertFalse(ProviderProcessSweeper.isRemoteCodeProviderRuntime(currentApp, currentPID: currentPID),
                       "heartbeat provider counts must not include the app process itself")
        XCTAssertTrue(ProviderProcessSweeper.isRemoteCodeProviderRuntime(provider, currentPID: currentPID),
                      "heartbeat must include live RemoteCode provider runtimes so 24h sessions show real RSS")
    }

    func test_currentProviderProcessesIncludesProviderDescendantsForMemoryTelemetry() {
        let currentPID: Int32 = 500
        let processes = [
            ProviderRuntimeProcess(
                pid: currentPID,
                ppid: 1,
                rssKB: 200_000,
                command: "/Applications/RemoteCode.app/Contents/MacOS/RemoteCode"
            ),
            ProviderRuntimeProcess(
                pid: 201,
                ppid: currentPID,
                rssKB: 25_000,
                command: "/opt/homebrew/bin/node /Users/me/Library/Application Support/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/ClaudeAgentSDKBridge.mjs"
            ),
            ProviderRuntimeProcess(
                pid: 202,
                ppid: 201,
                rssKB: 210_000,
                command: "/Users/me/Library/Application Support/RemoteCode/AgentRuntime/ClaudeAgentSDKBridge/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude --output-format stream-json"
            ),
            ProviderRuntimeProcess(
                pid: 401,
                ppid: 1,
                rssKB: 18_000,
                command: "claude --dangerously-skip-permissions"
            )
        ]

        let providerProcesses = ProviderProcessSweeper.currentProviderProcesses(
            processes: processes,
            currentPID: currentPID
        )

        XCTAssertEqual(providerProcesses.map(\.pid), [201, 202],
                       "heartbeat provider RSS must include the spawned Claude child without counting the app or user terminal Claude")
    }

    func test_currentSidecarProcessesIncludesRemoteCodeDistillServiceTreeOnly() {
        let currentPID: Int32 = 500
        let processes = [
            ProviderRuntimeProcess(
                pid: currentPID,
                ppid: 1,
                rssKB: 200_000,
                command: "/Applications/RemoteCode.app/Contents/MacOS/RemoteCode"
            ),
            ProviderRuntimeProcess(
                pid: 301,
                ppid: currentPID,
                rssKB: 4_700_000,
                command: "/Applications/RemoteCode.app/Contents/MacOS/RemoteCodeDistillService --runtime mlx"
            ),
            ProviderRuntimeProcess(
                pid: 302,
                ppid: 301,
                rssKB: 25_000,
                command: "/Applications/RemoteCode.app/Contents/MacOS/RemoteCodeDistillService mcp"
            ),
            ProviderRuntimeProcess(
                pid: 401,
                ppid: 1,
                rssKB: 1_000_000,
                command: "claude --dangerously-skip-permissions --chrome"
            )
        ]

        let sidecars = ProviderProcessSweeper.currentSidecarProcesses(
            processes: processes,
            currentPID: currentPID
        )

        XCTAssertEqual(sidecars.map(\.pid), [301, 302],
                       "Token Saver diagnostics must separate RemoteCode sidecar RSS from Agent App RSS, provider bridge RSS, and user-shell Claude RSS")
    }

    func test_currentProviderProcessesDoesNotBlockOnLargeProcessLists() {
        let currentPID: Int32 = 500
        let processes = [
            ProviderRuntimeProcess(
                pid: currentPID,
                ppid: 1,
                rssKB: 200_000,
                command: "/Applications/RemoteCode.app/Contents/MacOS/RemoteCode"
            ),
            ProviderRuntimeProcess(
                pid: 201,
                ppid: currentPID,
                rssKB: 25_000,
                command: "/opt/homebrew/bin/codex app-server"
            ),
            ProviderRuntimeProcess(
                pid: 202,
                ppid: 201,
                rssKB: 20_000,
                command: "codex child"
            )
        ] + (0..<5_000).map { index in
            ProviderRuntimeProcess(
                pid: Int32(10_000 + index),
                ppid: 1,
                rssKB: 1_000,
                command: "unrelated-\(index)"
            )
        }

        let providerProcesses = ProviderProcessSweeper.currentProviderProcesses(
            processes: processes,
            currentPID: currentPID
        )

        XCTAssertEqual(providerProcesses.map(\.pid), [201, 202])
    }
}
