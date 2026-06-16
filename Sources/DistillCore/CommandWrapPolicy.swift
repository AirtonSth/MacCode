import CoreModel
import Foundation

/// Pure, deterministic policy for the RTK-style transparent command wrappers (ported from
/// chopratejas/headroom). The OS-specific pieces — running the real binary and detecting
/// whether the wrapper is the terminal command feeding the agent — live in the service
/// executable; everything here is pure so the decisions are unit-tested without spawning a
/// process or touching the filesystem.
///
/// The wrappers exist because Codex (app-server) has no automatic tool-output compression
/// hook the way the Claude SDK bridge does, so `sed`/`rg`/etc. output was only ever
/// compressed when the agent chose to pipe `| distill` — and agents skip that for these
/// commands (the "exact bytes" carve-out reads a file slice / match list as exact bytes).
/// Wrapping the commands compresses their output for EVERY provider without agent cooperation.
public enum CommandWrapPolicy {
    /// The read/search command family RTK targets that is safe to compress (canonical list in
    /// `CoreModel.WrappedCommandCatalog`, shared with the installer that creates the symlinks).
    public static var wrappedCommands: Set<String> { WrappedCommandCatalog.commandSet }

    public static func isWrapped(_ command: String) -> Bool {
        wrappedCommands.contains(commandBasename(command))
    }

    /// basename without directory, so `/bin/cat` and `cat` both resolve to `cat`.
    public static func commandBasename(_ command: String) -> String {
        (command as NSString).lastPathComponent
    }

    // MARK: - thresholds (aggressive + env-tunable)

    public static let defaultMinBytes = 1_024
    public static let defaultMinLines = 10
    /// The wrap path lowers the reversible-store floor to this so virtually any compressed wrap
    /// output (which the agent opted into being "aggressive + reversible") carries a recovery
    /// handle (`[[rc:<handle>]]`) — well below the compress threshold so even a many-short-lines
    /// output that compressed on the line count, not the byte count, stays recoverable.
    public static let reversibleStoreFloorBytes = 256

    public static func minBytes(environment: [String: String]) -> Int {
        intEnv(environment, "REMOTE_CODE_WRAP_MIN_BYTES", default: defaultMinBytes, floor: 1)
    }

    public static func minLines(environment: [String: String]) -> Int {
        intEnv(environment, "REMOTE_CODE_WRAP_MIN_LINES", default: defaultMinLines, floor: 1)
    }

    public static func isDisabled(environment: [String: String]) -> Bool {
        (environment["REMOTE_CODE_WRAP_DISABLE"] ?? "").trimmingCharacters(in: .whitespaces) == "1"
    }

    private static func intEnv(_ env: [String: String], _ key: String, default def: Int, floor: Int) -> Int {
        guard let raw = env[key], let value = Int(raw.trimmingCharacters(in: .whitespaces)) else { return def }
        return max(floor, value)
    }

    // MARK: - passthrough (never compress, regardless of size / pipeline position)

    /// Reasons a wrapped command must run untouched even when its stdout reaches the agent:
    /// it mutates files (so its stdout is not summarizable review output) or the user
    /// disabled wrapping. Returns nil when the command is eligible for compression.
    public static func passthroughReason(command: String, args: [String], environment: [String: String]) -> String? {
        if isDisabled(environment: environment) { return "disabled" }
        let name = commandBasename(command)
        // `sed -i` / `sed -i.bak` / `sed --in-place[=SUFFIX]` edits files in place — its stdout
        // is not review output, so never compress it.
        if name == "sed", args.contains(where: Self.isSedInPlaceFlag) {
            return "sed_in_place"
        }
        return nil
    }

    static func isSedInPlaceFlag(_ arg: String) -> Bool {
        arg.hasPrefix("-i") || arg == "--in-place" || arg.hasPrefix("--in-place=")
    }

    // MARK: - compression decision (pure)

    public enum WrapAction: Equatable {
        case passthrough(reason: String)
        case compress
    }

    /// The single decision the wrapper makes once it has captured the real command's stdout.
    /// FAIL-CLOSED toward passthrough: compress only when the command is the terminal command
    /// feeding the agent, the output is valid UTF-8, and it clears the size threshold. Any
    /// other case hands the bytes back verbatim so a pipeline / file / binary is never altered.
    public static func decide(
        command: String,
        isTerminalToAgent: Bool,
        outputIsValidUTF8: Bool,
        byteCount: Int,
        lineCount: Int,
        environment: [String: String]
    ) -> WrapAction {
        if !isTerminalToAgent { return .passthrough(reason: "not_terminal") }
        if !outputIsValidUTF8 { return .passthrough(reason: "binary_output") }
        if !shouldCompress(byteCount: byteCount, lineCount: lineCount, environment: environment) {
            return .passthrough(reason: "below_threshold")
        }
        return .compress
    }

    public static func shouldCompress(byteCount: Int, lineCount: Int, environment: [String: String]) -> Bool {
        byteCount > minBytes(environment: environment) || lineCount > minLines(environment: environment)
    }

    /// The distill question every wrapped command sends. A neutral EXTRACTIVE query routes the
    /// distill service to its BERT encoder lane, which selects the most relevant lines VERBATIM —
    /// validated (E4B) to beat the generative LLM on code (real lines vs a lossy summary) AND on
    /// search (full `file:line: code` matches vs paths-only). STRUCTURED output (JSON) is caught
    /// by the lossless content-router BEFORE BERT, so the query never mangles it; and the query
    /// sidesteps the no-question intent-extractor misfire (code "FAIL" / markdown "PASS" tokens).
    /// The optional return keeps room for a future command that should not compress at all.
    public static func extractionQuery(forCommand command: String) -> String? {
        "Keep the lines most important for understanding this output, verbatim; preserve file paths, line numbers, identifiers, signatures, numbers, and code exactly; drop only boilerplate and repetition."
    }

    // MARK: - faithfulness guard

    /// A command's whole output is being replaced, so a degenerate "compression" must never
    /// reach the agent. The distill model can answer as a question and return a tiny token
    /// (e.g. "NONE"/"PASS"); the deterministic router can't, but the model lane can. Reject any
    /// compressed result whose content (excluding the `[[rc:<handle>]]` recovery marker) is
    /// implausibly small for output that cleared the compress threshold — the caller then emits
    /// the raw bytes instead. An absolute floor (not a ratio) so a legitimately huge win on
    /// highly-repetitive output is still accepted.
    public static let minFaithfulCompressedBytes = 24

    public static func isFaithfulCompression(rawByteCount: Int, compressedContentByteCount: Int) -> Bool {
        compressedContentByteCount >= min(minFaithfulCompressedBytes, rawByteCount)
    }

    /// Byte length of the compressed content with a trailing `[[rc:<handle>]]` marker line and
    /// surrounding whitespace removed, so the faithfulness floor measures real content — not the
    /// ~70-byte recovery handle that would otherwise let a "NONE" token slip past the floor.
    public static func compressedContentByteCount(_ emitted: String) -> Int {
        let withoutHandle = emitted.replacingOccurrences(
            of: "\\n?\\[\\[rc:[^\\]]*\\]\\]\\s*$",
            with: "",
            options: .regularExpression
        )
        return withoutHandle.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
    }

    // MARK: - real-binary resolution (recursion guard)

    /// Resolve the REAL executable for a wrapped command, walking `pathEntries` in order and
    /// skipping (a) the managed bin directory the wrapper symlink lives in and (b) any
    /// candidate that resolves to the wrapper binary itself — so the wrapper never re-invokes
    /// itself. Returns nil when no real binary exists (the caller then behaves like the command
    /// is absent rather than shadowing a missing command).
    public static func resolveRealExecutable(
        command: String,
        pathEntries: [String],
        managedBinDirectory: String,
        isExecutableFile: (String) -> Bool,
        resolvesToSelf: (String) -> Bool
    ) -> String? {
        let name = commandBasename(command)
        let managed = normalizedDirectory(managedBinDirectory)
        for entry in pathEntries {
            let dir = entry.trimmingCharacters(in: .whitespaces)
            guard !dir.isEmpty, normalizedDirectory(dir) != managed else { continue }
            let candidate = (dir as NSString).appendingPathComponent(name)
            guard isExecutableFile(candidate), !resolvesToSelf(candidate) else { continue }
            return candidate
        }
        return nil
    }

    private static func normalizedDirectory(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
