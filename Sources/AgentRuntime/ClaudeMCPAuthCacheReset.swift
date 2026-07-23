import Foundation

/// Clears Claude Code's negative MCP-auth cache (`~/.claude/mcp-needs-auth-cache.json`)
/// right before a headless `--print` session spawns, so remote OAuth MCP servers
/// (Linear, Stripe, the claude.ai connectors) are RE-PROBED live — exactly as an
/// interactive terminal REPL does — instead of being short-circuited to
/// `needs-auth` off a stale cache entry.
///
/// WHY: in `--print` / stream-json mode the CLI reads this cache and marks every
/// listed server `needs-auth` WITHOUT attempting to connect. `claude mcp list`
/// and the interactive REPL ignore the cache and health-check live. Once an entry
/// is written (e.g. the one time a token was briefly invalid) it is never
/// invalidated — so every headless Agent App session reported the server as
/// perpetually "connecting" even though the Keychain OAuth token was valid and
/// the terminal showed it connected with its full tool set. Reproduced on
/// `claude` 2.1.218: with the file present Linear = `needs-auth`, 0 tools; after
/// deleting it the next headless session reaches `connected`, 57 tools. The file
/// holds no secrets (server names, unix-ms timestamps, opaque `mcpsrv_` ids) and
/// the CLI regenerates it on demand, so removing it is safe and self-healing.
///
/// Scope: the CLI streaming adapter only. Codex (`~/.codex` config + oauth-locks)
/// and Grok (`~/.grok/*.json` tokens, ACP passes an empty MCP override) read their
/// MCP config live in both terminal and headless, so they have no equivalent gate.
/// The opt-in Claude Agent SDK bridge is intentionally excluded — the gate was not
/// reproduced there.
///
/// Safeguards (from the sam-codex-advisor review):
/// - Kill switch: `RC_CLAUDE_MCP_AUTH_CACHE_RESET=0` disables it wholesale.
/// - Same-user only: never mutate a run-as-user target's home — we do not escalate
///   privilege to touch another account's vendor state.
/// - Regular-file only: `lstat` (no symlink follow) then `unlink`, so a symlink or
///   directory is refused and nothing is ever removed recursively.
/// - Fail-OPEN + fail-LOUD: any anomaly logs a non-secret diagnostic and the spawn
///   proceeds unchanged.
/// - App-local only: this makes NO concurrency guarantee against a terminal
///   `claude` that may rewrite the cache between our unlink and the child's read.
///   That residual is benign — a healthy terminal only re-caches servers whose
///   live probe actually failed, which are `needs-auth` regardless.
public enum ClaudeMCPAuthCacheReset {
    public static let killSwitchEnvKey = "RC_CLAUDE_MCP_AUTH_CACHE_RESET"
    static let cacheRelativePath = ".claude/mcp-needs-auth-cache.json"

    public enum Outcome: Equatable {
        case removed
        case absent
        case disabled
        case skippedForeignUser
        case skippedNotRegularFile
        case failed(String)
    }

    /// Pure decision + single-file effect. `home` is injectable so tests run
    /// against a temp directory instead of the real `~`.
    @discardableResult
    public static func reset(
        home: String,
        isForeignUser: Bool,
        environment: [String: String]
    ) -> Outcome {
        if (environment[killSwitchEnvKey] ?? "1") == "0" { return .disabled }
        if isForeignUser { return .skippedForeignUser }

        let path = (home as NSString).appendingPathComponent(cacheRelativePath)

        // lstat: never follow a symlink; only unlink a real regular file. `unlink`
        // (vs FileManager.removeItem) can never recurse into a directory even if
        // the entry is swapped after this check (TOCTOU-safe: it removes at most
        // one directory entry, never a directory's contents).
        var info = stat()
        if lstat(path, &info) != 0 { return .absent }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .skippedNotRegularFile }

        if unlink(path) == 0 { return .removed }
        return .failed("errno=\(errno)")
    }

    /// Adapter-facing wrapper: performs the reset and emits a NON-SECRET diagnostic
    /// only on the anomalous outcomes (fail-loud); the expected paths stay quiet.
    public static func resetAndLog(
        home: String,
        isForeignUser: Bool,
        environment: [String: String]
    ) {
        switch reset(home: home, isForeignUser: isForeignUser, environment: environment) {
        case .removed, .absent, .disabled, .skippedForeignUser:
            break
        case .skippedNotRegularFile:
            diagnostic("Claude MCP needs-auth cache path is not a regular file; left untouched — remote MCP tools may show as 'connecting' this session.")
        case .failed(let detail):
            diagnostic("could not clear Claude MCP needs-auth cache (\(detail)); remote OAuth MCP servers may show as 'connecting' this session.")
        }
    }

    private static func diagnostic(_ message: String) {
        FileHandle.standardError.write(Data("[RemoteCode] \(message)\n".utf8))
    }
}
