import Foundation

/// Single source of truth for which shell commands the RTK-style transparent wrappers cover.
/// Lives in CoreModel because two modules that cannot depend on each other both need it:
/// `DistillCore.CommandWrapPolicy` (the runtime compression decision) and
/// `AgentRuntime.AgentSkillInstaller` (which symlinks each command onto the agent PATH).
///
/// The set is the read/search family RTK targets that is safe to compress — output the agent
/// inspects, not bytes it consumes for editing. `git`/`rsync` are intentionally excluded.
public enum WrappedCommandCatalog {
    /// Ordered for deterministic install/uninstall; `commandSet` is the membership view.
    public static let commands: [String] = ["rg", "grep", "find", "ls", "cat", "sed"]
    public static let commandSet: Set<String> = Set(commands)
}
