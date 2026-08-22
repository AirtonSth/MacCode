import CoreModel
import Foundation

/// Pure, deterministic policy for the RTK-style transparent command wrappers (ported from
/// chopratejas/headroom). The OS-specific pieces — running the real binary and detecting
/// whether the wrapper is the terminal command feeding the agent — live in the service
/// executable; everything here is pure so the decisions are unit-tested without spawning a
/// process or touching the filesystem.
///
/// The global interceptor covers high-volume / noisy commands (find, ls, git log/status, builds,
/// CI) and arbitrary non-interpreter command basenames. Exact-output tools (sed, rg, grep, cat,
/// head, tail, awk, …) also enter that interceptor; `passthroughReason` keeps their stdout raw
/// because agents need full line lists and file slices.
public enum CommandWrapPolicy {
    /// Canonical compressible targets in `CoreModel.WrappedCommandCatalog`.
    public static var wrappedCommands: Set<String> { WrappedCommandCatalog.commandSet }

    /// Basenames that must never be auto-compressed (wrap install or `| distill`).
    public static var exactOutputCommands: Set<String> { WrappedCommandCatalog.exactOutputCommandSet }

    public static func isWrapped(_ command: String) -> Bool {
        let name = commandBasename(command)
        // Exact-output commands enter the shared decision point and are kept raw
        // by passthroughReason. This preserves bytes without bypassing the
        // interceptor's fail-open and telemetry path.
        return !name.isEmpty && !WrappedCommandCatalog.isShebangInterpreter(name)
    }

    public static func isExactOutputCommand(_ command: String) -> Bool {
        WrappedCommandCatalog.isExactOutputCommand(command)
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

    /// Reasons a wrapped command must run untouched even when its stdout reaches the agent.
    /// Returns nil when the command is eligible for compression.
    ///
    /// Product rule (2026-07): **compress all wrapped-command stdout** except the
    /// exact-output family (rg/sed/cat/jq/…), exact git blob/match subcommands, and
    /// full patch dumps. There is **no** read-only subcommand allowlist — `gh api`,
    /// `git push` status text, merges, etc. all distill when terminal-to-agent and
    /// above threshold. Mutating *side effects* still run; only stdout may shrink.
    public static func passthroughReason(command: String, args: [String], environment: [String: String]) -> String? {
        if isDisabled(environment: environment) { return "disabled" }
        let name = commandBasename(command)
        // Defense in depth: even if an old symlink still exists for an exact-output
        // command, never compress its stdout.
        if isExactOutputCommand(name) {
            return "exact_output_command"
        }
        // `sed -i` / `sed -i.bak` / `sed --in-place[=SUFFIX]` edits files in place — its stdout
        // is not review output, so never compress it.
        if name == "sed", args.contains(where: Self.isSedInPlaceFlag) {
            return "sed_in_place"
        }
        // git grep/show/cat-file dump match lines or object bytes — treat as exact payload.
        if name == "git", isExactGitSubcommand(args) {
            return "exact_output_subcommand"
        }
        // Full patch output is source payload, not summary-friendly noise. Keep
        // it byte-for-byte exact. Only an explicit non-patch summary format may
        // opt these commands back into compression.
        if isExactPatchInvocation(command: name, args: args) {
            return "exact_patch_output"
        }
        // No subcommand allowlist: every other wrapped invocation is compress-eligible.
        return nil
    }

    // PERF: passthroughReason runs on every PATH-wrapped spawn. Array literals
    // for git exact-output subcommands / patch flags reallocated membership
    // tables per decision; share process-wide Sets (membership unchanged).
    private static let exactGitOutputSubcommands: Set<String> = [
        "grep", "show", "cat-file", "blame",
    ]
    private static let explicitDiffSummaryFlags: Set<String> = [
        "--stat", "--shortstat", "--numstat", "--name-only", "--name-status",
    ]
    private static let exactPatchEmissionFlags: Set<String> = [
        "-p", "-u", "--patch", "--patch-with-raw", "--patch-with-stat",
        "-c", "--cc", "--combined-all-paths", "--raw",
    ]

    /// Subcommands whose full stdout is the agent payload (matches / blob text).
    static func isExactGitSubcommand(_ args: [String]) -> Bool {
        let positional = args
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("-") }
        guard let sub = positional.first else { return false }
        return exactGitOutputSubcommands.contains(sub)
    }

    static func isSedInPlaceFlag(_ arg: String) -> Bool {
        arg.hasPrefix("-i") || arg == "--in-place" || arg.hasPrefix("--in-place=")
    }

    /// `git diff`, `gh pr diff`, and `glab mr diff` emit complete patches by
    /// default. A complete patch is exact agent input and must never be sent to
    /// Distill. Explicit summary formats remain eligible, unless a second flag
    /// also asks the tool to emit a patch.
    static func isExactPatchInvocation(command: String, args: [String]) -> Bool {
        let normalized = args.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let patchArguments: ArraySlice<String>
        switch command {
        case "git":
            guard let index = normalized.firstIndex(of: "diff") else { return false }
            patchArguments = normalized.suffix(from: normalized.index(after: index))
        case "gh":
            guard nestedCommand(normalized, first: "pr", second: "diff") else { return false }
            let index = normalized.firstIndex(of: "diff")!
            patchArguments = normalized.suffix(from: normalized.index(after: index))
        case "glab":
            guard nestedCommand(normalized, first: "mr", second: "diff") else { return false }
            let index = normalized.firstIndex(of: "diff")!
            patchArguments = normalized.suffix(from: normalized.index(after: index))
        default:
            return false
        }

        let hasSummaryFormat = patchArguments.contains(where: isExplicitDiffSummaryFlag)
        let alsoEmitsPatch = patchArguments.contains(where: isPatchEmissionFlag)
        return !hasSummaryFormat || alsoEmitsPatch
    }

    private static func nestedCommand(_ arguments: [String], first: String, second: String) -> Bool {
        let positional = arguments.filter { !$0.isEmpty && !$0.hasPrefix("-") }
        return positional.count >= 2 && positional[0] == first && positional[1] == second
    }

    private static func isExplicitDiffSummaryFlag(_ argument: String) -> Bool {
        explicitDiffSummaryFlags.contains(argument) || argument.hasPrefix("--stat=")
    }

    private static func isPatchEmissionFlag(_ argument: String) -> Bool {
        if exactPatchEmissionFlags.contains(argument) {
            return true
        }
        return argument.hasPrefix("-u")
            || argument.hasPrefix("--unified")
            || argument.hasPrefix("--word-diff")
            || argument.hasPrefix("--color-words")
    }

    /// Legacy helper kept for tests/diagnostics. **Not** used by `passthroughReason`
    /// (product: compress all wrapped subcommands except exact-output carve-outs).
    private static func requiresReadOnlySubcommand(_ command: String) -> Bool {
        ["git", "gh", "glab", "swift", "xcodebuild"].contains(command)
    }

    /// Legacy allowlist (unused by compress gate). Prefer `passthroughReason == nil`
    /// for eligibility; kept so historical tests can still describe old boundaries.
    static func isAllowedReadOnlyInvocation(command: String, args: [String]) -> Bool {
        let normalized = args
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !normalized.isEmpty || command == "xcodebuild" else { return false }

        switch command {
        case "git":
            guard let subcommand = normalized.first(where: { !$0.hasPrefix("-") }) else { return false }
            if [
                "diff", "show", "log", "status", "grep",
                "ls-files", "rev-parse", "describe"
            ].contains(subcommand) {
                return true
            }
            if subcommand == "branch" {
                let rest = Array(normalized.drop { $0 != subcommand }.dropFirst())
                return rest.isEmpty || rest.allSatisfy { ["--list", "-a", "-r", "--show-current", "-v", "-vv"].contains($0) }
            }
            if subcommand == "remote" {
                let rest = Array(normalized.drop { $0 != subcommand }.dropFirst())
                return rest.isEmpty || rest == ["-v"] || rest.first == "show" || rest.first == "get-url"
            }
            if subcommand == "tag" {
                return normalized.contains("-l") || normalized.contains("--list")
            }
            if subcommand == "stash" {
                return normalized.dropFirst().first == "show" || normalized.dropFirst().first == "list"
            }
            return false
        case "gh":
            return hasAllowedNestedCommand(normalized, allowed: [
                ["pr", "diff"], ["pr", "view"], ["pr", "status"], ["pr", "checks"], ["pr", "list"],
                ["run", "view"], ["run", "list"], ["run", "watch"],
                ["repo", "view"], ["issue", "view"], ["issue", "list"]
            ])
        case "glab":
            return hasAllowedNestedCommand(normalized, allowed: [
                ["mr", "diff"], ["mr", "view"], ["mr", "list"], ["mr", "status"],
                ["pipeline", "view"], ["pipeline", "list"], ["pipeline", "status"],
                ["ci", "view"], ["job", "trace"], ["issue", "view"], ["issue", "list"]
            ])
        case "swift":
            if normalized.first == "test" || normalized.first == "build" { return true }
            if normalized.count >= 2, normalized[0] == "package" {
                return ["describe", "dump-package", "show-dependencies"].contains(normalized[1])
            }
            return false
        case "xcodebuild":
            return normalized.isEmpty ||
                normalized.contains("test") ||
                normalized.contains("build") ||
                normalized.contains("-list") ||
                normalized.contains("-showbuildsettings") ||
                normalized.contains("-showsdks") ||
                normalized.contains("-version")
        default:
            return true
        }
    }

    private static func hasAllowedNestedCommand(_ args: [String], allowed: [[String]]) -> Bool {
        let positional = args.filter { !$0.hasPrefix("-") }
        return allowed.contains { prefix in
            positional.count >= prefix.count && Array(positional.prefix(prefix.count)) == prefix
        }
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

    /// Claude Code writes a top-level Bash command's stdout/stderr directly to
    /// a provider-owned task file instead of a pipe. A wrapped command whose
    /// stdout is exactly this file is terminal-to-agent; a pipeline stage still
    /// has a pipe, and an ordinary user redirect has a different path.
    ///
    /// Keep admission deliberately structural and narrow: the runtime provider
    /// must be Claude and `claude-<uid>` must match the wrapper process's real
    /// user ID. The current Claude layout is:
    /// `<temp>/claude-<uid>/<workspace>/<session UUID>/tasks/<task>.output`.
    public static func isClaudeBashCaptureTransport(
        path: String,
        provider: String?,
        userID: UInt32
    ) -> Bool {
        guard provider == "claude" else { return false }
        guard path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let claudeIndex = components.firstIndex(of: "claude-\(userID)") else {
            return false
        }

        // Only OS temporary roots. `/tmp` canonicalizes to `/private/tmp` on
        // macOS; Claude may also honor the per-user `/var/folders/.../T` root.
        let prefix = Array(components[..<claudeIndex])
        let isTmp = prefix == ["tmp"] || prefix == ["private", "tmp"]
        let isDarwinUserTemp = prefix.count >= 4
            && (prefix.starts(with: ["var", "folders"])
                || prefix.starts(with: ["private", "var", "folders"]))
            && prefix.last == "T"
        guard isTmp || isDarwinUserTemp else { return false }

        // Exactly workspace/session/tasks/file after `claude-<uid>`; the UUID
        // prevents a user-created generic `tasks/foo.output` redirect matching.
        guard components.count == claudeIndex + 5,
              !components[claudeIndex + 1].isEmpty,
              UUID(uuidString: components[claudeIndex + 2]) != nil,
              components[claudeIndex + 3] == "tasks" else {
            return false
        }
        let filename = components[claudeIndex + 4]
        guard filename.hasSuffix(".output") else { return false }
        let stem = filename.dropLast(".output".count)
        return !stem.isEmpty && stem.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    /// The distill question every wrapped command sends. A neutral EXTRACTIVE query routes the
    /// distill service to its BERT encoder lane, which selects the most relevant lines VERBATIM —
    /// validated (E4B) to beat the generative LLM on code (real lines vs a lossy summary) AND on
    /// search (full `file:line: code` matches vs paths-only). STRUCTURED output (JSON) is caught
    /// by the lossless content-router BEFORE BERT, so the query never mangles it; and the query
    /// sidesteps the no-question intent-extractor misfire (code "FAIL" / markdown "PASS" tokens).
    /// The optional return keeps room for a future command that should not compress at all.
    public static func extractionQuery(forCommand command: String) -> String? {
        "Keep the lines most important for understanding this output, verbatim; preserve exact literals, identifiers, signatures, numbers, and code; drop only boilerplate and repetition."
    }

    // MARK: - faithfulness guard

    /// A command's whole output is being replaced, so a degenerate "compression" must never
    /// reach the agent. The distill model can answer as a question and return a tiny token
    /// (e.g. "NONE"/"PASS"); the deterministic router can't, but the model lane can. Reject any
    /// compressed result whose content (excluding trailing recovery and applied markers) is
    /// implausibly small for output that cleared the compress threshold — the caller then emits
    /// the raw bytes instead. An absolute floor (not a ratio) so a legitimately huge win on
    /// highly-repetitive output is still accepted.
    public static let minFaithfulCompressedBytes = 24

    public static func isFaithfulCompression(rawByteCount: Int, compressedContentByteCount: Int) -> Bool {
        compressedContentByteCount >= min(minFaithfulCompressedBytes, rawByteCount)
    }

    // PERF: compile once — was recompiled via replacingOccurrences(.regularExpression)
    // on every wrap faithfulness floor check after compress.
    private static let trailingRecoveryHandleRegex = try! NSRegularExpression(
        pattern: #"\n?\[\[rc:[^\]]*\]\]\s*$"#
    )

    /// Byte length of the compressed content with trailing applied-receipt and
    /// `[[rc:<handle>]]` recovery lines removed, so the faithfulness floor measures real
    /// content — not protocol metadata that would let a "NONE" token slip past the floor.
    public static func compressedContentByteCount(_ emitted: String) -> Int {
        let withoutReceipt = DistillAppliedReceipt.strip(emitted)
        let ns = withoutReceipt as NSString
        let full = NSRange(location: 0, length: ns.length)
        let withoutHandle = trailingRecoveryHandleRegex.stringByReplacingMatches(
            in: withoutReceipt,
            options: [],
            range: full,
            withTemplate: ""
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
