import Foundation

/// Single source of truth for which shell commands the RTK-style transparent wrappers cover,
/// and which commands must never be distilled (agent expects full stdout).
///
/// Lives in CoreModel because two modules that cannot depend on each other both need it:
/// `DistillCore.CommandWrapPolicy` (the runtime compression decision) and
/// `AgentRuntime.AgentSkillInstaller` (which symlinks each command onto the agent PATH).
///
/// Split:
/// - **exact-output family**: line slices, search matches, file dumps — agent needs every line.
///   Never install wrappers; agent instructions must skip `| distill`.
/// - **compressible family**: everything else that gets a PATH wrapper. Subcommands are not
///   allowlisted — `CommandWrapPolicy` compresses any terminal-to-agent stdout above threshold
///   (except exact-output / exact-patch carve-outs).
///
/// Provider basenames (`grok` / `claude` / `codex`) are **not** listed here. Nested
/// provider interception is a separate always-on controller — see `ProviderProxyCatalog`.
public enum WrappedCommandCatalog {
    // MARK: Exact-output (no wrap, no | distill)

    /// Commands whose stdout *is* the payload the agent will reason over line-by-line.
    /// Lossy distill here drops match lines, code slices, or structure the model needs next.
    public static let exactOutputCommands: [String] = [
        // search / match lines
        "rg", "grep", "egrep", "fgrep", "ag", "ugrep",
        // stream editors / field cutters
        "sed", "awk", "gawk", "nawk", "cut", "tr", "paste",
        // file / range dumps
        "cat", "head", "tail", "nl", "tac",
        // exact compare / binary-ish dumps
        "diff", "cmp", "od", "hexdump", "xxd", "base64",
        // verification digests (every byte is part of the proof)
        "hash", "shasum", "sha1sum", "sha224sum", "sha256sum", "sha384sum", "sha512sum",
        "md5", "md5sum", "cksum", "b2sum",
        // structured extractors (full document often required)
        "jq", "yq"
    ]

    public static let exactOutputCommandSet: Set<String> = Set(exactOutputCommands)

    // MARK: Interactive / TUI (no wrap, no | distill)

    /// Programs whose normal contract owns a terminal session rather than
    /// producing finite stdout for the agent. Capturing these behind a wrapper
    /// can break input, cursor control, alternate screens, or job control.
    public static let interactiveCommands: [String] = [
        "vi", "vim", "nvim", "nano", "emacs",
        "less", "more", "most", "man", "info",
        "top", "htop", "btop", "watch", "fzf",
        "lazygit", "tig", "gitui", "ranger", "nnn", "mc", "k9s",
        "tmux", "screen", "lldb", "gdb",
        "ssh", "sftp", "ftp", "telnet"
    ]

    public static let interactiveCommandSet: Set<String> = Set(interactiveCommands)

    // MARK: Compressible wrap targets

    /// Ordered for deterministic install/uninstall; `commandSet` is the membership view.
    /// These binaries get PATH wrappers; **all** their subcommands compress when eligible
    /// (no read-only allowlist). Exact-output basenames are never listed here.
    public static let commands: [String] = [
        "find", "ls",
        "git", "gh", "glab",
        "swift", "xcodebuild",
        // package managers / install
        "npm", "yarn", "pnpm", "bun", "bunx", "pip", "pip3", "poetry", "bundle", "composer", "gem", "brew",
        // build tools
        "make", "cmake", "ninja", "gradle", "mvn", "dotnet", "cargo", "go", "rustc", "tsc", "javac",
        // test runners (bun test is the bun binary; node test runners stay listed)
        "pytest", "jest", "mocha", "rspec", "phpunit",
        // linters
        "eslint", "pylint", "flake8", "rubocop", "swiftlint", "shellcheck", "golangci-lint", "stylelint", "hadolint",
        // containers / IaC
        "docker", "kubectl", "helm", "terraform", "terragrunt", "pulumi",
        // HTTP / cloud CLIs (common noisy agent stdout across Claude/Codex/Grok)
        "curl", "wget", "aws", "gcloud", "az",
        // script interpreters often used for one-shot agents (not exact-output)
        "python", "python3"
    ]

    public static let commandSet: Set<String> = Set(commands)

    /// Symlinks to remove on install/uninstall: current wrap targets plus exact-output
    /// basenames that may still exist from older installs that wrapped sed/rg/cat/etc.
    public static var symlinkBasenamesToRemove: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for name in commands + exactOutputCommands {
            if seen.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }

    public static func isExactOutputCommand(_ command: String) -> Bool {
        let base = (command as NSString).lastPathComponent
        return exactOutputCommandSet.contains(base)
    }

    public static func isInteractiveCommand(_ command: String) -> Bool {
        let base = (command as NSString).lastPathComponent
        return interactiveCommandSet.contains(base)
    }

    /// Universal wrapper admission. The installed command set is discovered
    /// from PATH at runtime; this method owns only the closed exclusions.
    public static func isAutoWrappableCommand(_ command: String) -> Bool {
        let base = (command as NSString).lastPathComponent
        guard !base.isEmpty,
              base != "RemoteCodeDistillService",
              base != "distill",
              base != "remote-code",
              base != "rc-retrieve-mcp",
              !ProviderProxyCatalog.isProviderProxyCommand(base),
              !isExactOutputCommand(base),
              !isInteractiveCommand(base) else {
            return false
        }
        return true
    }
}
