import Foundation
import XCTest
import CoreModel
import Darwin
@testable import AgentRuntime

final class ProviderSubprocessLauncherTests: XCTestCase {
    private func receiptEnvironment(for provider: AgentProvider) -> [String: String] {
        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: provider,
            threadId: "10000000-0000-0000-0000-000000000001",
            rootRunId: "40000000-0000-0000-0000-000000000004",
            attemptId: "50000000-0000-0000-0000-000000000005",
            workspaceId: "20000000-0000-0000-0000-000000000002",
            projectId: "30000000-0000-0000-0000-000000000003",
            enabledLanes: ["deterministic_wrapper"]
        )
        return TokenSaverExecutionReceiptSeam.environment(from: receipt)
    }

    func test_everyProviderLaunchUsesTheSameTokenSaverAndIdentityContract() throws {
        // WHY: a provider-specific adapter must not be able to create a child
        // process without inheriting the host receipt and its provider identity.
        for provider in AgentProvider.allCases {
            let process = try ProviderSubprocessLauncher.makeProcess(
                provider: provider,
                executablePath: "/bin/sh",
                arguments: ["-c", "exit 0"],
                currentDirectory: FileManager.default.currentDirectoryPath,
                environment: receiptEnvironment(for: provider)
            )

            XCTAssertEqual(process.environment?["REMOTE_CODE_AGENT_PROVIDER"], provider.rawValue)
            XCTAssertEqual(process.environment?[TokenSaverExecutionReceipt.envKey],
                           receiptEnvironment(for: provider)[TokenSaverExecutionReceipt.envKey])
            XCTAssertEqual(process.arguments, ["-c", "exit 0"])
        }
    }

    func test_launchWithoutAValidReceiptRemainsRawForEveryProvider() throws {
        // WHY: automaticity must never resurrect optimization flags from stale
        // GUI/shell state when the host did not make a valid admission.
        for provider in AgentProvider.allCases {
            let process = try ProviderSubprocessLauncher.makeProcess(
                provider: provider,
                executablePath: "/bin/sh",
                arguments: ["-c", "exit 0"],
                currentDirectory: FileManager.default.currentDirectoryPath,
                environment: [
                    "RC_TOKEN_SAVER_DISTILL_HINT": "stale",
                    "RC_TOKEN_SAVER_POST_TOOL_USE": "stale"
                ]
            )

            XCTAssertNil(process.environment?["RC_TOKEN_SAVER_DISTILL_HINT"])
            XCTAssertNil(process.environment?["RC_TOKEN_SAVER_POST_TOOL_USE"])
            XCTAssertEqual(process.environment?["REMOTE_CODE_AGENT_PROVIDER"], provider.rawValue)
        }
    }

    func test_foreignUserLaunchPreservesProviderReceiptThroughInstalledHelper() throws {
        // WHY: the run-as-user path is a second Process configuration route;
        // it must not lose provider identity or the authorized receipt when it
        // rewrites the child to sudo.
        let process = try ProviderSubprocessLauncher.makeProcess(
            provider: .codex,
            executablePath: "/usr/local/bin/codex",
            arguments: ["exec", "--json"],
            currentDirectory: FileManager.default.currentDirectoryPath,
            environment: receiptEnvironment(for: .codex),
            runAsUser: AgentRunAsUser(
                generatedUID: "target-generated-uid",
                shortName: "target-user",
                uid: getuid() + 1,
                gid: getgid(),
                homePath: "/Users/target-user"
            ),
            askpassPath: "/tmp/remotecode-test-askpass",
            helperPathOverride: "/tmp/remotecode-test-helper"
        )

        XCTAssertEqual(process.executableURL?.path, "/tmp/remotecode-test-helper")
        XCTAssertTrue(process.arguments?.contains("/usr/local/bin/codex") == true)
        XCTAssertTrue(process.arguments?.contains("target-user") == true)
        XCTAssertEqual(process.environment?["REMOTE_CODE_AGENT_PROVIDER"], AgentProvider.codex.rawValue)
        XCTAssertNotNil(process.environment?[TokenSaverExecutionReceipt.envKey])
        XCTAssertNil(process.environment?["SUDO_ASKPASS"],
                     "provider children must not inherit a password-prompt script after helper installation")
    }

    func test_foreignClaudeLaunchPreservesOnlyEnabledThinkingControls() throws {
        let process = try ProviderSubprocessLauncher.makeProcess(
            provider: .claude,
            executablePath: "/usr/local/bin/claude",
            arguments: ["--print", "hello"],
            currentDirectory: FileManager.default.currentDirectoryPath,
            environment: ClaudeRunner.thinkingEnvironment([
                "CLAUDE_CODE_EFFORT_LEVEL": "low",
                "DISABLE_INTERLEAVED_THINKING": "1"
            ]),
            runAsUser: AgentRunAsUser(
                generatedUID: "target-generated-uid",
                shortName: "target-user",
                uid: getuid() + 1,
                gid: getgid(),
                homePath: "/Users/target-user"
            ),
            helperPathOverride: "/tmp/remotecode-test-helper"
        )

        XCTAssertTrue(process.arguments?.contains("CLAUDE_CODE_DISABLE_THINKING") == false,
                      "thinking controls belong in the filtered helper environment, not command-line sudo flags")
        XCTAssertEqual(process.environment?["CLAUDE_CODE_DISABLE_THINKING"], "0")
        XCTAssertEqual(process.environment?["MAX_THINKING_TOKENS"], "32000")
        XCTAssertNil(process.environment?["CLAUDE_CODE_EFFORT_LEVEL"])
        XCTAssertNil(process.environment?["DISABLE_INTERLEAVED_THINKING"])
        XCTAssertEqual(process.executableURL?.path, "/tmp/remotecode-test-helper")
    }

    func test_providerSourceLaunchSitesAreArchitecturallyBoundToTheLauncher() throws {
        // WHY: a unit test of the launcher alone cannot prevent a future adapter
        // from constructing Process directly. Keep the source-level inventory
        // executable so adding a provider launch requires an explicit seam call.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runnerFiles = [
            "CodexRunner.swift",
            "CodexAppServerClient.swift",
            "ClaudeRunner.swift",
            "ClaudeStreamingCLIAdapter.swift",
            "GrokRunner.swift",
            "GrokACPClient.swift"
        ]

        for file in runnerFiles {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/AgentRuntime/\(file)"), encoding: .utf8)
            XCTAssertTrue(source.contains("ProviderSubprocessLauncher.makeProcess"), "\(file) must use the universal launcher")
            XCTAssertFalse(source.contains("Process()"), "\(file) contains a direct Process construction bypass")
            XCTAssertFalse(source.contains("RunAsUserProcessBootstrap.plan("), "\(file) bypasses the universal run-as-user seam")
        }

        let sdkSource = try String(contentsOf: root.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridgeAdapter.swift"), encoding: .utf8)
        let sessionStart = try XCTUnwrap(sdkSource.range(of: "private func spawnSession"))
        let sessionEnd = sdkSource[sessionStart.upperBound...].firstRange(of: "    // A machine-agnostic")?.lowerBound ?? sdkSource.endIndex
        let sessionSource = String(sdkSource[sessionStart.lowerBound..<sessionEnd])
        XCTAssertTrue(sessionSource.contains("ProviderSubprocessLauncher.makeProcess"))
        XCTAssertFalse(sessionSource.contains("Process()"))
    }
}
