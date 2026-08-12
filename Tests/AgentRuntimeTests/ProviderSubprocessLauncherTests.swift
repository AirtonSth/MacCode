import Foundation
import XCTest
import CoreModel
import Darwin
@testable import AgentRuntime

final class ProviderSubprocessLauncherTests: XCTestCase {
    private func receiptEnvironment(
        for provider: AgentProvider,
        statePath: String? = nil
    ) -> [String: String] {
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
        var environment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        if let statePath {
            environment["REMOTE_CODE_DISTILL_STATE_PATH"] = statePath
            environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = URL(fileURLWithPath: statePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
        }
        return environment
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

    func test_codexToolChildReceivesAdmittedReceiptThroughShellEnvironmentPolicy() throws {
        // WHY: Codex's default shell policy strips RC_* from tool children even
        // though PATH still points at the managed wrappers. Only an admitted,
        // fully-scoped run may reintroduce the receipt through explicit config.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-codex-env-policy-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = root.appendingPathComponent("fake-codex.js")
        try Data(
            """
            #!/usr/bin/env node
            const pair = process.argv.slice(2).find((arg) => arg.includes("shell_environment_policy.set.RC_TOKEN_SAVER_EXECUTION_RECEIPT_V1="));
            delete process.env.RC_TOKEN_SAVER_EXECUTION_RECEIPT_V1;
            process.stdout.write(pair ? "FORWARDED\\n" : "BLOCKED\\n");
            """.utf8
        ).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)

        func runFixture(environment: [String: String]) throws -> String {
            let process = try ProviderSubprocessLauncher.makeProcess(
                provider: .codex,
                executablePath: fixture.path,
                arguments: ["app-server"],
                currentDirectory: root.path,
                environment: environment
            )
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: data, as: UTF8.self)
        }

        let statePath = root
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
            .path
        let admittedEnvironment = receiptEnvironment(for: .codex, statePath: statePath)
        let admittedProcess = try ProviderSubprocessLauncher.makeProcess(
            provider: .codex,
            executablePath: fixture.path,
            arguments: ["app-server"],
            currentDirectory: root.path,
            environment: admittedEnvironment
        )
        XCTAssertTrue(
            admittedProcess.arguments?.contains(
                "shell_environment_policy.set.REMOTE_CODE_DISTILL_STATE_PATH=\"\(statePath)\""
            ) == true,
            "a valid Codex receipt must carry the exact sidecar state path into shell policy"
        )
        XCTAssertTrue(
            admittedProcess.arguments?.contains(
                "shell_environment_policy.set.RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY=\"\(root.path)\""
            ) == true,
            "a valid Codex receipt must carry the exact app-support DB namespace into shell policy"
        )
        XCTAssertTrue(
            admittedProcess.arguments?.contains(
                "shell_environment_policy.set.RC_REMOTE_CODE_PROVIDER_TERMINAL_STDOUT=\"1\""
            ) == true,
            "only an admitted Codex tool shell may identify its broker-owned terminal stdout"
        )
        XCTAssertTrue(
            admittedProcess.arguments?.contains(
                "shell_environment_policy.set.RC_REMOTE_CODE_UNOWNED_TOOL_SHELL=\"1\""
            ) == true,
            "Codex tool shells must fail open unless a managed aggregate wrapper transfers ownership"
        )
        XCTAssertEqual(try runFixture(environment: admittedEnvironment), "FORWARDED\n")
        XCTAssertEqual(
            try runFixture(environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "stale"]),
            "BLOCKED\n",
            "Token Saver OFF/stale hint must not authorize child receipt propagation"
        )

        var mismatchedNamespace = admittedEnvironment
        mismatchedNamespace["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = root
            .appendingPathComponent("other-support", isDirectory: true)
            .path
        let mismatchedNamespaceProcess = try ProviderSubprocessLauncher.makeProcess(
            provider: .codex,
            executablePath: fixture.path,
            arguments: ["app-server"],
            currentDirectory: root.path,
            environment: mismatchedNamespace
        )
        XCTAssertFalse(
            mismatchedNamespaceProcess.arguments?.contains(where: {
                $0.contains("shell_environment_policy.set.RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY=")
                    || $0.contains("shell_environment_policy.set.REMOTE_CODE_DISTILL_STATE_PATH=")
            }) == true,
            "a state/app-support mismatch must not reach the Codex tool shell"
        )

        let deniedReceipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: false,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: "10000000-0000-0000-0000-000000000001"
        )
        let deniedEnvironment = [
            "REMOTE_CODE_DISTILL_STATE_PATH": statePath,
            TokenSaverExecutionReceipt.envKey: try XCTUnwrap(deniedReceipt.encodedJSONString())
        ]
        let deniedProcess = try ProviderSubprocessLauncher.makeProcess(
            provider: .codex,
            executablePath: fixture.path,
            arguments: ["app-server"],
            currentDirectory: root.path,
            environment: deniedEnvironment
        )
        XCTAssertFalse(
            deniedProcess.arguments?.contains(where: {
                $0.contains("shell_environment_policy.set.REMOTE_CODE_DISTILL_STATE_PATH=")
            }) == true,
            "a denied receipt must not authorize a state-path override"
        )
        XCTAssertFalse(
            deniedProcess.arguments?.contains(where: {
                $0.contains("shell_environment_policy.set.RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY=")
            }) == true,
            "a denied receipt must not authorize an app-support DB namespace"
        )
        XCTAssertFalse(
            deniedProcess.arguments?.contains(where: {
                $0.contains("shell_environment_policy.set.RC_REMOTE_CODE_PROVIDER_TERMINAL_STDOUT=")
            }) == true,
            "a denied receipt must not authorize terminal-output capture"
        )
        XCTAssertFalse(
            deniedProcess.arguments?.contains(where: {
                $0.contains("shell_environment_policy.set.RC_REMOTE_CODE_UNOWNED_TOOL_SHELL=")
            }) == true,
            "a denied receipt must not alter tool-shell ownership policy"
        )

        let mismatched = try ProviderSubprocessLauncher.makeProcess(
            provider: .codex,
            executablePath: fixture.path,
            arguments: ["app-server"],
            currentDirectory: root.path,
            environment: receiptEnvironment(for: .claude, statePath: statePath)
        )
        XCTAssertFalse(
            mismatched.arguments?.contains(where: {
                $0.contains("shell_environment_policy.set.REMOTE_CODE_DISTILL_STATE_PATH=")
            }) == true,
            "a provider-mismatched receipt must not authorize a state-path override"
        )
        XCTAssertFalse(
            mismatched.arguments?.contains(where: {
                $0.contains("shell_environment_policy.set.RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY=")
            }) == true,
            "a provider-mismatched receipt must not authorize an app-support DB namespace"
        )
        XCTAssertFalse(
            mismatched.arguments?.contains(where: {
                $0.contains("shell_environment_policy.set.RC_REMOTE_CODE_PROVIDER_TERMINAL_STDOUT=")
            }) == true,
            "a provider-mismatched receipt must not authorize terminal-output capture"
        )
        XCTAssertFalse(
            mismatched.arguments?.contains(where: {
                $0.contains("shell_environment_policy.set.RC_REMOTE_CODE_UNOWNED_TOOL_SHELL=")
            }) == true,
            "a provider-mismatched receipt must not alter tool-shell ownership policy"
        )
    }

    func test_codexNodeTransportBypassesManagedNodeButChildKeepsManagedPath() throws {
        // WHY: Homebrew's Codex entrypoint is a Node shebang. If the managed
        // `node` wrapper launches that shebang, it captures the JSON-RPC stream
        // and Codex never answers initialize. Only the transport interpreter is
        // bypassed; commands spawned by Codex must still see managed PATH first.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-codex-node-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let managed = root
            .appendingPathComponent("app-support/ManagedIntegrationHome/.remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let nodeWrapper = managed.appendingPathComponent("node")
        try Data("#!/bin/sh\nprintf wrapper-used >&2\nexit 99\n".utf8).write(to: nodeWrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nodeWrapper.path)

        let node = try XCTUnwrap(
            ProcessLocator.resolveOutsideManagedBin(
                "node",
                environmentPath: ProcessInfo.processInfo.environment["PATH"],
                homeDirectory: home.path
            ),
            "a real node interpreter is required for this transport regression"
        )
        let script = root.appendingPathComponent("codex.js")
        try Data(
            "#!/usr/bin/env node\nprocess.stdout.write(JSON.stringify({method: 'initialize'}) + '\\n'); setTimeout(() => {}, 5000);\n".utf8
        ).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let environment = [
            "HOME": home.path,
            "PATH": managed.path + ":" + URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/usr/bin:/bin",
            "RC_REMOTE_CODE_MANAGED_BIN": managed.path,
            "RC_LOGIN_SHELL_ENV_IMPORT": "0"
        ]
        let ordinaryNode = try XCTUnwrap(
            ProcessLocator.resolve("node", environmentPath: environment["PATH"], homeDirectory: home.path)
        )
        XCTAssertEqual(ordinaryNode, nodeWrapper.path,
                       "ordinary user node commands must continue to resolve through the managed wrapper")

        let process = try ProviderSubprocessLauncher.makeProcess(
            provider: .codex,
            executablePath: script.path,
            arguments: ["app-server"],
            currentDirectory: root.path,
            environment: environment
        )
        XCTAssertEqual(process.executableURL?.path, node,
                       "Codex's Node shebang must use the real interpreter for JSON-RPC transport")
        XCTAssertEqual(process.arguments?.first, script.path)
        XCTAssertTrue(process.environment?["PATH"]?.hasPrefix(managed.path + ":") == true,
                      "the provider child environment must retain managed PATH")

        let ordinaryCodex = ProviderSubprocessLauncher.transportCommand(
            provider: .codex,
            executablePath: script.path,
            arguments: ["exec", "--json"],
            environment: environment
        )
        XCTAssertEqual(ordinaryCodex.executablePath, script.path,
                       "only the persistent app-server transport may bypass the managed node wrapper")
        XCTAssertEqual(ordinaryCodex.arguments, ["exec", "--json"])

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let bytes = try XCTUnwrap(output.fileHandleForReading.read(upToCount: 128))
        let initialize = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertTrue(initialize.contains("initialize"),
                      "initialize bytes must arrive before the long-lived app-server reaches EOF")
    }

    func test_foreignUserLaunchPreservesProviderReceiptThroughSudoPlan() throws {
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
            askpassPath: "/tmp/remotecode-test-askpass"
        )

        XCTAssertEqual(process.executableURL?.path, RunAsUserProcessBootstrap.sudoPath)
        XCTAssertTrue(process.arguments?.contains("/usr/local/bin/codex") == true)
        XCTAssertTrue(process.arguments?.contains("target-user") == true)
        XCTAssertEqual(process.environment?["REMOTE_CODE_AGENT_PROVIDER"], AgentProvider.codex.rawValue)
        XCTAssertNotNil(process.environment?[TokenSaverExecutionReceipt.envKey])
        XCTAssertEqual(process.environment?["SUDO_ASKPASS"], "/tmp/remotecode-test-askpass")
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
