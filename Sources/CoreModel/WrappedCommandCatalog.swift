import Foundation

/// Single source of truth for which shell commands the RTK-style transparent wrappers cover.
/// Lives in CoreModel because two modules that cannot depend on each other both need it:
/// `DistillCore.CommandWrapPolicy` (the runtime compression decision) and
/// `AgentRuntime.AgentSkillInstaller` (which symlinks each command onto the agent PATH).
///
/// The set is the read/search/log family RTK targets that is safe to compress when the
/// invocation itself is read-only. Mutating subcommands are rejected by
/// `DistillCore.CommandWrapPolicy` and inherit raw streams.
public enum WrappedCommandCatalog {
    /// Ordered for deterministic install/uninstall; `commandSet` is the membership view.
    public static let commands: [String] = ["rg", "grep", "find", "ls", "cat", "sed", "git", "gh", "glab", "swift", "xcodebuild"]
    public static let commandSet: Set<String> = Set(commands)
}
