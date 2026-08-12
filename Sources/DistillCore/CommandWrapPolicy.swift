import CoreModel
import Foundation

/// Pure, deterministic policy for the RTK-style transparent command wrappers (ported from
/// chopratejas/headroom). The OS-specific pieces — running the real binary and detecting
/// whether the wrapper is the terminal command feeding the agent — live in the service
/// executable; everything here is pure so the decisions are unit-tested without spawning a
/// process or touching the filesystem.
///
/// Wrappers cover every runtime-discovered non-interactive command.
/// Exact-output tools (sed, rg, grep, cat, head, tail, awk, …) are intentionally NOT
/// wrapped: agents need full line lists and file slices; distill would drop payload lines.
public enum CommandWrapPolicy {
    /// Output ownership for a shell payload. A mixed payload cannot be safely
    /// compressed as one aggregate because exact-output commands (for example
    /// `rg` or `command -v`) share the shell's stdout with ordinary commands.
    /// The wrapper therefore lets child wrappers handle only the mixed case.
    public enum ShellOutputClassification: String, Sendable, Equatable {
        case ordinaryOnly = "ordinary_only"
        case exactOnly = "exact_only"
        case mixed
    }

    /// One command in a deliberately small shell subset that is safe to run
    /// independently while preserving the ordering of a `;` sequence.
    public struct BoundedShellSegment: Sendable, Equatable {
        public let source: String
        public let preservesExactOutput: Bool

        public init(source: String, preservesExactOutput: Bool) {
            self.source = source
            self.preservesExactOutput = preservesExactOutput
        }
    }

    /// Compressible wrap targets only (canonical list in `CoreModel.WrappedCommandCatalog`).
    public static var wrappedCommands: Set<String> { WrappedCommandCatalog.commandSet }

    /// Basenames that must never be auto-compressed (wrap install or `| distill`).
    public static var exactOutputCommands: Set<String> { WrappedCommandCatalog.exactOutputCommandSet }

    public static func isWrapped(_ command: String) -> Bool {
        wrappedCommands.contains(commandBasename(command))
    }

    /// Runtime-discovered wrappers are not limited to the historical catalog.
    /// Every PATH executable is eligible except exact-output, TUI, provider,
    /// and RemoteCode-owned control basenames.
    public static func isAutoWrappable(_ command: String) -> Bool {
        WrappedCommandCatalog.isAutoWrappableCommand(command)
    }

    public static func isExactOutputCommand(_ command: String) -> Bool {
        WrappedCommandCatalog.isExactOutputCommand(command)
    }

    /// basename without directory, so `/bin/cat` and `cat` both resolve to `cat`.
    public static func commandBasename(_ command: String) -> String {
        (command as NSString).lastPathComponent
    }

    // MARK: - legacy thresholds (retained for explicit callers; universal wrappers ignore them)

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
    /// Product rule (2026-08): **distill all wrapped-command output** except the
    /// exact-output family (rg/sed/cat/jq/…), exact git blob/match subcommands, and
    /// full patch dumps. There is **no** read-only subcommand allowlist — `gh api`,
    /// `git push` status text, merges, etc. all distill when terminal-to-agent.
    /// Mutating *side effects* still run; only captured output may shrink.
    public static func passthroughReason(command: String, args: [String], environment: [String: String]) -> String? {
        if isDisabled(environment: environment) { return "disabled" }
        // An outer universal wrapper owns the final agent-facing stream. Inner
        // wrappers still execute the real binary but must not distill twice.
        if environment["REMOTE_CODE_WRAP_PARENT"] == "1" { return "nested_wrapper" }
        let name = commandBasename(command)
        // Defense in depth: even if an old symlink still exists for an exact-output
        // command, never compress its stdout.
        if isExactOutputCommand(name) {
            return "exact_output_command"
        }
        // macOS `env -S` / `--split-string` embeds the child command in an
        // option value, so ordinary argv forwarding cannot identify its exact
        // or interactive shape safely. Keep the whole invocation untouched.
        if name == "env", isEnvSplitStringInvocation(args) {
            return "env_split_string"
        }
        if let reason = forwardedExactOutputReason(command: name, args: args) {
            return reason
        }
        if WrappedCommandCatalog.isInteractiveCommand(name) {
            return "interactive_command"
        }
        if let reason = interactiveArgumentReason(command: name, args: args) {
            return reason
        }
        if isShellLauncher(name) {
            if shellInvocationIsInteractive(args) {
                return "interactive_shell"
            }
            if let payload = shellCommandPayload(args) {
                if shellPayloadContainsDistill(payload) {
                    return "explicit_distill_pipeline"
                }
                switch shellOutputClassification(payload) {
                case .exactOnly:
                    return "exact_output_shell_payload"
                case .mixed:
                    // Preserve exact segments while allowing ordinary child
                    // wrappers to compress their own terminal stdout. The
                    // runner scopes a marker to the validated payload; the
                    // original commands stay intact and no explicit pipe is needed.
                    return "segmented_shell"
                case .ordinaryOnly:
                    break
                }
            }
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

    private static func isEnvSplitStringInvocation(_ args: [String]) -> Bool {
        args.contains { argument in
            argument == "-S"
                || argument == "--split-string"
                || argument.hasPrefix("--split-string=")
                || (argument.hasPrefix("-S") && argument.count > 2)
        }
    }

    /// `env`, `command`, `xargs`, and `time` can own an otherwise exact-output child while
    /// remaining ordinary universal wrapper commands themselves. Preserve the
    /// child's byte-exact stdout without making every invocation of these
    /// forwarding commands a passthrough.
    private static func forwardedExactOutputReason(command: String, args: [String]) -> String? {
        guard let childArguments = forwardedChildArguments(command: command, args: args),
              let child = childArguments.first else {
            return nil
        }
        guard invocationLooksExactOutput(
            command: child,
            args: Array(childArguments.dropFirst())
        ) else { return nil }
        return "exact_output_forwarded"
    }

    private static func forwardedChildArguments(command: String, args: [String]) -> [String]? {
        switch command.lowercased() {
        case "env":
            return childArgumentsAfterEnvOptions(args)
        case "xargs":
            return childArgumentsAfterOptions(
                args,
                optionsWithSeparateValues: xargsOptionsWithSeparateValues
            )
        case "command":
            return childArgumentsAfterCommandOptions(args)
        case "time":
            return childArgumentsAfterOptions(
                args,
                optionsWithSeparateValues: timeOptionsWithSeparateValues
            )
        default:
            return nil
        }
    }

    private static func childArgumentsAfterEnvOptions(_ args: [String]) -> [String]? {
        var index = 0
        var optionsEnded = false
        while index < args.count {
            let argument = args[index]
            if !optionsEnded, argument == "--" {
                optionsEnded = true
                index += 1
                continue
            }
            if !optionsEnded, argument.hasPrefix("-") {
                if envOptionsWithSeparateValues.contains(argument) {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            // NAME=VALUE assignments precede the forwarded command, including
            // after `--`; a non-assignment positional is the child executable.
            if argument.contains("=") {
                index += 1
                continue
            }
            break
        }
        return index < args.count ? Array(args[index...]) : nil
    }

    private static func childArgumentsAfterCommandOptions(_ args: [String]) -> [String]? {
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                index += 1
                break
            }
            guard argument.hasPrefix("-") else { break }
            index += 1
        }
        return index < args.count ? Array(args[index...]) : nil
    }

    private static func childArgumentsAfterOptions(
        _ args: [String],
        optionsWithSeparateValues: Set<String>
    ) -> [String]? {
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                index += 1
                break
            }
            guard argument.hasPrefix("-") else { break }
            if optionsWithSeparateValues.contains(argument) {
                index += 2
            } else {
                // Flags and joined short/long options (for example `-n1` or
                // `--delimiter=,`) are self-contained.
                index += 1
            }
        }
        return index < args.count ? Array(args[index...]) : nil
    }

    private static let envOptionsWithSeparateValues: Set<String> = [
        "-u", "--unset", "-C", "--chdir", "-P",
        "-S", "--split-string",
    ]

    private static let xargsOptionsWithSeparateValues: Set<String> = [
        "-a", "-d", "-E", "-I", "-J", "-L", "-n", "-P", "-R", "-S", "-s",
        "--arg-file", "--delimiter", "--eof", "--max-args", "--max-chars",
        "--max-lines", "--max-procs", "--replace",
    ]

    private static let timeOptionsWithSeparateValues: Set<String> = [
        "-f", "-o", "--format", "--output",
    ]

    /// Classifies a single shell invocation after argv has already been split.
    /// Forwarders recurse into their child so `env git -C /repo show`,
    /// `command rg`, and macOS `xargs -J {} sed ...` retain the child's exact
    /// stdout contract instead of being mistaken for ordinary wrapper output.
    static func invocationLooksExactOutput(command: String, args: [String]) -> Bool {
        let name = commandBasename(command).lowercased()
        if isExactOutputCommand(name) {
            return true
        }
        if isShellLauncher(name), let payload = shellCommandPayload(args) {
            // A nested shell can hide an exact child behind its own `-c`; keep
            // that byte-exact intent visible to the outer shell classifier.
            return shellOutputClassification(payload) != .ordinaryOnly
        }
        if name == "eval" {
            // `eval` reparses its arguments as shell source. Its child shape is
            // intentionally not guessed; preserving the aggregate is the
            // fail-closed choice for exact output hidden in that source.
            return true
        }
        if name == "git" {
            return isExactGitSubcommand(args) || isExactPatchInvocation(command: name, args: args)
        }
        // `command -v/-V` produces command-resolution data rather than running
        // a child. Its output is itself the exact payload requested by the shell.
        if name == "command", commandQueriesResolution(args) {
            return true
        }
        guard let childArguments = forwardedChildArguments(command: name, args: args),
              let child = childArguments.first else {
            return false
        }
        return invocationLooksExactOutput(
            command: child,
            args: Array(childArguments.dropFirst())
        )
    }

    private static func commandQueriesResolution(_ args: [String]) -> Bool {
        for argument in args {
            if argument == "--" || !argument.hasPrefix("-") {
                return false
            }
            if !argument.hasPrefix("--"), argument.dropFirst().contains(where: { $0 == "v" || $0 == "V" }) {
                return true
            }
        }
        return false
    }

    /// Some otherwise ordinary command basenames become terminal-owned only for
    /// particular argument shapes. Keep this list narrow: ordinary scripts,
    /// non-patch git operations, non-TTY containers, and npm init --yes remain
    /// eligible for normal output handling.
    private static func interactiveArgumentReason(command: String, args: [String]) -> String? {
        switch command.lowercased() {
        case "python", "python3":
            if args.isEmpty || args.contains(where: isPythonInteractiveFlag) {
                return "interactive_arguments"
            }
        case "node":
            if args.isEmpty || args.contains(where: isNodeInteractiveFlag) {
                return "interactive_arguments"
            }
        case "sqlite3":
            if !sqliteInvocationHasStatement(args) {
                return "interactive_arguments"
            }
        case "git":
            if isInteractiveGitInvocation(args) {
                return "interactive_arguments"
            }
        case "docker":
            if isInteractiveContainerInvocation(args, subcommands: ["run", "exec", "attach"]) {
                return "interactive_arguments"
            }
        case "kubectl":
            if isInteractiveContainerInvocation(args, subcommands: ["exec", "attach", "run"]) {
                return "interactive_arguments"
            }
        case "npm":
            if isInteractiveNpmInit(args) {
                return "interactive_arguments"
            }
        default:
            break
        }
        return nil
    }

    private static func isPythonInteractiveFlag(_ argument: String) -> Bool {
        argument == "--interactive"
            || (argument.hasPrefix("-")
                && !argument.hasPrefix("--")
                && argument.dropFirst().contains("i"))
    }

    private static func isNodeInteractiveFlag(_ argument: String) -> Bool {
        argument == "--interactive"
            || argument.hasPrefix("--interactive=")
            || (argument.hasPrefix("-")
                && !argument.hasPrefix("--")
                && argument.dropFirst().contains("i"))
    }

    /// `sqlite3` starts its REPL when argv contains no SQL statement. A database
    /// path alone is still interactive; a second positional is a finite command.
    private static func sqliteInvocationHasStatement(_ args: [String]) -> Bool {
        var index = 0
        var positionalCount = 0
        var optionsEnded = false
        while index < args.count {
            let argument = args[index]
            if !optionsEnded, argument == "--" {
                optionsEnded = true
                index += 1
                continue
            }
            if !optionsEnded, argument.hasPrefix("-") {
                index += sqliteOptionsWithSeparateValues.contains(argument) ? 2 : 1
                continue
            }
            positionalCount += 1
            if positionalCount >= 2 { return true }
            index += 1
        }
        return false
    }

    private static let sqliteOptionsWithSeparateValues: Set<String> = [
        "-cmd", "-init", "-separator", "-newline", "-nullvalue",
    ]

    private static func isInteractiveGitInvocation(_ args: [String]) -> Bool {
        guard let subcommandIndex = firstGitSubcommandIndex(args) else { return false }
        let subcommand = args[subcommandIndex].lowercased()
        let subcommandArgs = args.dropFirst(subcommandIndex + 1)
        switch subcommand {
        case "add":
            return subcommandArgs.contains(where: isGitInteractivePatchFlag)
        case "commit":
            // git commit opens the editor unless a message/file/reuse option or
            // --no-edit supplies the message non-interactively.
            if subcommandArgs.contains("-e") || subcommandArgs.contains("--edit") {
                return true
            }
            return !subcommandArgs.contains(where: isGitCommitMessageFlag)
        case "rebase":
            return subcommandArgs.contains("-i") || subcommandArgs.contains("--interactive")
        default:
            return false
        }
    }

    private static func firstGitSubcommandIndex(_ args: [String]) -> Int? {
        var index = 0
        while index < args.count {
            let argument = args[index]
            guard !argument.isEmpty else {
                index += 1
                continue
            }
            if argument == "--" {
                return nil
            }
            if !argument.hasPrefix("-") {
                return index
            }
            if gitGlobalOptionsWithSeparateValues.contains(argument) {
                // A malformed missing value is not an interactive shape; let
                // the real Git process report it rather than guessing.
                index += 2
                continue
            }
            if argument.hasPrefix("-C") && argument.count > 2
                || argument.hasPrefix("-c") && argument.count > 2
                || argument.hasPrefix("--git-dir=")
                || argument.hasPrefix("--work-tree=")
                || argument.hasPrefix("--namespace=")
                || argument.hasPrefix("--config-env=")
                || argument.hasPrefix("--super-prefix=") {
                index += 1
                continue
            }
            index += 1
        }
        return nil
    }

    private static let gitGlobalOptionsWithSeparateValues: Set<String> = [
        "-C", "-c", "--git-dir", "--work-tree", "--namespace",
        "--config-env", "--super-prefix",
    ]

    private static func isGitInteractivePatchFlag(_ argument: String) -> Bool {
        argument == "-p"
            || argument == "-i"
            || argument == "--patch"
            || argument == "--interactive"
    }

    private static func isGitCommitMessageFlag(_ argument: String) -> Bool {
        argument == "-m"
            || argument.hasPrefix("-m")
            || (!argument.hasPrefix("--")
                && argument.hasPrefix("-")
                && argument.dropFirst().contains("m"))
            || argument == "--message"
            || argument.hasPrefix("--message=")
            || argument == "-F"
            || argument.hasPrefix("-F")
            || argument == "--file"
            || argument.hasPrefix("--file=")
            || argument == "-C"
            || argument.hasPrefix("-C")
            || argument == "--reuse-message"
            || argument.hasPrefix("--reuse-message=")
            || argument == "-c"
            || argument.hasPrefix("-c")
            || argument == "--reedit-message"
            || argument.hasPrefix("--reedit-message=")
            || argument == "--template"
            || argument.hasPrefix("--template=")
            || argument == "--no-edit"
    }

    private static func isInteractiveContainerInvocation(
        _ args: [String],
        subcommands: Set<String>
    ) -> Bool {
        guard let subcommandIndex = args.firstIndex(where: {
            subcommands.contains($0.lowercased())
        }) else {
            return false
        }
        for argument in args.dropFirst(subcommandIndex + 1) {
            if argument == "--" { break }
            if argument == "-i"
                || argument == "-t"
                || argument == "--interactive"
                || argument.hasPrefix("--interactive=")
                || argument == "--tty"
                || argument.hasPrefix("--tty=") {
                return true
            }
            if argument.hasPrefix("-")
                && !argument.hasPrefix("--")
                && argument.dropFirst().contains(where: { $0 == "i" || $0 == "t" }) {
                return true
            }
        }
        return false
    }

    private static func isInteractiveNpmInit(_ args: [String]) -> Bool {
        guard let initIndex = args.firstIndex(where: { $0.lowercased() == "init" }) else {
            return false
        }
        let initArgs = args.dropFirst(initIndex + 1)
        return !initArgs.contains {
            $0 == "-y" || $0 == "--yes" || $0.hasPrefix("--yes=")
        }
    }

    private static let shellLaunchers: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    private static func isShellLauncher(_ command: String) -> Bool {
        shellLaunchers.contains(commandBasename(command).lowercased())
    }

    /// Extract `-c` payloads including combined login flags (`-lc`).
    private static func shellCommandPayload(_ args: [String]) -> String? {
        for index in args.indices {
            let argument = args[index]
            guard argument == "-c"
                    || (argument.hasPrefix("-")
                        && !argument.hasPrefix("--")
                        && argument.dropFirst().contains("c")) else {
                continue
            }
            let next = args.index(after: index)
            guard next < args.endIndex else { return nil }
            return args[next]
        }
        return nil
    }

    /// A bare shell (or one explicitly requesting `-i`) owns a terminal session;
    /// capturing it behind a wrapper would remove TTY/job-control semantics.
    /// Script files and `-s` remain eligible finite command invocations.
    private static func shellInvocationIsInteractive(_ args: [String]) -> Bool {
        if args.contains(where: { argument in
            argument == "-i"
                || (argument.hasPrefix("-")
                    && !argument.hasPrefix("--")
                    && argument.dropFirst().contains("i"))
                || argument == "--interactive"
        }) {
            return true
        }
        guard shellCommandPayload(args) == nil else { return false }
        guard !args.contains("-s") else { return false }
        var positional = false
        var optionsEnded = false
        for argument in args {
            if argument == "--" {
                optionsEnded = true
                continue
            }
            if !optionsEnded && argument.hasPrefix("-") { continue }
            positional = true
            break
        }
        return !positional
    }

    private static func shellPayloadContainsDistill(_ payload: String) -> Bool {
        shellSimpleCommandTokens(payload).contains { tokens in
            guard let invocation = shellInvocation(tokens) else { return false }
            return invocationRunsDistill(command: invocation.command, args: invocation.args)
        }
    }

    private static func invocationRunsDistill(command: String, args: [String]) -> Bool {
        let name = commandBasename(command).lowercased()
        if name == "distill" { return true }
        if name == "command", commandQueriesResolution(args) { return false }
        guard let childArguments = forwardedChildArguments(command: name, args: args),
              let child = childArguments.first else {
            return false
        }
        return invocationRunsDistill(
            command: child,
            args: Array(childArguments.dropFirst())
        )
    }

    /// Classify every simple command in a shell `-c` payload. The lexer only
    /// treats separators outside quotes as command boundaries, so a literal
    /// `"rg; example"` cannot accidentally change output ownership. This is
    /// intentionally a small ownership lexer, not a shell interpreter: if a
    /// shape is ambiguous it remains ordinary and the outer wrapper's existing
    /// fail-open path handles it without changing bytes.
    public static func shellOutputClassification(_ payload: String) -> ShellOutputClassification {
        let commands = shellSimpleCommandTokens(payload)
        var sawExact = false
        var sawOrdinary = false
        for tokens in commands {
            guard let invocation = shellInvocation(tokens) else { continue }
            let exact = invocationLooksExactOutput(
                command: invocation.command,
                args: invocation.args
            )
            if exact {
                sawExact = true
            } else {
                sawOrdinary = true
            }
            if sawExact && sawOrdinary { return .mixed }
        }
        if sawExact { return .exactOnly }
        return .ordinaryOnly
    }

    /// Split only an unambiguous sequence of simple commands separated by
    /// semicolons. The returned source is still interpreted by the real shell,
    /// but each segment has one output owner: exact segments pass through and
    /// ordinary segments may be distilled independently. Anything with shell
    /// control, redirection, substitution, comments, or an uncertain quoting
    /// shape returns nil so the original shell command runs wholly raw.
    public static func boundedSemicolonSegments(_ payload: String) -> [BoundedShellSegment]? {
        guard !payload.isEmpty, payload.utf8.count <= 16 * 1024 else { return nil }

        var rawSegments: [String] = []
        var segment = ""
        var quote: Character?
        var escaped = false

        func appendSegment() -> Bool {
            let value = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return false }
            rawSegments.append(value)
            segment.removeAll(keepingCapacity: true)
            return rawSegments.count <= 16
        }

        var index = payload.startIndex
        while index < payload.endIndex {
            let character = payload[index]
            let next = payload.index(after: index)

            if escaped {
                segment.append(character)
                escaped = false
                index = next
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"" && character == "\\" {
                    escaped = true
                } else if activeQuote == "\"" && (character == "$" || character == "`") {
                    return nil
                }
                segment.append(character)
                index = next
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                segment.append(character)
                index = next
                continue
            }
            if character == ";" {
                guard appendSegment() else { return nil }
                index = next
                continue
            }
            if character == "\\" {
                // Backslash-newline and escaped metacharacters are valid shell,
                // but interpreting their boundaries here would duplicate zsh.
                return nil
            }
            if character.isNewline
                || character == "|" || character == "&"
                || character == "<" || character == ">"
                || character == "(" || character == ")"
                || character == "`" || character == "$"
                || character == "#" || character == "{" || character == "}" {
                return nil
            }
            segment.append(character)
            index = next
        }
        guard quote == nil, !escaped, appendSegment(), rawSegments.count >= 2 else { return nil }

        var result: [BoundedShellSegment] = []
        for source in rawSegments {
            let tokenGroups = shellSimpleCommandTokens(source)
            guard tokenGroups.count == 1,
                  let tokens = tokenGroups.first,
                  let invocation = shellInvocation(tokens),
                  !shellControlWords.contains(invocation.command.lowercased()),
                  !shellStatefulBuiltins.contains(invocation.command.lowercased()),
                  !isShellAssignment(invocation.command) else {
                return nil
            }
            result.append(BoundedShellSegment(
                source: source,
                preservesExactOutput: invocationLooksExactOutput(
                    command: invocation.command,
                    args: invocation.args
                )
            ))
        }
        guard result.contains(where: \.preservesExactOutput),
              result.contains(where: { !$0.preservesExactOutput }) else {
            return nil
        }
        return result
    }

    private struct ShellInvocation {
        let command: String
        let args: [String]
    }

    private static let shellControlWords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until",
        "do", "done", "case", "esac", "in", "function", "!"
    ]

    /// Builtins whose effect belongs to the current shell process. Splitting
    /// around one would change the meaning of following segments.
    private static let shellStatefulBuiltins: Set<String> = [
        ".", "source", "cd", "chdir", "pushd", "popd", "dirs",
        "export", "unset", "set", "setopt", "unsetopt", "emulate",
        "alias", "unalias", "autoload", "functions", "typeset", "local",
        "readonly", "umask", "trap", "exec", "exit", "return", "shift",
        "eval", "read", "bindkey", "zmodload"
    ]

    /// Return command words after shell assignments and control words. A
    /// forwarding invocation (`env`, `time`, `xargs`, `command`) is left intact
    /// so `invocationLooksExactOutput` can recurse through its argv contract.
    private static func shellInvocation(_ tokens: [String]) -> ShellInvocation? {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if isShellAssignment(token) || token == "{" || token == "}" {
                index += 1
                continue
            }
            if shellControlWords.contains(token.lowercased()) {
                index += 1
                continue
            }
            return ShellInvocation(
                command: token,
                args: Array(tokens.dropFirst(index + 1))
            )
        }
        return nil
    }

    private static func isShellAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[..<equals]
        guard let first = name.first,
              first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Shell word lexer used only for command ownership. Quotes and escaped
    /// separators stay inside their word; separators outside quotes terminate
    /// the current simple command. Redirections are arguments, not boundaries.
    private static func shellSimpleCommandTokens(_ payload: String) -> [[String]] {
        var commands: [[String]] = []
        var current: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var comment = false

        func flushWord() {
            guard !word.isEmpty else { return }
            current.append(word)
            word.removeAll(keepingCapacity: true)
        }

        func flushCommand() {
            flushWord()
            if !current.isEmpty { commands.append(current) }
            current.removeAll(keepingCapacity: true)
        }

        var iterator = payload.makeIterator()
        while let character = iterator.next() {
            if comment {
                if character.isNewline {
                    comment = false
                    flushCommand()
                }
                continue
            }
            if escaped {
                word.append(character)
                escaped = false
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"" && character == "\\" {
                    escaped = true
                } else {
                    word.append(character)
                }
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character == "#" && word.isEmpty {
                comment = true
                continue
            }
            if character.isWhitespace {
                if character.isNewline {
                    flushCommand()
                } else {
                    flushWord()
                }
                continue
            }
            if character == ";" || character == "|" || character == "&" {
                flushCommand()
                continue
            }
            if character == "(" || character == ")" {
                flushCommand()
                continue
            }
            word.append(character)
        }
        if escaped { word.append("\\") }
        flushCommand()
        return commands
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
        guard let subcommandIndex = firstGitSubcommandIndex(args) else { return false }
        let sub = args[subcommandIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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

    /// The single decision the wrapper makes once it has captured the real command's output.
    /// FAIL-CLOSED toward passthrough: compress only when the command is the terminal command
    /// feeding the agent and the output is valid UTF-8. Size is deliberately not a gate: every
    /// eligible command must execute Distill, whose own fail-open path may return the raw bytes.
    public static func decide(
        command: String,
        args: [String] = [],
        isTerminalToAgent: Bool,
        outputIsValidUTF8: Bool,
        byteCount: Int,
        lineCount: Int,
        environment: [String: String]
    ) -> WrapAction {
        if let reason = passthroughReason(command: command, args: args, environment: environment) {
            return .passthrough(reason: reason)
        }
        if !isTerminalToAgent { return .passthrough(reason: "not_terminal") }
        if !outputIsValidUTF8 { return .passthrough(reason: "binary_output") }
        return .compress
    }

    public static func shouldCompress(byteCount: Int, lineCount: Int, environment: [String: String]) -> Bool {
        byteCount > minBytes(environment: environment) || lineCount > minLines(environment: environment)
    }

    /// The same stable prompt used by an explicit `| distill` request. Exact-output commands
    /// bypass wrappers before this point; ordinary output remains byte-recoverable via its
    /// trailing handle if the model accepts a smaller representation.
    public static func extractionQuery(forCommand command: String) -> String? {
        "Summarize the key output and exit status"
    }

    // MARK: - faithfulness guard

    /// A command's whole output is being replaced, so a degenerate "compression" must never
    /// reach the agent. The distill model can answer as a question and return a tiny token
    /// (e.g. "NONE"/"PASS"); the deterministic router can't, but the model lane can. Reject any
    /// compressed result whose content (excluding the `[[rc:<handle>]]` recovery marker) is
    /// implausibly small for the captured output — the caller then emits the raw bytes instead.
    /// An absolute floor (not a ratio) so a legitimately huge win on
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

    /// Byte length of the compressed content with a trailing `[[rc:<handle>]]` marker line and
    /// surrounding whitespace removed, so the faithfulness floor measures real content — not the
    /// ~70-byte recovery handle that would otherwise let a "NONE" token slip past the floor.
    public static func compressedContentByteCount(_ emitted: String) -> Int {
        let ns = emitted as NSString
        let full = NSRange(location: 0, length: ns.length)
        let withoutHandle = trailingRecoveryHandleRegex.stringByReplacingMatches(
            in: emitted,
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
