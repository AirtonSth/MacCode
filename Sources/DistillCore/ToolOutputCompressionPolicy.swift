import Foundation
import CoreModel

public enum ToolCompressionProfile: String, Sendable, Equatable {
    case passthrough
    case conservative
    case moderate
    case aggressive

    public var allowsAbstractRewrite: Bool {
        self == .aggressive
    }

    public var allowsLinePruning: Bool {
        switch self {
        case .moderate, .aggressive:
            return true
        case .passthrough, .conservative:
            return false
        }
    }
}

public enum ToolCompressionSkipReason: String, Sendable, Equatable {
    case excludedTool = "excluded_tool"
    case notAllowlisted = "not_allowlisted"
    case belowThreshold = "below_threshold"
    case multimodalImage = "multimodal_image"
    /// Bash/shell tool whose `command` is exact-output (rg/sed/cat/…) or exact git blob/match.
    case exactOutputShell = "exact_output_shell"
}

public struct ToolCompressionDecision: Sendable, Equatable {
    public let toolName: String
    public let profile: ToolCompressionProfile
    public let shouldCompress: Bool
    public let skipReason: ToolCompressionSkipReason?
    public let mode: DistillMode
    public let cacheState: String
    public let minBytes: Int
    public let minLines: Int
    public let reversibleStoreMinBytes: Int
    public let allowsAbstractRewrite: Bool
    public let allowsLinePruning: Bool
    public let contractQuestion: String
}

public struct ToolOutputCompressionPolicy: Sendable, Equatable {
    /// Mutation tools must stay raw so the model never plans edits from a lossy view.
    /// Large `Read` is allowlisted (skeleton/BERT path) — not excluded.
    public static let defaultExcludedTools: Set<String> = [
        "Edit",
        "Write",
        "MultiEdit",
        "NotebookEdit"
    ]

    /// PERF: pre-normalized membership set so every tool-output decision does an
    /// O(1) `Set.contains` instead of mapping/normalizing the whole exclude list.
    private static let normalizedExcludedTools: Set<String> = Set(
        defaultExcludedTools.map(Self.normalizeToolName)
    )

    public static let defaultAllowlistedTools: Set<String> = [
        "Bash",
        "Grep",
        "Glob",
        "WebFetch",
        "Read"
    ]

    public let minBytes: Int
    public let minLines: Int
    public let reversibleStoreMinBytes: Int

    public init(minBytes: Int = 2_048, minLines: Int = 30, reversibleStoreMinBytes: Int = 2_048) {
        self.minBytes = max(1, minBytes)
        self.minLines = max(1, minLines)
        self.reversibleStoreMinBytes = max(1, reversibleStoreMinBytes)
    }

    public func decision(
        toolName: String,
        output: String,
        toolArgumentsSummary: String? = nil,
        taskSummary: String? = nil,
        bindingDigest: String? = nil,
        resultScopeDigest: String? = nil
    ) -> ToolCompressionDecision {
        // Wave A shadow instrumentation (task-12): content-free scorecard; requires BindingID.
        TokenSaverWaveAShadowBridge.failOpenObserve {
            TokenSaverWaveAShadowBridge.observeToolOutput(
                toolName: toolName, output: output, bindingDigest: bindingDigest
            )
            // Wave B typed crushers (task-15) + recovery (task-16) probes (default OFF).
            TokenSaverTypedCrushersBridge.observeToolOutput(
                toolName: toolName,
                output: output,
                bindingDigest: bindingDigest,
                resultScopeDigest: resultScopeDigest
            )
        }
        let profile = profile(for: toolName)
        let skipReason: ToolCompressionSkipReason?
        if isExcluded(toolName) {
            skipReason = .excludedTool
        } else if ToolOutputMultimodalGuard.looksLikeImagePayload(output) {
            // Text Distill cannot safely rewrite image/base64 tool payloads.
            skipReason = .multimodalImage
        } else if isExactOutputShellTool(toolName: toolName, toolArgumentsSummary: toolArgumentsSummary) {
            // Align with CommandWrapPolicy / Claude SDK bridge: never rewrite exact stdout.
            skipReason = .exactOutputShell
        } else if !meetsSizeThreshold(output) {
            skipReason = .belowThreshold
        } else {
            // Default: compress allowlisted + other non-excluded tools (Task, MCP, …)
            // with extractive contracts. Mutation tools already excluded above.
            skipReason = nil
        }

        return ToolCompressionDecision(
            toolName: toolName,
            profile: profile,
            shouldCompress: skipReason == nil,
            skipReason: skipReason,
            mode: .commandOutput,
            cacheState: "tool_output_hooked",
            minBytes: minBytes,
            minLines: minLines,
            reversibleStoreMinBytes: reversibleStoreMinBytes,
            allowsAbstractRewrite: profile.allowsAbstractRewrite,
            allowsLinePruning: profile.allowsLinePruning,
            contractQuestion: contractQuestion(
                toolName: toolName,
                profile: profile,
                toolArgumentsSummary: toolArgumentsSummary,
                taskSummary: taskSummary
            )
        )
    }

    public func profile(for toolName: String) -> ToolCompressionProfile {
        switch normalize(toolName) {
        case "grep", "glob":
            return .conservative
        case "bash", "read", "readfile", "listdir", "runterminalcommand", "shell", "terminal", "localshell":
            // Read / Grok read_file / Grok list_dir: extractive keep (skeleton/BERT);
            // Bash/Grok/Codex shell: noise collapse.
            return .moderate
        case "webfetch":
            return .aggressive
        default:
            // Non-mutation tools default to extractive moderate compression (Task/MCP/etc.).
            // Exclusions still block Edit/Write. Unknown names are not silent no-ops.
            return .moderate
        }
    }

    public func isExcluded(_ toolName: String) -> Bool {
        Self.normalizedExcludedTools.contains(normalize(toolName))
    }

    public func meetsSizeThreshold(_ output: String) -> Bool {
        // Short-circuit on bytes first so multi-MB dumps never scan for lines.
        if output.utf8.count > minBytes { return true }
        return lineComponentCountExceeds(output, minLines)
    }

    private func contractQuestion(
        toolName: String,
        profile: ToolCompressionProfile,
        toolArgumentsSummary: String?,
        taskSummary: String?
    ) -> String {
        let context = [taskSummary, toolArgumentsSummary]
            .compactMap { value -> String? in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            .joined(separator: " | ")
        let suffix = context.isEmpty ? "" : " Context: \(context)."
        switch profile {
        case .conservative:
            return "Compress search output without dropping any match line. Preserve paths, line numbers, matched text, and quoted strings verbatim; only collapse duplicate/context noise. \(DistillPrompt.densityMarker) if every match line still fits.\(suffix)"
        case .moderate:
            if normalize(toolName) == "read" || normalize(toolName) == "readfile" {
                return "Compress file read output for the current task. Prefer signatures, exports, types, and task-relevant spans; elide large bodies only when a retrieve handle covers the original; preserve paths, line numbers, identifiers, and quoted strings verbatim. \(DistillPrompt.densityMarker) if those literals still fit.\(suffix)"
            }
            return "Compress command output. Preserve exit codes, failing test names, errors, warnings, assertions, numbers, paths, and quoted strings verbatim; collapse repeated progress noise. \(DistillPrompt.densityMarker) if those literals still fit.\(suffix)"
        case .aggressive:
            return "Compress fetched web content for the current task. Preserve URLs, titles, code, API signatures, numbers, and quoted strings verbatim; keep retrieve-worthy details explicit. \(DistillPrompt.densityMarker) if those literals still fit.\(suffix)"
        case .passthrough:
            return "Pass through tool output unchanged.\(suffix)"
        }
    }

    /// True when `split(separator: "\n", omittingEmptySubsequences: false).count > threshold`.
    ///
    /// PERF: UTF-8 LF scan with early exit — no `Array` of `Substring` for medium
    /// tool dumps that already failed the byte gate. Component count is
    /// `newlineCount + 1` for this split form.
    private func lineComponentCountExceeds(_ output: String, _ threshold: Int) -> Bool {
        // components > threshold ⇔ newlines >= threshold
        guard threshold > 0 else { return true }
        var newlines = 0
        for byte in output.utf8 where byte == 0x0A {
            newlines += 1
            if newlines >= threshold { return true }
        }
        return false
    }

    private func normalize(_ toolName: String) -> String {
        Self.normalizeToolName(toolName)
    }

    private static func normalizeToolName(_ toolName: String) -> String {
        toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }

    /// Normalized names of provider shell tools whose `command=` is a user shell line.
    /// Includes Grok `run_terminal_command` and Codex `local_shell` so exact-output
    /// skip / last-pipe distill admit apply uniformly (hooks still cannot rewrite
    /// Codex/Grok output; this gates policy + wrap-adjacent decisions).
    public static let shellLikeNormalizedToolNames: Set<String> = [
        "bash", "shell", "terminal", "runterminalcommand", "localshell",
    ]

    /// True when this is a shell tool whose command string is exact-output family
    /// (rg/grep/sed/cat/…, git grep|show|cat-file|blame). Summary may be
    /// `command=rg -n foo` (hook args) or a raw shell line.
    ///
    /// Voluntary `rg … | distill "<question>"` is **not** exact-output: the last
    /// pipeline command is distill. Raw `rg` without that last stage still skips.
    public func isExactOutputShellTool(toolName: String, toolArgumentsSummary: String?) -> Bool {
        let name = normalize(toolName)
        guard Self.shellLikeNormalizedToolNames.contains(name) else { return false }
        guard let summary = toolArgumentsSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return false
        }
        return Self.shellCommandLooksExactOutput(Self.commandField(from: summary))
    }

    /// Pull `command=` from a `summarizeToolInput` line without treating a shell
    /// pipe (`rg | distill`) as the field separator (` | path=` / ` | pattern=`).
    public static func commandField(from summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "command=") else { return trimmed }
        let rest = String(trimmed[range.upperBound...])
        var end = rest.endIndex
        for key in ["pattern", "path", "glob", "url"] {
            let marker = " | \(key)="
            if let hit = rest.range(of: marker), hit.lowerBound < end {
                end = hit.lowerBound
            }
        }
        return String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // PERF: shellCommandLooksExactOutput runs on every bash/shell compress
    // decision and allocated CharacterSet(charactersIn: "|&;\n") per call.
    private static let shellSegmentSeparators = CharacterSet(charactersIn: "|&;\n")

    private static func isShellAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else {
            return false
        }
        let name = token[..<equals]
        guard let first = name.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first) else {
            return false
        }
        return name.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func unquotedShellToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    /// Minimal shell lexer for prefix inspection. It preserves whitespace inside
    /// quotes and removes quoting/escapes without evaluating expansions.
    private static func shellWords(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasToken = false
        for character in input {
            if escaping {
                current.append(character)
                escaping = false
                hasToken = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    hasToken = true
                } else if activeQuote == "\"", character == "\\" {
                    escaping = true
                } else {
                    current.append(character)
                    hasToken = true
                }
                continue
            }
            if character.isWhitespace {
                if hasToken {
                    words.append(current)
                    current = ""
                    hasToken = false
                }
            } else if character == "'" || character == "\"" {
                quote = character
                hasToken = true
            } else if character == "\\" {
                escaping = true
                hasToken = true
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if escaping { current.append("\\") }
        if hasToken { words.append(current) }
        return words
    }

    private static func strippingShellPrefixes(_ input: [String]) -> [String] {
        var tokens = input
        var changed = true
        while changed, !tokens.isEmpty {
            changed = false
            let head = (tokens[0] as NSString).lastPathComponent.lowercased()
            if head == "env" {
                tokens.removeFirst()
                while let token = tokens.first {
                    let option = unquotedShellToken(token)
                    if option == "--" {
                        tokens.removeFirst()
                        break
                    } else if option == "-S" {
                        tokens.removeFirst()
                        if !tokens.isEmpty {
                            let splitString = tokens.removeFirst()
                            tokens.insert(contentsOf: shellWords(splitString), at: 0)
                        }
                    } else if option == "-u" || option == "--unset"
                        || option == "-C" || option == "-P"
                        || option == "--chdir" || option == "--path" {
                        tokens.removeFirst()
                        if !tokens.isEmpty { tokens.removeFirst() }
                    } else if option == "-i" || option == "-0" || option == "-v"
                        || option == "--ignore-environment"
                        || (option.count > 1 && option.first == "-"
                            && option.dropFirst().allSatisfy { $0 == "0" || $0 == "i" || $0 == "v" })
                        || option.hasPrefix("-u")
                        || (option.hasPrefix("-C") && option.count > 2)
                        || (option.hasPrefix("-P") && option.count > 2) {
                        tokens.removeFirst()
                    } else if isShellAssignment(option) {
                        tokens.removeFirst()
                    } else {
                        break
                    }
                }
                changed = true
            } else if head == "command" || head == "builtin" || head == "exec" {
                tokens.removeFirst()
                while tokens.first?.hasPrefix("-") == true {
                    let option = tokens.removeFirst()
                    if option == "--" { break }
                    if head == "exec", option == "-a", !tokens.isEmpty {
                        tokens.removeFirst()
                    }
                }
                changed = true
            } else if isShellAssignment(tokens[0]) {
                tokens.removeFirst()
                changed = true
            }
        }
        return tokens
    }

    private static func gitSubcommand(in arguments: [String]) -> String? {
        let valueOptions: Set<String> = [
            "-C", "-c", "--git-dir", "--work-tree", "--namespace",
            "--config-env", "--super-prefix",
        ]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valueOptions.contains(argument) {
                index += 2
                continue
            }
            if argument.hasPrefix("--git-dir=")
                || argument.hasPrefix("--work-tree=")
                || argument.hasPrefix("--namespace=")
                || (argument.hasPrefix("-c") && argument.count > 2) {
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            return argument.lowercased()
        }
        return nil
    }

    /// Last `|` stage of a shell line (quote-aware). Nil when `command` is empty.
    public static func lastPipelineSegment(_ command: String) -> String? {
        pipeSegments(command).last
    }

    /// Last `&&` / `||` / `;` command inside the last `|` stage.
    /// `cd foo && git status` → `git status`. `swift test | head` → `head`.
    public static func lastChainSegment(_ command: String) -> String {
        let lastPipe = lastPipelineSegment(command) ?? command
        return chainSegments(lastPipe).last ?? lastPipe
    }

    /// Basename + args of the last chain command after stripping `env` / assignments.
    public static func lastInvocation(_ command: String) -> (name: String, args: [String])? {
        let tokens = strippingShellPrefixes(shellWords(lastChainSegment(command)))
        guard let primaryRaw = tokens.first else { return nil }
        let name = (unquotedShellToken(primaryRaw) as NSString).lastPathComponent.lowercased()
        let args = tokens.dropFirst().map { unquotedShellToken($0) }
        return (name, Array(args))
    }

    /// True when the last `|` stage (quote-aware) is the managed `distill` CLI.
    /// Raw exact-output tools stay skipped; a voluntary pipe to distill is admitted.
    public static func lastPipelineCommandIsVoluntaryDistill(_ command: String) -> Bool {
        lastInvocation(command)?.name == "distill" && pipeSegments(command).count >= 2
    }

    /// Quote-aware split on `|` only (not `&&` / `;`). Used to detect last-pipe distill.
    private static func pipeSegments(_ input: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for character in input {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", character == "\\" {
                    escaping = true
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
            } else if character == "\\" {
                escaping = true
                current.append(character)
            } else if character == "|" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { segments.append(trimmed) }
                current = ""
            } else {
                current.append(character)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { segments.append(trimmed) }
        return segments
    }

    /// Quote-aware split on `&&` / `||` / `;` (not `|`).
    private static func chainSegments(_ input: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        let characters = Array(input)
        var index = 0
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(trimmed) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            if escaping {
                current.append(character)
                escaping = false
                index += 1
                continue
            }
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", character == "\\" {
                    escaping = true
                }
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
                index += 1
                continue
            }
            if character == "\\" {
                escaping = true
                current.append(character)
                index += 1
                continue
            }
            if character == ";" {
                flush()
                index += 1
                continue
            }
            if character == "&", index + 1 < characters.count, characters[index + 1] == "&" {
                flush()
                index += 2
                continue
            }
            if character == "|", index + 1 < characters.count, characters[index + 1] == "|" {
                flush()
                index += 2
                continue
            }
            current.append(character)
            index += 1
        }
        flush()
        return segments
    }

    /// Segment-aware check shared with wrapper intent: pipes/and chains may mix tools.
    /// Last-pipeline `distill` wins: do not treat `rg … | distill "q"` as exact-output.
    public static func shellCommandLooksExactOutput(_ command: String) -> Bool {
        if lastPipelineCommandIsVoluntaryDistill(command) {
            return false
        }
        let segments = command
            .components(separatedBy: shellSegmentSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for segment in segments {
            let rawTokens = shellWords(segment)
            let tokens = strippingShellPrefixes(rawTokens)
            guard let primaryRaw = tokens.first else { continue }
            let primary = (unquotedShellToken(primaryRaw) as NSString).lastPathComponent.lowercased()
            if WrappedCommandCatalog.isExactOutputCommand(primary) {
                return true
            }
            if primary == "git", let subcommand = gitSubcommand(in: Array(tokens.dropFirst())) {
                if CommandWrapPolicy.isExactGitSubcommand([subcommand]) {
                    return true
                }
            }
        }
        return false
    }
}
