import Foundation

/// Provider basenames intercepted by the RemoteCode nested-provider controller.
///
/// When a shell inside a RemoteCode agent turn runs `grok`, `claude`, or `codex`
/// by bare name, the managed PATH entry (`~/.remote-code/bin`) resolves to a
/// RemoteCode-owned proxy that:
/// - inherits the parent provider environment as-is
/// - records a content-free Subagents lifecycle receipt (begin → end)
/// - execs the real provider CLI outside the managed bin (no recursion)
///
/// Provider proxies are available whenever a thread-scoped RemoteCode provider
/// environment is created.
///
/// Skills should not need a manual `subagent begin/end` bridge for nested
/// provider CLI invocations; the global controller owns that lifecycle.
/// Manual telemetry remains for non-provider workers only.
///
/// Main agent turns must not launch through these proxies: host launchers resolve
/// absolute provider binaries and skip managed-bin provider shims.
public enum ProviderProxyCatalog {
    /// Ordered for deterministic install/uninstall.
    public static let providers: [String] = [
        "claude",
        "codex",
        "grok",
    ]

    public static let providerSet: Set<String> = Set(providers)

    public static func isProviderProxyCommand(_ command: String) -> Bool {
        providerSet.contains(commandBasename(command))
    }

    public static func commandBasename(_ command: String) -> String {
        (command as NSString).lastPathComponent
    }

    /// Map a basename to `AgentProvider` when it is a managed proxy target.
    public static func agentProvider(forCommand command: String) -> AgentProvider? {
        AgentProvider(rawValue: commandBasename(command))
    }
}
