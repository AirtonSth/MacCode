import Foundation
import CoreModel

/// The only supported construction path for a provider agent subprocess.
///
/// Keeping environment construction and run-as-user rewriting here makes the
/// Token Saver receipt and provider identity part of the launch contract rather
/// than a convention repeated by each provider adapter.
public enum ProviderSubprocessLauncher {
    /// Node-based Codex distributions use `#!/usr/bin/env node`. A managed
    /// `node` wrapper must not become the JSON-RPC transport executable, but the
    /// original managed PATH remains in the child environment for agent shells.
    public static func transportCommand(
        provider: AgentProvider,
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) -> (executablePath: String, arguments: [String]) {
        let transportArguments = arguments.first == "app-server"
            ? arguments + codexShellEnvironmentPolicyArguments(
                provider: provider,
                environment: environment
            )
            : arguments
        guard provider == .codex,
              arguments.first == "app-server",
              let script = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath() as URL?,
              let firstLine = try? String(contentsOf: script, encoding: .utf8)
                .split(whereSeparator: \.isNewline).first,
              firstLine.hasPrefix("#!") else {
            return (executablePath, transportArguments)
        }
        let shebang = firstLine.dropFirst(2)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        let interpreter: String
        if shebang.first?.hasSuffix("/env") == true {
            guard shebang.count >= 2 else { return (executablePath, transportArguments) }
            interpreter = shebang[1]
        } else {
            guard let first = shebang.first else { return (executablePath, transportArguments) }
            interpreter = first
        }
        guard (interpreter as NSString).lastPathComponent == "node",
              let node = ProcessLocator.resolveOutsideManagedBin(
                interpreter,
                environmentPath: environment["PATH"],
                homeDirectory: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
                managedBinDirectory: environment["RC_REMOTE_CODE_MANAGED_BIN"]
              ) else {
            return (executablePath, transportArguments)
        }
        return (node, [script.path] + transportArguments)
    }

    /// Codex's app-server applies `shell_environment_policy` when it launches
    /// tool shells. Its default policy intentionally drops RC_* variables, so
    /// an admitted run would reach managed wrappers without its admission
    /// receipt. Pass only the validated, content-free run scope as explicit
    /// `-c` overrides; never inherit the whole host environment.
    private static func codexShellEnvironmentPolicyArguments(
        provider: AgentProvider,
        environment: [String: String]
    ) -> [String] {
        guard provider == .codex,
              let receipt = TokenSaverExecutionReceiptSeam.receipt(from: environment),
              receipt.admitted,
              receipt.sameUser,
              receipt.provider == provider.rawValue,
              receipt.capabilities.distill == true,
              receipt.capabilities.managedPath == true,
              receipt.capabilities.recoveryScope == true else {
            return []
        }

        let requiredScope = [
            "RC_TOKEN_SAVER_WORKSPACE_ID",
            "RC_TOKEN_SAVER_PROJECT_ID",
            "RC_TOKEN_SAVER_THREAD_ID",
            "RC_TOKEN_SAVER_ATTEMPT_ID",
            "REMOTE_CODE_AGENT_PROVIDER",
        ]
        guard requiredScope.allSatisfy({
            guard let value = environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return false }
            return true
        }),
        environment["RC_TOKEN_SAVER_THREAD_ID"] == receipt.threadId,
        environment["RC_TOKEN_SAVER_WORKSPACE_ID"] == receipt.workspaceId,
        environment["RC_TOKEN_SAVER_PROJECT_ID"] == receipt.projectId,
        environment["RC_TOKEN_SAVER_ATTEMPT_ID"] == receipt.attemptId,
        let appSupport = nonEmpty(environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]),
        let statePath = nonEmpty(environment["REMOTE_CODE_DISTILL_STATE_PATH"]),
        URL(fileURLWithPath: statePath).standardizedFileURL == URL(
            fileURLWithPath: appSupport,
            isDirectory: true
        )
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
            .standardizedFileURL else {
            return []
        }

        let keys = [
            TokenSaverExecutionReceipt.envKey,
            "RC_TOKEN_SAVER_DISTILL_HINT",
            "RC_TOKEN_SAVER_WORKSPACE_ID",
            "RC_TOKEN_SAVER_PROJECT_ID",
            "RC_TOKEN_SAVER_THREAD_ID",
            "RC_TOKEN_SAVER_ATTEMPT_ID",
            "RC_TOKEN_SAVER_ROOT_RUN_ID",
            "RC_TOKEN_SAVER_WAVE_LIVE",
            "REMOTE_CODE_AGENT_PROVIDER",
            "REMOTE_CODE_DISTILL_STATE_PATH",
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY",
            "RC_REMOTE_CODE_MANAGED_BIN",
            "RC_REMOTE_CODE_PROVIDER_PROXY_BIN",
        ] + codexShellBridgeEnvironmentKeys(environment: environment)
        let forwarded = keys.flatMap { (key) -> [String] in
            guard let value = environment[key], !value.isEmpty else { return [] }
            return ["-c", "shell_environment_policy.set.\(key)=\(tomlString(value))"]
        }
        // Marks stdout as owned by the provider command runner. The wrapper
        // uses this only as a fallback when macOS exposes the broker stream as
        // a socket rather than a discoverable pipe, and only for an exec'd
        // bare command whose parent is not a shell. Pipeline stages still have
        // a shell parent and remain byte-preserving.
        return forwarded + [
            "-c",
            "shell_environment_policy.set.RC_REMOTE_CODE_PROVIDER_TERMINAL_STDOUT=\(tomlString("1"))",
            "-c",
            "shell_environment_policy.set.RC_REMOTE_CODE_UNOWNED_TOOL_SHELL=\(tomlString("1"))",
        ]
    }

    /// Codex's app-server does not launch tool shells with the complete parent
    /// environment. In particular, a login zsh may run macOS `path_helper` and
    /// move a managed bin behind `/usr/bin`, so a bare `swift noisy.swift` then
    /// bypasses the wrapper even though the provider process started with the
    /// right PATH. Forward the host-composed PATH and the installed shell bridge
    /// only after receipt admission; never forward an arbitrary user ZDOTDIR or
    /// BASH_ENV as a shell-policy escape hatch.
    private static func codexShellBridgeEnvironmentKeys(
        environment: [String: String]
    ) -> [String] {
        var keys: [String] = []
        if let path = environment["PATH"], !path.isEmpty {
            keys.append("PATH")
        }

        guard let managedBin = nonEmpty(environment["RC_REMOTE_CODE_MANAGED_BIN"]),
              let managedBridge = nonEmpty(environment["RC_REMOTE_CODE_MANAGED_ZDOTDIR"]),
              isInstalledShellBridge(managedBin: managedBin, bridge: managedBridge) else {
            return keys
        }

        keys.append(contentsOf: [
            "ZDOTDIR",
            "RC_REMOTE_CODE_MANAGED_ZDOTDIR",
            "RC_REMOTE_CODE_ORIGINAL_ZDOTDIR",
            "RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR",
            "BASH_ENV",
            "RC_REMOTE_CODE_ORIGINAL_BASH_ENV",
        ])
        return keys
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func isInstalledShellBridge(managedBin: String, bridge: String) -> Bool {
        let managedDirectory = URL(fileURLWithPath: managedBin).standardizedFileURL
        let expectedBridge = managedDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("shell/zsh", isDirectory: true)
            .standardizedFileURL
        guard URL(fileURLWithPath: bridge).standardizedFileURL == expectedBridge else {
            return false
        }
        let fileManager = FileManager.default
        return [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"]
            .allSatisfy {
                fileManager.isReadableFile(
                    atPath: expectedBridge.appendingPathComponent($0).path
                )
            }
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    public static func makeProcess(
        provider: AgentProvider,
        executablePath: String,
        arguments: [String],
        currentDirectory: String,
        environment overrides: [String: String],
        runAsUser: AgentRunAsUser? = nil,
        askpassPath: String? = nil
    ) throws -> Process {
        let environment = CodexRunner.processEnvironment(
            overrides: overrides,
            purpose: .agentTurn(provider)
        )
        let transport = transportCommand(
            provider: provider,
            executablePath: executablePath,
            arguments: arguments,
            environment: environment
        )
        let plan = try RunAsUserProcessBootstrap.plan(
            executablePath: transport.executablePath,
            arguments: transport.arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            runAsUser: runAsUser,
            askpassPath: askpassPath
        )
        let process = Process()
        RunAsUserProcessBootstrap.apply(plan, to: process)
        return process
    }
}
