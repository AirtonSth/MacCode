import Foundation
import CoreModel

public enum RunAsUserProcessBootstrapError: Error, LocalizedError, Equatable {
    case helperUnavailable(String)
    case invalidTarget(String)
    case binaryNotAbsolute(String)
    case binaryNotAllowlisted(String)

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable(let detail):
            return "Run-as-user helper unavailable: \(detail)"
        case .invalidTarget(let detail):
            return "Cannot run as that macOS user: \(detail)"
        case .binaryNotAbsolute(let path):
            return "Provider binary must be an absolute path for run-as-user: \(path)"
        case .binaryNotAllowlisted(let name):
            return "Executable is not allowlisted for run-as-user: \(name)"
        }
    }
}

/// Rewrites a provider Process launch so it runs as another macOS user via the
/// privileged trampoline helper (setuid/root LaunchDaemon install). Stdio is
/// preserved because the helper `exec`s into the provider in-process tree.
public enum RunAsUserProcessBootstrap {
    public static let helperExecutableNames = [
        "RemoteCodeRunAsUserHelper",
        "io.remotecode.RunAsUserHelper"
    ]

    /// Basenames allowed through the privileged trampoline.
    public static let allowlistedBasenames: Set<String> = [
        "codex",
        "claude",
        "grok",
        "node",
        "npm"
    ]

    public struct LaunchPlan: Equatable, Sendable {
        public var executablePath: String
        public var arguments: [String]
        public var environment: [String: String]
        public var currentDirectory: String
        public var usesHelper: Bool

        public init(
            executablePath: String,
            arguments: [String],
            environment: [String: String],
            currentDirectory: String,
            usesHelper: Bool
        ) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.environment = environment
            self.currentDirectory = currentDirectory
            self.usesHelper = usesHelper
        }
    }

    public static func plan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String,
        runAsUser: AgentRunAsUser?,
        helperLocator: (String) -> String? = { ProcessLocator.resolve($0) },
        currentUID: uid_t = getuid()
    ) throws -> LaunchPlan {
        guard let runAsUser, runAsUser.uid != currentUID else {
            return LaunchPlan(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                usesHelper: false
            )
        }

        guard runAsUser.uid >= 501, runAsUser.uid != 0 else {
            throw RunAsUserProcessBootstrapError.invalidTarget("uid \(runAsUser.uid) is not an interactive user")
        }
        guard executablePath.hasPrefix("/") else {
            throw RunAsUserProcessBootstrapError.binaryNotAbsolute(executablePath)
        }
        let base = URL(fileURLWithPath: executablePath).lastPathComponent
        guard allowlistedBasenames.contains(base) else {
            throw RunAsUserProcessBootstrapError.binaryNotAllowlisted(base)
        }

        guard let helper = helperExecutableNames.compactMap(helperLocator).first else {
            throw RunAsUserProcessBootstrapError.helperUnavailable(
                "install RemoteCodeRunAsUserHelper (privileged) or ensure it is on PATH"
            )
        }

        // Helper argv: exec --uid N --gid N --home H --user NAME --cwd C -- binary args...
        var helperArgs: [String] = [
            "exec",
            "--uid", "\(runAsUser.uid)",
            "--gid", "\(runAsUser.gid)",
            "--home", runAsUser.homePath,
            "--user", runAsUser.shortName,
            "--cwd", currentDirectory,
            "--",
            executablePath
        ]
        helperArgs.append(contentsOf: arguments)

        // Environment for the helper process itself (root phase). The helper
        // rebuilds a clean user environment after setuid.
        var helperEnv = environment
        helperEnv["HOME"] = runAsUser.homePath
        helperEnv["USER"] = runAsUser.shortName
        helperEnv["LOGNAME"] = runAsUser.shortName
        helperEnv["RC_RUN_AS_USER"] = runAsUser.shortName
        helperEnv["RC_RUN_AS_UID"] = "\(runAsUser.uid)"

        return LaunchPlan(
            executablePath: helper,
            arguments: helperArgs,
            environment: helperEnv,
            currentDirectory: currentDirectory,
            usesHelper: true
        )
    }

    /// Applies a launch plan onto a Foundation Process.
    public static func apply(_ plan: LaunchPlan, to process: Process) {
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.currentDirectory)
        process.environment = plan.environment
    }
}
