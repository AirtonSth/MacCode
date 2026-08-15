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
/// system `sudo -u` (already present on macOS — no helper install required).
/// Stdio is preserved because `sudo` execs the provider in the same process
/// tree. Becoming another user needs privilege, so `sudo` authenticates the
/// CURRENT user; a graphical askpass (`-A` + `SUDO_ASKPASS`) supplies the
/// password without a tty. Without an askpass we fall back to `-n`
/// (non-interactive) which succeeds only on a cached sudo timestamp.
public enum RunAsUserProcessBootstrap {
    public static let sudoPath = "/usr/bin/sudo"

    /// Basenames allowed through the elevated launch.
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

    /// Builds the launch plan. When `runAsUser` is nil or the current user, this
    /// is a passthrough. Otherwise it rewrites to
    /// `sudo [-A|-n] -u <shortName> -H -- <binary> <args>`:
    /// `-H` sets HOME to the target's home so the provider reads THAT user's
    /// config (e.g. `~/.claude` = the account/MCP/skills that user is logged in
    /// with); `-A` uses the graphical askpass at `askpassPath`; without an
    /// askpass we use `-n` so a missing credential fails loudly instead of
    /// hanging on a tty prompt.
    public static func plan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String,
        provider: AgentProvider? = nil,
        runAsUser: AgentRunAsUser?,
        askpassPath: String? = nil,
        sudoPathOverride: String? = nil,
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

        // Preserve PATH so providers can find node/git/rg after sudo's env_reset.
        // Claude also needs the two positive thinking controls that the host
        // configures. Effort stays on the explicit CLI/SDK payload, while
        // inherited disabling controls remain absent. Never preserve the broad
        // provider environment (it can carry credentials and routing secrets).
        let preservedEnvironmentKeys = provider == .claude
            ? ["PATH", "CLAUDE_CODE_DISABLE_THINKING", "MAX_THINKING_TOKENS"]
            : ["PATH"]
        let authFlag = (askpassPath?.isEmpty == false) ? "-A" : "-n"
        var sudoArgs: [String] = [
            authFlag,
            "--preserve-env=\(preservedEnvironmentKeys.joined(separator: ","))",
            "-u", runAsUser.shortName,
            "-H",
            "--",
            executablePath
        ]
        sudoArgs.append(contentsOf: arguments)

        // SUDO_ASKPASS must be in the INVOKING environment (read before sudo
        // resets env). `-H` handles the target HOME; do not preset HOME here.
        var sudoEnv = environment
        if let askpassPath, !askpassPath.isEmpty {
            sudoEnv["SUDO_ASKPASS"] = askpassPath
        }

        return LaunchPlan(
            executablePath: sudoPathOverride ?? sudoPath,
            arguments: sudoArgs,
            environment: sudoEnv,
            currentDirectory: currentDirectory,
            usesHelper: true
        )
    }

    /// Builds the argv for a best-effort, non-interactive `sudo` that signals
    /// `pids` AS the target uid. A run-as-user provider's real child (`claude`
    /// and its descendants) carries the TARGET user's uid, so this non-root app
    /// gets EPERM signalling them directly and `sudo` never relays `SIGKILL`;
    /// reaping them requires re-entering the target uid via `sudo`. Uses `-n`
    /// (never prompt) so teardown never pops a password dialog — it succeeds only
    /// on the sudo credential cached by the spawn-time askpass and otherwise fails
    /// silently, leaving the orphan we already could not signal. Returns nil when
    /// there is nothing to signal.
    public static func sudoKillArguments(
        uid: uid_t,
        signal: Int32,
        pids: [pid_t],
        killPath: String = "/bin/kill",
        sudoPathOverride: String? = nil
    ) -> (executablePath: String, arguments: [String])? {
        let targets = pids.filter { $0 > 0 }
        guard !targets.isEmpty else { return nil }
        var arguments = ["-n", "-u#\(uid)", "--", killPath, "-\(signal)"]
        arguments.append(contentsOf: targets.map(String.init))
        return (sudoPathOverride ?? sudoPath, arguments)
    }

    /// The graphical askpass script body. `sudo -A` runs this and reads the
    /// password from stdout; a macOS dialog collects it (hidden answer). Cancel
    /// prints nothing → sudo auth fails loudly. Contains no secret itself.
    public static func askpassScriptBody(targetUser: String) -> String {
        // Sanitize the user name before it enters the osascript string literal —
        // a macOS short name is `[A-Za-z0-9_.-]`, so anything else is dropped to
        // block AppleScript/shell injection via a pathological account name.
        let safe = targetUser.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
        let who = safe.isEmpty ? "another user" : safe
        return """
        #!/bin/sh
        /usr/bin/osascript \
          -e 'display dialog "RemoteCode needs your macOS password to run the agent as \(who)." with title "RemoteCode" default answer "" with hidden answer with icon caution' \
          -e 'text returned of result' 2>/dev/null
        """
    }

    /// Writes the askpass script for `targetUser` to a user-scoped temp path
    /// (mode 0700 dir, 0755 file), returning its absolute path. Rewritten each
    /// call so the dialog names the current target. Returns nil on write
    /// failure so the caller can fall back to `-n`.
    public static func materializeAskpass(
        targetUser: String,
        directory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        let path = directory.appendingPathComponent("remotecode-sudo-askpass.sh")
        do {
            try askpassScriptBody(targetUser: targetUser).write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            return path.path
        } catch {
            return nil
        }
    }

    /// Applies a launch plan onto a Foundation Process.
    public static func apply(_ plan: LaunchPlan, to process: Process) {
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.currentDirectory)
        process.environment = plan.environment
    }
}
