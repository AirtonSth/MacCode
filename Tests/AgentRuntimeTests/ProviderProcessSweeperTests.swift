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
