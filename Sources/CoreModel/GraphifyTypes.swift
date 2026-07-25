import Foundation
import CryptoKit

// MARK: - Graphify domain
// Host Graphify runtime is gated by Token Saver (see AppSettings.isGraphifyRuntimeActive).
// Distill is still a separate Token Saver path — Graphify does not couple to Distill
// compressors, but both require tokenSaverEnabled at the product gate.

/// Identity of a git repository for Graphify coalesce/cache.
/// Equality and hashing use ONLY the normalized absolute `git-common-dir`.
public struct GraphifyRepoKey: Hashable, Codable, Sendable, Equatable {
    /// Absolute, standardized path of `git rev-parse --git-common-dir`.
    public let commonDir: String

    public init(commonDir: String) {
        self.commonDir = URL(fileURLWithPath: commonDir).standardizedFileURL.path
    }

    public static func == (lhs: GraphifyRepoKey, rhs: GraphifyRepoKey) -> Bool {
        lhs.commonDir == rhs.commonDir
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(commonDir)
    }

    /// Stable App Support directory name for this identity.
    public var artifactDirectoryName: String {
        let digest = SHA256.hash(data: Data(commonDir.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// A concrete checkout path (main worktree or linked worktree).
/// Artifact storage is keyed by (commonDir + displayRoot) so divergent worktrees
/// do not clobber each other (Codex advisor: common-dir alone is insufficient).
public struct GraphifyCheckout: Codable, Sendable, Equatable {
    public let key: GraphifyRepoKey
    /// Absolute toplevel from `git rev-parse --show-toplevel`.
    public let displayRoot: String

    public init(key: GraphifyRepoKey, displayRoot: String) {
        self.key = key
        self.displayRoot = URL(fileURLWithPath: displayRoot).standardizedFileURL.path
    }

    /// Stable App Support directory for this exact checkout (worktree-aware).
    public var artifactDirectoryName: String {
        let material = key.commonDir + "\n" + displayRoot
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Scheduler identity (unique per worktree checkout).
    public var scheduleID: String { artifactDirectoryName }
}

public enum GraphifyWorkspaceKind: Codable, Sendable, Equatable {
    case singleRepo(GraphifyCheckout)
    case multiRepoContainer(children: [GraphifyCheckout])
    case plainFolder(String)
}

public enum GraphifyRootStatus: String, Codable, Sendable, Equatable {
    case missing
    case fresh
    case stale
    case building
    case unavailable
    case ambiguous
    case error
}

public struct GraphifyRootBinding: Codable, Sendable, Equatable {
    public let checkout: GraphifyCheckout
    public let status: GraphifyRootStatus
    /// Why this root was selected: thread_cwd, worktree, attachment, sticky_pin, pinned.
    public let reason: String
    public let artifactRoot: String?

    public init(
        checkout: GraphifyCheckout,
        status: GraphifyRootStatus,
        reason: String,
        artifactRoot: String? = nil
    ) {
        self.checkout = checkout
        self.status = status
        self.reason = reason
        self.artifactRoot = artifactRoot
    }
}

public struct GraphifyThreadWorkingSet: Codable, Sendable, Equatable {
    public let threadId: UUID?
    public let workspaceKind: String
    public let roots: [GraphifyRootBinding]
    public let ambiguous: Bool

    public init(
        threadId: UUID? = nil,
        workspaceKind: String,
        roots: [GraphifyRootBinding],
        ambiguous: Bool
    ) {
        self.threadId = threadId
        self.workspaceKind = workspaceKind
        self.roots = roots
        self.ambiguous = ambiguous
    }

    public static func empty(kind: String, threadId: UUID? = nil) -> GraphifyThreadWorkingSet {
        GraphifyThreadWorkingSet(threadId: threadId, workspaceKind: kind, roots: [], ambiguous: kind == "multiRepoContainer")
    }
}

public enum GraphifyEnsureMode: String, Codable, Sendable, Equatable {
    case verify
    case update
    case full
}

/// Stable query-first instructions when Graphify is enabled.
/// Injected into provider system/developer prompts (same pattern as Distill).
public enum GraphifyStableSkillText {
    public static let beginMarker = "<!-- graphify skill: begin -->"
    public static let endMarker = "<!-- graphify skill: end -->"

    /// Compact mandatory rules — always the same text for prompt-cache friendliness.
    public static let agentInstructionsBody = """
    CRITICAL (Graphify / codebase map — RemoteCode):
    - Canonical graph path is ONLY `$RC_GRAPHIFY_GRAPH_JSON` (and `$RC_GRAPHIFY_ARTIFACT_ROOT`). Host stores graphs under Application Support by default — NOT `./graphify-out/` in the repo. Missing `graphify-out/` in the working tree does NOT mean there is no graph.
    - To check if a graph exists: `test -f "$RC_GRAPHIFY_GRAPH_JSON" && echo yes` (or `ls "$RC_GRAPHIFY_GRAPH_JSON"`). Never answer "no graph" from a failed look at repo `graphify-out/`.
    - Before broad greps/globs/multi-file reads for architecture, ownership, or "where is X", run: `graphify query "<question>" --graph "$RC_GRAPHIFY_GRAPH_JSON"` when that env var is set.
    - Use `graphify path "A" "B" --graph "$RC_GRAPHIFY_GRAPH_JSON"` and `graphify explain "Symbol" --graph "$RC_GRAPHIFY_GRAPH_JSON"` instead of reading whole modules.
    - If `$RC_GRAPHIFY_GRAPH_JSON` is unset: check `$RC_GRAPHIFY_ARTIFACT_ROOT/graph.json`, then fail open (normal tools). Never invent or require a repo-local `graphify-out/`.
    - If multiple roots are listed in `$RC_GRAPHIFY_ROOTS`, pick the root that matches the question; query each only if needed (still via `$RC_GRAPHIFY_GRAPH_JSON` when present).
    - If `$RC_GRAPHIFY_AMBIGUOUS=1`, `$RC_GRAPHIFY_STALE=1`, or binary/graph is unavailable, fail open and use normal tools (state that briefly). Prefer graph query again on the next turn after the host refreshes.
    - Do not ask the user to run Graphify or `/graphify`; the host indexes continuously (send + FSEvents). You do not "generate" the graph in-session — the host does. Do not dump graph.json into the chat.
    """

    public static let instructions = """
    \(beginMarker)
    \(agentInstructionsBody)
    \(endMarker)
    """

    /// Short high-signal banner with absolute paths. Prefixed so models cannot
    /// miss it when answering "tem graph?" / "já tem graphify?" style questions.
    public static func runtimeStatusBanner(environment: [String: String]) -> String? {
        guard environment["RC_GRAPHIFY_ENABLED"] == "1" else { return nil }
        var lines: [String] = [
            "HOST GRAPHIFY STATUS (read before answering whether a graph exists):"
        ]
        if let graph = environment["RC_GRAPHIFY_GRAPH_JSON"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !graph.isEmpty {
            lines.append("- Graph EXISTS at absolute path: \(graph)")
            lines.append("- This is NOT repo ./graphify-out/ (host default stores under Application Support).")
            lines.append("- To verify: test -f \"\(graph)\" && echo yes")
            lines.append("- Query: graphify query \"…\" --graph \"\(graph)\"")
        } else if let artifact = environment["RC_GRAPHIFY_ARTIFACT_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !artifact.isEmpty {
            let candidate = artifact.hasSuffix("/") ? artifact + "graph.json" : artifact + "/graph.json"
            lines.append("- No RC_GRAPHIFY_GRAPH_JSON this turn; check artifact: \(candidate)")
            lines.append("- Missing repo ./graphify-out/ is NORMAL and is NOT proof the graph is absent.")
        } else {
            lines.append("- Graphify host enabled but no path this turn (building/unavailable/ambiguous).")
            lines.append("- Missing repo ./graphify-out/ is NORMAL — do NOT answer \"no graph\" from that alone; fail open.")
        }
        if let roots = environment["RC_GRAPHIFY_ROOTS"], !roots.isEmpty {
            let first = roots.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? roots
            lines.append("- Active root: \(first)")
        }
        if environment["RC_GRAPHIFY_STALE"] == "1" {
            lines.append("- Graph may be refreshing; fail open if query looks incomplete.")
        }
        if environment["RC_GRAPHIFY_AMBIGUOUS"] == "1" {
            lines.append("- Multi-repo ambiguous this turn; fail open if unsure which root applies.")
        }
        return lines.joined(separator: "\n")
    }

    /// Compact per-turn path hint for providers that reuse a session without
    /// re-applying system/developer instructions (Claude Agent SDK long sessions).
    /// Prefixed (not suffixed) so the absolute path is seen before tool calls.
    public static func augmentTurnPrompt(_ prompt: String, environment: [String: String]) -> String {
        guard let banner = runtimeStatusBanner(environment: environment) else { return prompt }
        return banner + "\n\n" + prompt
    }
}
