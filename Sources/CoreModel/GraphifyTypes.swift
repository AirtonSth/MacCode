import Foundation
import CryptoKit

// MARK: - Graphify domain (Token Saver isolation: no Distill coupling)

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
    - Before broad greps/globs/multi-file reads for architecture, ownership, or "where is X" questions, run `graphify query "<question>"` first when a graph is available.
    - Use `graphify path "A" "B"` and `graphify explain "Symbol"` to trace connections instead of reading whole modules.
    - Prefer `--graph "$RC_GRAPHIFY_GRAPH_JSON"` when that env var is set; otherwise run from the active repo root (never a multi-repo parent folder).
    - If multiple roots are listed in `$RC_GRAPHIFY_ROOTS`, pick the root that matches the question; query each only if needed.
    - If `$RC_GRAPHIFY_AMBIGUOUS=1`, `$RC_GRAPHIFY_STALE=1`, or graphify/binary/graph is unavailable, fail open and use normal tools (state that briefly). Prefer graph query again on the next turn after the host refreshes.
    - Do not ask the user to run Graphify; the host indexes continuously (send + FSEvents). Do not dump graph.json into the chat.
    """

    public static let instructions = """
    \(beginMarker)
    \(agentInstructionsBody)
    \(endMarker)
    """

    /// Compact per-turn path hint for providers that reuse a session without
    /// re-applying system/developer instructions (Claude Agent SDK long sessions).
    public static func augmentTurnPrompt(_ prompt: String, environment: [String: String]) -> String {
        guard environment["RC_GRAPHIFY_ENABLED"] == "1" else { return prompt }
        var lines: [String] = []
        if let graph = environment["RC_GRAPHIFY_GRAPH_JSON"], !graph.isEmpty {
            lines.append("[Graphify] Prefer: graphify query \"…\" --graph \(graph)")
        }
        if let roots = environment["RC_GRAPHIFY_ROOTS"], !roots.isEmpty {
            let first = roots.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? roots
            lines.append("[Graphify] Active root: \(first)")
        }
        if environment["RC_GRAPHIFY_STALE"] == "1" {
            lines.append("[Graphify] Graph may be refreshing; fail open if results look incomplete.")
        }
        if environment["RC_GRAPHIFY_AMBIGUOUS"] == "1" {
            lines.append("[Graphify] Multi-repo ambiguous; fail open if unsure which root applies.")
        }
        guard !lines.isEmpty else { return prompt }
        return prompt + "\n\n" + lines.joined(separator: "\n")
    }
}
