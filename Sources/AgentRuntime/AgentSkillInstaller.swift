import CryptoKit
import Foundation
import CoreModel

public struct AgentSkillManifest: Codable, Sendable, Equatable {
    public let provider: AgentProvider
    public let skillID: String
    public let sourceURL: String
    public let sourceRevision: String
    public let localVersion: String
    public let sha256: String
    public let installPath: String
    public let installedAt: Date

    public init(
        provider: AgentProvider,
        skillID: String,
        sourceURL: String,
        sourceRevision: String,
        localVersion: String,
        sha256: String,
        installPath: String,
        installedAt: Date
    ) {
        self.provider = provider
        self.skillID = skillID
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.localVersion = localVersion
        self.sha256 = sha256
        self.installPath = installPath
        self.installedAt = installedAt
    }
}

public struct AgentSkillInstallResult: Sendable, Equatable {
    public enum Action: String, Sendable {
        case installed
        case skipped
    }

    public let action: Action
    public let manifest: AgentSkillManifest
}

public enum AgentSkillUninstallResult: String, Sendable, Equatable {
    case removed
    case notPresent
}

public struct RemoteCodeOrchestrateFile: Codable, Sendable, Equatable {
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String

    public init(relativePath: String, byteCount: Int, sha256: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct RemoteCodeOrchestratePackage: Sendable, Equatable {
    public let skillID: String
    public let sourceURL: String
    public let sourceRevision: String
    public let sourceTreeSHA256: String
    public let localVersion: String
    public let allowedPaths: [String]

    public init(
        skillID: String,
        sourceURL: String,
        sourceRevision: String,
        sourceTreeSHA256: String,
        localVersion: String,
        allowedPaths: [String]
    ) {
        self.skillID = skillID
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.sourceTreeSHA256 = sourceTreeSHA256
        self.localVersion = localVersion
        self.allowedPaths = allowedPaths.sorted()
    }
}

public struct RemoteCodeOrchestrateManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let managedBy: String
    public let skillID: String
    public let sourceURL: String
    public let sourceRevision: String
    public let sourceTreeSHA256: String
    public let localVersion: String
    public let installPath: String
    public let installedAt: Date
    public let files: [RemoteCodeOrchestrateFile]
}

public struct RemoteCodeOrchestrateInstallResult: Sendable, Equatable {
    public enum Action: String, Sendable {
        case installed
        case skipped
        case updated
        case repaired
    }

    public let action: Action
    public let manifest: RemoteCodeOrchestrateManifest
}

public struct RemoteCodeOrchestrateStatus: Sendable, Equatable {
    public enum State: String, Sendable {
        case notInstalled
        case ready
        case updateRequired
        case repairRequired
        case unmanagedCollision
    }

    public let state: State
    public let manifest: RemoteCodeOrchestrateManifest?
    public let lastKnownGoodAvailable: Bool
    public let repairReason: String?
}

public enum RemoteCodeOrchestrateInstallError: Error, Sendable, Equatable {
    case sourceMissing(String)
    case unsafeRelativePath(String)
    case symbolicLink(String)
    case unexpectedEntry(String)
    case missingRequiredFile(String)
    case sourceTreeDigestMismatch(expected: String, actual: String)
    case unmanagedCollision(String)
    case invalidManagedPackage(String)
    case lastKnownGoodUnavailable
}

/// Always-on parent identity for the provider-neutral `subagent begin` bridge.
/// This is lifecycle scope only: resolving it must not depend on Token Saver
/// admission or enable any paid lane.
public struct RemoteCodeSubagentTelemetryScope: Sendable, Equatable {
    public let threadId: AgentThreadID
    public let parentRunId: AgentRunID?
    public let parentThreadId: AgentThreadID?
    public let parentCapability: String?

    public init?(environment: [String: String]) {
        guard let threadUUID = UUID(
            uuidString: environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"]
                ?? environment["RC_TOKEN_SAVER_THREAD_ID"]
                ?? ""
        ) else {
            return nil
        }
        let threadId = AgentThreadID(threadUUID)
        let parentRunId = UUID(
            uuidString: environment["RC_REMOTE_CODE_ROOT_RUN_ID"]
                ?? environment["RC_TOKEN_SAVER_ROOT_RUN_ID"]
                ?? environment["RC_TOKEN_SAVER_ATTEMPT_ID"]
                ?? ""
        ).map { AgentRunID($0) }

        self.threadId = threadId
        self.parentRunId = parentRunId
        self.parentThreadId = parentRunId == nil ? nil : threadId
        self.parentCapability = environment[
            AgentDelegationCapabilityTransport.environmentKey
        ].flatMap {
            AgentDelegationCapabilityTransport.isWellFormed($0) ? $0 : nil
        }
    }
}

public final class AgentSkillInstaller: @unchecked Sendable {
    public static let toolShellProtocolVersion = "1"
    public static let toolShellProtocolEnvironmentKey =
        "RC_TOKEN_SAVER_TOOL_SHELL_PROTOCOL"
    public static let toolShellBinaryEnvironmentKey =
        "RC_TOKEN_SAVER_TOOL_SHELL_BINARY"
    public static let runtimeRootEnvironmentKey =
        "RC_REMOTE_CODE_RUNTIME_ROOT"
    public static let toolShellCurrentDoneEnvironmentKey =
        "RC_REMOTE_CODE_TOOL_SHELL_DONE"
    public static let toolShellLegacyDoneEnvironmentKey =
        "RC_TOKEN_SAVER_TOOL_SHELL_DONE"
    public static let distillSkillID = "distill"
    public static let distillSourceURL = "https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md"
    public static let distillLocalVersion = "9"
    public static let distillInstructionsBeginMarker = "<!-- distill skill: begin -->"
    public static let distillInstructionsEndMarker = "<!-- distill skill: end -->"
    public static let distillCLIBeginMarker = "# RemoteCode managed distill CLI: begin"
    public static let distillCLIEndMarker = "# RemoteCode managed distill CLI: end"
    public static let mcpBeginMarker = "# RemoteCode managed MCP: begin"
    public static let mcpEndMarker = "# RemoteCode managed MCP: end"
    public static let retrieveMCPName = "remotecode-distill-retrieve"
    public static let agentAppMiddlewareCommand = "remote-code"
    public static let remoteCodeOrchestrateManifestName = ".remote-code-install.json"
    public static let remoteCodeOrchestrateRuntimeManifestName = "manifest.json"
    public static let remoteCodeOrchestratePinnedPackage = RemoteCodeOrchestratePackage(
        skillID: "remote-code-orchestrate",
        sourceURL: "https://github.com/samuelfaj/sam-skills/tree/main/sam-orchestrate",
        // Upstream base revision; tree digest is recomputed from the embedded package
        // after local contract edits (skill content must stay complete / no Distill-in-skills).
        sourceRevision: "2c77fa48431bc20e5dc841652079594a3ea918c9",
        sourceTreeSHA256: "b5e06a22bf885038f9c339f5c6499671aab202d54fd7a41ac75c2007e296b75b",
        localVersion: "5",
        allowedPaths: [
            "SKILL.md",
            "agents/openai.yaml",
            "references/host-runtime-matrix.md",
            "references/output-contract.md",
            "references/prompt-contract.md",
            "references/routing-policy.md",
            "scripts/test_orchestration_harness.py",
            "scripts/validate_orchestration.py"
        ]
    )

    public static let distillSkillTemplate = """
    ---
    name: distill
    description: Conversation mode that makes the LLM speak in distill compressed language for the whole thread.
    source: https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md
    ---

    # Distill

    Use when RemoteCode invokes `/distill` or asks the provider to use Token Saver / Distill language.

    This is a conversation style mode, not a prompt-compression request.
    Do not return the user's prompt compressed as an artifact.
    Adopt canonical `@sr2 v1` Opaque Agent IR for every provider-authored text item (Claude/Codex/Grok), including reasoning, commentary/intermediate updates, and final replies. No free monologue — the host humanizes for the user. Never emit legacy `@sr2 v0` or SR1 S/C/D/R/O/N/P text. Tool stdout stays exact. Keep using v1 wire for the rest of the thread.

    Core behavior (sparse by default):
    - Begin every provider-authored text item with exactly `@sr2 v1`.
    - Use only the v1 fields documented by the host instruction; put each field on its own line and omit unused fields.
    - Tool-only continuation is `@sr2 v1` plus `o:cont`; long answers use the host's v1 answer-handle shape.
    - Keep exact paths, commands, IDs, errors, and proof anchors when useful.
    - No filler, markdown essays, or multi-paragraph prose on the wire.
    - Do not output a rewritten/compressed copy of the user's prompt unless explicitly asked to compress text.

    Command-output / exploration policy (Token Saver — Claude + Codex + Grok, primary + nested + subagents):
    - **Coverage first (mandatory for large surveys):** do **not** flood context with native multi-file `read_file` / `grep` / `list_dir` / tree walks. Order:
      1) When `$RC_GRAPHIFY_ENABLED=1` and `$RC_GRAPHIFY_GRAPH_JSON` is set → `graphify query|path|explain` first.
      2) Else / after graph → shell via `run_terminal_command` / Bash using PATH-wrapped tools (`git`, `bun`, `npm`, `find`, `ls`, tests, builds, …) and/or end with `| distill "<question>"`.
      3) Native file tools only for **small, targeted** slices you need byte-exactly (one file, known path, short range).
    - **Why:** Grok/Codex cannot rewrite native tool output (passive/no `updatedToolOutput`). Claude PostToolUse may compress some tools, but shell wrappers + `| distill` maximize measured savings on all three providers. Prefer shell+compress for noisy builds/tests/logs.
    - MANDATORY default-pipe: for **every** non-GUI pipable shell command whose full stdout you do **not** need byte-exactly next, end with `| distill "<question>"` (`pipefail` when exit status matters). If you only need summary / pass-fail / key lines, you MUST pipe.
      Applies to: build, test, lint, install, docker, kubectl, terraform, find, ls, git/gh/glab (including `gh api`, merges, status), package managers, python/bun one-shots, curl/aws/cloud CLIs, compound scripts, CI/logs, and **any other ordinary command** not listed under NEVER below.
      Host PATH wrappers auto-route **every discovered non-TUI, non-exact executable** through Distill when terminal-to-agent, regardless of output size — still pipe `| distill` yourself so extraction is explicit. Same policy for primary, nested subagents, and cross-provider orchestration (Claude/Codex/Grok).
    - NEVER batch exact-output and ordinary commands into one shell tool call or `sh`/`zsh -c` compound. Run exact probes as separate tool calls, then run the ordinary command separately with explicit `| distill`; host wrappers auto-cover bare calls only when their shell has validated aggregate ownership. Unowned mixed compounds intentionally fail open wholly raw.
    - NEVER pipe `| distill` only when you need the **exact** full stdout (or the tool is not a normal shell pipe target):
      search/match: rg, grep, egrep, fgrep, ag, ugrep, git grep
      line/stream edit or dump: sed, awk, cat, head, tail, nl, cut, tr, paste
      exact compare/bytes: diff, cmp, od, hexdump, xxd, base64
      structure extractors when parsing: jq, yq
      Also skip: GUI / interactive / TUI apps, non-pipable calls, patches/apply, hash/token copy, or RemoteCodeDistillService unavailable.
    - NEVER Distill skill content: Skill tool output and requested/returned SKILL.md bodies are a protected verbatim category — return them complete (no summary, recovery handle, truncation, or savings accounting).
    - Never call Node, tsx, npm, bun, or a source-checkout CLI for `distill`.
    - When you skip `| distill`, state that briefly (e.g. skip: exact sed/rg; skip: GUI; skip: skill). Omitting `| distill` on a non-exact, non-GUI shell command is a policy violation.
    - Applies to primary agents, same-provider subagents, and cross-provider nested launches (Claude↔Codex↔Grok) whenever Token Saver is admitted.
    - Host/runtime carries the ordinary-output Distill policy; do not require every worker prompt to restate it.
    - If a summary includes `[[rc:<handle>]]`, recover exact bytes with `distill retrieve <handle>`.
    - Wait for `distill` before continuing when you did pipe it.

    Examples:
    - `graphify query "where is mark-as-completed?" --graph "$RC_GRAPHIFY_GRAPH_JSON"`  # when Graphify active
    - `bun test 2>&1 | distill "Did tests pass? Return PASS or FAIL, followed by failing test names if any."`
    - `git log --oneline -50 | distill "Summarize recent commits by theme."`
    - `python3 script.py 2>&1 | distill "What failed? Key errors only."`
    - `rg -n "func applyGraphify" Sources`  # skip distill — need every match line
    - `sed -n '100,180p' Sources/Foo.swift`  # skip distill — need exact slice

    Source reference:
    - https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md
    """

    public static let distillAgentInstructionsTemplate = """
    <!-- distill skill: begin -->
    CRITICAL: Use canonical **@sr2 v1** Opaque Agent IR for every provider-authored text item (Claude/Codex/Grok): reasoning, commentary/intermediate updates, and final replies. No free monologue. Host humanizes for UI. Tool stdout stays exact. Never emit legacy @sr2 v0 or SR1 S/C/D/R/O/N/P text.\nCRITICAL: Keep v1 sparse: one field per line, omit unused fields, and use `o:cont` for tool-only continuation.
    Do not rewrite/compress the user's prompt unless explicitly asked.
    Token Saver — Claude/Codex/Grok (primary, nested, cross-provider): for large surveys use Graphify first when `$RC_GRAPHIFY_GRAPH_JSON` is set; otherwise use shell + PATH wrappers / `| distill`. Avoid native multi-file reads/searches; reserve them for small exact slices.
    MANDATORY default-pipe: for **every** non-TUI pipable shell command whose full stdout you do **not** need byte-exactly next, end with `| distill "<question>"` (`pipefail` when exit status matters). If you only need summary/pass-fail/key lines, you MUST pipe. Host PATH wrappers auto-route every discovered non-TUI, non-exact executable and eligible subcommand (including `gh api`); still pipe yourself for an explicit extraction question. Applies primary + nested + cross-provider (Claude/Codex/Grok) whenever Token Saver is admitted. The UI preserves the complete original command for expand/copy.
    Mixed exact+ordinary shell: separate tool calls. In SR2, `run:[a;b]>[c]` means each bracket is one separate ordered shell tool call; never flatten groups. Exact raw; ordinary group uses explicit `| distill`; wrapper only with owned shell; unowned mix fails open raw.
    NEVER pipe `| distill` only for exact-output (agent needs full stdout): rg, grep, egrep, fgrep, sed, awk, cat, head, tail, nl, cut, tr, diff, jq, yq, git grep/show/cat-file/blame; also patches/hashes/tokens, GUI/interactive/TUI, non-pipable, or service unavailable — state the skip briefly.
    Omitting `| distill` on a non-exact, non-GUI shell command is a policy violation.
    NEVER Distill skill content: Skill tool output and requested/returned SKILL bodies must stay complete/verbatim (no summary, `[[rc:]]` handle, truncation, or savings accounting).
    Never invoke Node/tsx/npm/bun or a source-checkout `distill`.
    Host/runtime carries the ordinary-output Distill policy; do not require every worker prompt to restate it.
    If a summary includes `[[rc:<handle>]]`, recover exact bytes with `distill retrieve <handle>`. Wait for `distill` before continuing when used.
    Details and examples live in the managed `distill` SKILL.md.
    <!-- distill skill: end -->
    """

    /// The distill agent instructions with the begin/end HTML markers stripped. The markers
    /// only matter for the in-place upsert/removal inside CLAUDE.md/AGENTS.md; this marker-free
    /// body is what gets injected as an authoritative system prompt (Claude SDK bridge), where
    /// the surrounding CLAUDE.md is easily buried. The runtime adapter appends the safety ABI
    /// separately so mutable on-disk instructions cannot duplicate that contract.
    public static var distillAgentInstructionsBody: String {
        distillAgentInstructionsTemplate
            .replacingOccurrences(of: distillInstructionsBeginMarker, with: "")
            .replacingOccurrences(of: distillInstructionsEndMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inject managed Distill into provider runtime prompts (Claude / Codex / Grok)
    /// only while Token Saver is active (`RC_TOKEN_SAVER_DISTILL_HINT=1`).
    /// Token economy is the paid feature: no Distill dialect, `| distill` rules,
    /// or safety ABI when the toggle is off.
    public static func tokenSaverProviderPrompt(_ base: String, environment: [String: String]) -> String {
        let routed = nestedAgentProviderPrompt(base, environment: environment)
        let withDistill: String
        if environment["RC_TOKEN_SAVER_DISTILL_HINT"] == "1" {
            withDistill = managedDistillProviderPrompt(routed)
        } else {
            withDistill = routed
        }
        return graphifyProviderPrompt(withDistill, environment: environment)
    }

    /// Always-on host routing for provider-to-provider delegation. This is
    /// lifecycle plumbing, not a Token Saver lane, so it remains present when
    /// the paid toggle is off. Explicit skill CLIs keep their exact ABI and are
    /// intercepted by provider proxies instead of being silently rewritten.
    public static func nestedAgentProviderPrompt(
        _ base: String,
        environment: [String: String]
    ) -> String {
        guard environment["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"] == "1",
              let command = environment["RC_REMOTE_CODE_AGENT_APP_COMMAND"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return base
        }
        let block = """
        REMOTE_CODE_SUBAGENT_ROUTING_V1
        When delegating a normal task to another Codex, Claude, or Grok agent, launch it through:
        \(command) agent-app <codex|claude|grok> --prompt-file <absolute-path>
        This keeps the child in RemoteCode's Agent App lifecycle, persistence, usage, and active Subagents UI.
        Preserve an explicit skill's provider CLI ABI when it carries stricter sandbox, tool, memory, session, or no-subagent flags; the RemoteCode provider proxy will observe that exact launch.
        Never bypass the launcher with an absolute provider binary for ordinary delegation.
        """
        if base.contains("REMOTE_CODE_SUBAGENT_ROUTING_V1") { return base }
        return base.isEmpty ? block : base + "\n\n" + block
    }

    /// Add host runtime guidance to an exact raw provider CLI invocation without
    /// changing its prompt transport, sandbox, tools, persistence, or output ABI.
    ///
    /// Nested `claude` / `codex` / `grok` launches go through this seam (via
    /// `ProviderProxyRunner.providerRuntimeArguments`). For Claude, Agent App
    /// runs already register PostToolUse via `ClaudeRunner.ultracodeSettingsArgs`.
    /// The raw provider-proxy path must do the same when Token Saver admits
    /// `RC_TOKEN_SAVER_POST_TOOL_USE=1` — otherwise nested Claude (advisor,
    /// spawn_subagent, shell `claude`) burns tokens with zero tool-output
    /// compression while lifecycle still shows Nested - Claude receipts.
    public static func providerProxyArguments(
        provider: AgentProvider,
        arguments: [String],
        environment: [String: String]
    ) -> [String] {
        // Claude PostToolUse is independent of the dialect prompt: nested
        // advisors use only Read/Glob/Grep, so PATH wrappers never fire and
        // hooks are the only provider-native rewrite path (Agents.md).
        var rewritten = ensuringClaudePostToolUseSettings(
            provider: provider,
            arguments: arguments,
            environment: environment
        )

        let prompt = tokenSaverProviderPrompt("", environment: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedTurn = isSupportedProviderTurn(provider: provider, arguments: rewritten)
        // Codex exec resume is a continuation ABI, not a fresh prompt turn:
        // do not inject developer instructions or dialect text, but still carry
        // the validated shell policy so its tool shells retain the host-issued
        // artifact transport.
        if provider == .codex, !supportedTurn || prompt.isEmpty {
            return ProviderSubprocessLauncher.codexShellEnvironmentPolicyArguments(
                provider: provider,
                environment: environment
            ) + rewritten
        }
        guard !prompt.isEmpty, supportedTurn else {
            return rewritten
        }

        switch provider {
        case .grok:
            return mergingProviderPrompt(
                prompt,
                option: "--rules",
                provider: provider,
                arguments: rewritten
            )
        case .claude:
            return mergingProviderPrompt(
                prompt,
                option: "--append-system-prompt",
                provider: provider,
                arguments: rewritten
            )
        case .codex:
            let scan = scanProviderArguments(provider: provider, arguments: rewritten)
            guard !scan.malformed else { return rewritten }
            let shellEnvironmentPolicy = ProviderSubprocessLauncher
                .codexShellEnvironmentPolicyArguments(
                    provider: provider,
                    environment: environment
                )
            let configValues = (scan.optionValues["--config"] ?? [])
                + (scan.optionValues["-c"] ?? [])
            let hasDeveloperOverride = configValues.contains {
                $0.hasPrefix("developer_instructions=")
            }
            guard !hasDeveloperOverride else {
                return shellEnvironmentPolicy + rewritten
            }
            let quoted = "\""
                + prompt
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                + "\""
            return shellEnvironmentPolicy
                + ["--config", "developer_instructions=\(quoted)"]
                + rewritten
        }
    }

    /// Inject Claude CLI `--settings` PostToolUse hooks on the raw provider-proxy
    /// path when Token Saver has admitted the Claude PostToolUse lane.
    ///
    /// Fail-open rules:
    /// - Non-Claude providers: unchanged.
    /// - Flag absent / not admitted: unchanged (byte-identical argv).
    /// - Administrative / unsupported turns: unchanged.
    /// - Caller already passed `--settings`: leave intact (never double-inject).
    /// - Settings builder fails: leave argv unchanged.
    static func ensuringClaudePostToolUseSettings(
        provider: AgentProvider,
        arguments: [String],
        environment: [String: String]
    ) -> [String] {
        guard provider == .claude else { return arguments }
        guard environment[ClaudeRunner.tokenSaverPostToolUseEnvKey] == "1" else {
            return arguments
        }
        guard isSupportedProviderTurn(provider: .claude, arguments: arguments) else {
            return arguments
        }
        // Reuse the Agent App settings builder so proxy and ClaudeRunner never
        // drift on hook command, matcher, or timeout.
        let settingsArgs = ClaudeRunner.ultracodeSettingsArgs(
            nil,
            environment: environment
        )
        guard settingsArgs.count == 2, settingsArgs[0] == "--settings",
              let ptuJSON = settingsArgs[1].data(using: .utf8),
              let ptuObject = try? JSONSerialization.jsonObject(with: ptuJSON) as? [String: Any],
              let ptuHooks = ptuObject["hooks"] as? [String: Any] else {
            return arguments
        }
        // Merge into an existing inline JSON --settings when present (nested CLIs
        // sometimes already pass --settings). File-path --settings stays untouched.
        if let settingsIndex = arguments.firstIndex(of: "--settings"),
           settingsIndex + 1 < arguments.count {
            let existing = arguments[settingsIndex + 1]
            if existing.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
               let existingData = existing.data(using: .utf8),
               var existingObject = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                var hooks = existingObject["hooks"] as? [String: Any] ?? [:]
                if hooks["PostToolUse"] == nil {
                    hooks["PostToolUse"] = ptuHooks["PostToolUse"]
                    existingObject["hooks"] = hooks
                    if let merged = try? JSONSerialization.data(
                        withJSONObject: existingObject,
                        options: [.sortedKeys]
                    ),
                       let mergedJSON = String(data: merged, encoding: .utf8) {
                        var out = arguments
                        out[settingsIndex + 1] = mergedJSON
                        return out
                    }
                }
                // Already has PostToolUse — leave intact.
                return arguments
            }
            // Path-form --settings: cannot safely merge; leave intact (fail open).
            return arguments
        }
        return settingsArgs + arguments
    }

    /// Restrict prompt/rules injection to provider invocations whose turn ABI
    /// RemoteCode understands. Administrative commands must remain byte-for-byte
    /// unchanged even when an inherited runtime environment enables routing.
    private static func isSupportedProviderTurn(
        provider: AgentProvider,
        arguments: [String]
    ) -> Bool {
        let scan = scanProviderArguments(provider: provider, arguments: arguments)
        guard !scan.malformed else { return false }
        if scan.flags.contains(where: {
            $0 == "--version" || $0 == "-V" || $0 == "--help" || $0 == "-h"
        }) {
            return false
        }
        let sessionContinuationFlags: Set<String>
        switch provider {
        case .codex:
            sessionContinuationFlags = []
        case .claude:
            sessionContinuationFlags = [
                "--resume", "-r", "--continue", "-c", "--session-id", "--fork-session"
            ]
        case .grok:
            sessionContinuationFlags = [
                "--resume", "-r", "--continue", "--session-id", "--fork-session"
            ]
        }
        if !scan.flags.isDisjoint(with: sessionContinuationFlags) {
            return false
        }

        switch provider {
        case .grok:
            return scan.positionals.isEmpty
                && ["--prompt-file", "--prompt", "-p"].contains {
                    scan.optionValues[$0]?.contains(where: { !$0.isEmpty }) == true
                }
        case .claude:
            let administrativeCommands: Set<String> = [
                "agents", "auth", "config", "doctor", "install",
                "mcp", "plugin", "plugins", "update"
            ]
            let isAdministrative = scan.positionals.first.map {
                administrativeCommands.contains($0)
            } ?? false
            return !isAdministrative
                && (scan.flags.contains("--print") || scan.flags.contains("-p"))
        case .codex:
            return scan.positionals.first == "exec"
                && scan.positionals.dropFirst().first != "resume"
        }
    }

    private struct ProviderArgumentScan {
        var flags = Set<String>()
        var optionValues: [String: [String]] = [:]
        var positionals: [String] = []
        var malformed = false
    }

    private static func scanProviderArguments(
        provider: AgentProvider,
        arguments: [String]
    ) -> ProviderArgumentScan {
        let optionBoundary = arguments.firstIndex(of: "--") ?? arguments.endIndex
        let valueOptions = providerValueOptions(provider)
        let flagOptions = providerFlagOptions(provider)
        var scan = ProviderArgumentScan()
        var index = 0
        while index < optionBoundary {
            let argument = arguments[index]
            if valueOptions.contains(argument) {
                scan.flags.insert(argument)
                guard index + 1 < optionBoundary else {
                    scan.malformed = true
                    return scan
                }
                scan.optionValues[argument, default: []].append(arguments[index + 1])
                index += 2
                continue
            }
            if let option = valueOptions.first(where: {
                argument.hasPrefix("\($0)=")
            }) {
                scan.flags.insert(option)
                scan.optionValues[option, default: []].append(
                    String(argument.dropFirst(option.count + 1))
                )
                index += 1
                continue
            }
            if argument == "-" {
                scan.positionals.append(argument)
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                guard flagOptions.contains(argument) else {
                    // Provider CLIs evolve. An unknown option may consume the
                    // following argument, so treating it as a valueless flag
                    // could make RemoteCode rewrite the wrong turn ABI.
                    scan.malformed = true
                    return scan
                }
                scan.flags.insert(argument)
                index += 1
                continue
            }
            scan.positionals.append(argument)
            index += 1
        }
        return scan
    }

    private static func providerValueOptions(_ provider: AgentProvider) -> Set<String> {
        switch provider {
        case .grok:
            return [
                "--prompt-file", "--prompt", "-p", "--rules",
                "--permission-mode", "--sandbox", "--model", "-m",
                "--effort", "--reasoning-effort", "--output-format",
                "--input-format", "--disallowed-tools", "--allowed-tools",
                "--settings", "--resume", "-r", "--session-id"
            ]
        case .claude:
            return [
                "--model", "--effort", "--output-format", "--input-format",
                "--permission-mode", "--tools", "--allowed-tools", "--allowedTools",
                "--disallowed-tools", "--disallowedTools", "--append-system-prompt",
                "--system-prompt", "--setting-sources", "--settings",
                "--session-id", "--resume", "-r"
            ]
        case .codex:
            return [
                "--sandbox", "--ask-for-approval", "-a", "--config", "-c",
                "--model", "-m", "--image", "--color", "--cd", "-C",
                "--profile", "-p"
            ]
        }
    }

    private static func providerFlagOptions(_ provider: AgentProvider) -> Set<String> {
        switch provider {
        case .grok:
            return [
                "--always-approve", "--auto-update", "--continue",
                "--help", "-h", "--list-models", "--memory", "--no-auto-update",
                "--no-memory", "--no-plan", "--no-subagents", "--plan",
                "--subagents", "--version", "-V"
            ]
        case .claude:
            return [
                "--continue", "-c", "--debug", "--disable-slash-commands",
                "--fork-session", "--help", "-h", "--ide", "--include-partial-messages",
                "--no-session-persistence", "--print", "-p", "--strict-mcp-config",
                "--verbose", "--version", "-V"
            ]
        case .codex:
            return [
                "--dangerously-bypass-approvals-and-sandbox", "--ephemeral",
                "--full-auto", "--help", "-h", "--ignore-user-config", "--json",
                "--oss", "--search", "--skip-git-repo-check", "--strict-config",
                "--version", "-V"
            ]
        }
    }

    private static func mergingProviderPrompt(
        _ prompt: String,
        option: String,
        provider: AgentProvider,
        arguments: [String]
    ) -> [String] {
        let scan = scanProviderArguments(provider: provider, arguments: arguments)
        guard !scan.malformed,
              (scan.optionValues[option]?.count ?? 0) <= 1 else {
            return arguments
        }
        var merged = arguments
        let optionBoundary = merged.firstIndex(of: "--") ?? merged.endIndex
        let valueOptions = providerValueOptions(provider)
        var index = 0
        while index < optionBoundary {
            let argument = merged[index]
            if argument == option {
                guard index + 1 < optionBoundary else { return arguments }
                merged[index + 1] += "\n\n" + prompt
                return merged
            }
            if argument.hasPrefix("\(option)=") {
                let existing = String(argument.dropFirst(option.count + 1))
                merged[index] = "\(option)=\(existing)\n\n\(prompt)"
                return merged
            }
            if valueOptions.contains(argument) {
                guard index + 1 < optionBoundary else { return arguments }
                index += 2
            } else {
                index += 1
            }
        }
        merged.insert(contentsOf: [option, prompt], at: optionBoundary)
        return merged
    }

    /// Inject Graphify query-first rules when host set `RC_GRAPHIFY_ENABLED=1`.
    /// Optional roots/graph path from env help the model call the right CLI without user prompts.
    public static func graphifyProviderPrompt(_ base: String, environment: [String: String]) -> String {
        guard environment["RC_GRAPHIFY_ENABLED"] == "1" else { return base }
        let banner = GraphifyStableSkillText.runtimeStatusBanner(environment: environment) ?? ""

        // Already fully injected (stable body present): still force absolute path banner first.
        if base.contains(GraphifyStableSkillText.agentInstructionsBody) {
            if let graph = environment["RC_GRAPHIFY_GRAPH_JSON"], !graph.isEmpty, !base.contains(graph) {
                let note = GraphifyStableSkillText.runtimeStatusBanner(environment: environment) ?? "Graphify runtime: --graph \(graph)"
                return note + "\n\n" + base
            }
            if !banner.isEmpty, !base.contains("HOST GRAPHIFY STATUS") {
                return banner + "\n\n" + base
            }
            return base
        }

        var block = GraphifyStableSkillText.agentInstructionsBody
        if let roots = environment["RC_GRAPHIFY_ROOTS"], !roots.isEmpty {
            block += "\nActive Graphify roots (one per line):\n\(roots)"
        }
        if let graph = environment["RC_GRAPHIFY_GRAPH_JSON"], !graph.isEmpty {
            block += "\nPrimary graph JSON (canonical; use --graph with this path): \(graph)"
        }
        if let artifact = environment["RC_GRAPHIFY_ARTIFACT_ROOT"], !artifact.isEmpty {
            block += "\nGraphify artifact root (Application Support; not repo graphify-out/): \(artifact)"
        }
        if environment["RC_GRAPHIFY_AMBIGUOUS"] == "1" {
            block += "\nNote: multi-repo workspace is ambiguous this turn; fail open if unsure which root applies."
        }
        if environment["RC_GRAPHIFY_STALE"] == "1" {
            block += "\nNote: graph is refreshing in the background this turn; fail open for broad search if query results look incomplete."
        }
        // Banner FIRST (before user request) so "tem graph?" cannot be answered from repo graphify-out alone.
        if banner.isEmpty {
            return base + "\n\n" + block
        }
        return banner + "\n\n" + base + "\n\n" + block
    }

    /// Distill injection for Token-Saver-enabled provider adapters.
    public static func managedDistillProviderPrompt(_ base: String) -> String {
        let withDistill = base.contains(distillAgentInstructionsBody)
            ? base
            : base + "\n\n" + distillAgentInstructionsBody
        // SR2 always-on for Claude + Codex + Grok whenever Token Saver distill hint is on.
        let withSR2 = SR2WirePolicy.appendingAlwaysOnInstruct(to: withDistill, tokenSaverHintOn: true)
        return TokenSaverProviderSafetyABI.appendingExactlyOnce(to: withSR2, enabled: true)
    }

    /// App-private Distill package directory (mirrors remote-code-orchestrate layout).
    public func distillAppPrivateDirectory() -> URL {
        appPrivateSkillsRoot.appendingPathComponent(Self.distillSkillID, isDirectory: true)
    }

    /// Install Distill into RemoteCode Application Support only — never into
    /// `~/.claude/skills`, `~/.codex/skills`, or `~/.grok/skills`.
    @discardableResult
    public func installAppPrivateDistillSkill(
        sourceRevision: String = "github-main-remote-code-template-v2",
        installedAt: Date = Date()
    ) throws -> AgentSkillInstallResult {
        try fileManager.createDirectory(at: appPrivateSkillsRoot, withIntermediateDirectories: true)
        let directory = distillAppPrivateDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let skillURL = directory.appendingPathComponent("SKILL.md")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = Data(Self.distillSkillTemplate.utf8)
        let checksum = Self.sha256Hex(data)
        let manifest = AgentSkillManifest(
            provider: .claude, // app-private; provider field is historical on the manifest
            skillID: Self.distillSkillID,
            sourceURL: Self.distillSourceURL,
            sourceRevision: sourceRevision,
            localVersion: Self.distillLocalVersion,
            sha256: checksum,
            installPath: skillURL.path,
            installedAt: installedAt
        )
        if let existingData = try? Data(contentsOf: skillURL),
           Self.sha256Hex(existingData) == checksum,
           let manifestData = try? Data(contentsOf: manifestURL),
           let existingManifest = try? decoder.decode(AgentSkillManifest.self, from: manifestData),
           existingManifest.sourceRevision == sourceRevision,
           existingManifest.localVersion == Self.distillLocalVersion {
            return AgentSkillInstallResult(action: .skipped, manifest: existingManifest)
        }
        try data.write(to: skillURL, options: .atomic)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        return AgentSkillInstallResult(action: .installed, manifest: manifest)
    }

    /// Remove legacy Distill copies that used to live in each provider's home skill tree.
    public func uninstallLegacyProviderDistillSkills() throws {
        for provider in AgentProvider.allCases {
            _ = try uninstallDistillSkill(for: provider)
            _ = try uninstallDistillInstructions(for: provider)
        }
    }

    private let claudeSkillsRoot: URL
    private let codexSkillsRoot: URL
    private let claudeInstructionsURL: URL
    private let codexInstructionsURL: URL
    private let cliBinDirectory: URL
    private let pathBinDirectory: URL
    private let shellBridgeDirectory: URL?
    private let linksDistillOntoUserPath: Bool
    private let artifactServiceBinaryURL: URL?
    private let appPrivateSkillsRoot: URL
    private let remoteCodeOrchestratePackage: RemoteCodeOrchestratePackage
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Distill + remote-code-orchestrate are app-private under RemoteCode Application
    /// Support and injected at runtime. Legacy provider-home skill roots are still
    /// accepted for cleanup of older installs and tests.
    public init(
        claudeSkillsRoot: URL = AgentSkillInstaller.defaultClaudeSkillsRoot(),
        codexSkillsRoot: URL = AgentSkillInstaller.defaultCodexSkillsRoot(),
        claudeInstructionsURL: URL = AgentSkillInstaller.defaultClaudeInstructionsURL(),
        codexInstructionsURL: URL = AgentSkillInstaller.defaultCodexInstructionsURL(),
        cliBinDirectory: URL = AgentSkillInstaller.defaultManagedCLIBinDirectory(),
        pathBinDirectory: URL = AgentSkillInstaller.defaultPathBinDirectory(),
        shellBridgeDirectory: URL? = nil,
        linksDistillOntoUserPath: Bool = true,
        artifactServiceBinaryURL: URL? = nil,
        appPrivateSkillsRoot: URL = AgentSkillInstaller.defaultAppPrivateSkillsRoot(),
        remoteCodeOrchestratePackage: RemoteCodeOrchestratePackage = AgentSkillInstaller.remoteCodeOrchestratePinnedPackage,
        fileManager: FileManager = .default
    ) {
        self.claudeSkillsRoot = claudeSkillsRoot
        self.codexSkillsRoot = codexSkillsRoot
        self.claudeInstructionsURL = claudeInstructionsURL
        self.codexInstructionsURL = codexInstructionsURL
        self.cliBinDirectory = cliBinDirectory
        self.pathBinDirectory = pathBinDirectory
        self.shellBridgeDirectory = shellBridgeDirectory
        self.linksDistillOntoUserPath = linksDistillOntoUserPath
        self.artifactServiceBinaryURL = artifactServiceBinaryURL
        self.appPrivateSkillsRoot = appPrivateSkillsRoot
        self.remoteCodeOrchestratePackage = remoteCodeOrchestratePackage
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Test seam: derive both provider skill roots from a sandboxed home directory so
    /// unit tests never write into the developer's real `~/.claude` / `~/.codex`.
    public convenience init(homeDirectory: URL, fileManager: FileManager = .default) {
        self.init(
            claudeSkillsRoot: homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true),
            codexSkillsRoot: homeDirectory.appendingPathComponent(".codex/skills", isDirectory: true),
            claudeInstructionsURL: homeDirectory.appendingPathComponent(".claude/CLAUDE.md"),
            codexInstructionsURL: homeDirectory.appendingPathComponent(".codex/AGENTS.md"),
            cliBinDirectory: homeDirectory.appendingPathComponent(".remote-code/bin", isDirectory: true),
            pathBinDirectory: homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            appPrivateSkillsRoot: homeDirectory.appendingPathComponent(".remote-code/app-private-skills", isDirectory: true),
            fileManager: fileManager
        )
    }

    public static func defaultClaudeSkillsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    public static func defaultCodexSkillsRoot() -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("skills", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/skills", isDirectory: true)
    }

    public static func defaultClaudeInstructionsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/CLAUDE.md")
    }

    public static func defaultCodexInstructionsURL() -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true).appendingPathComponent("AGENTS.md")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/AGENTS.md")
    }

    public static func defaultManagedCLIBinDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".remote-code/bin", isDirectory: true)
    }

    public static func defaultProviderShellBridgeDirectory() -> URL {
        defaultManagedCLIBinDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("shell/zsh", isDirectory: true)
    }

    /// The managed bin selected for this installer. Production uses the user's
    /// RemoteCode home; tests and isolated provider homes use their injected root.
    public var managedCLIBinURL: URL {
        cliBinDirectory
    }

    /// Provider-only aliases used for always-on Subagents routing. Keeping
    /// these outside the universal wrapper directory lets Token Saver OFF
    /// provider shells resolve nested providers without launching the
    /// RemoteCodeDistillService for ordinary commands.
    public var providerProxyBinURL: URL {
        cliBinDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("provider-bin", isDirectory: true)
    }

    public var providerShellBridgeURL: URL {
        shellBridgeDirectory ?? cliBinDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("shell/zsh", isDirectory: true)
    }

    /// Reject persisted startup pointers into any RemoteCode-owned bridge.
    /// Passing a prior app instance's managed bridge as a user profile would
    /// re-enter its interceptor and can recurse forever.
    public static func isManagedProviderShellBridgePath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard let marker = components.lastIndex(of: ".remote-code") else { return false }
        let suffix = Array(components.dropFirst(marker + 1))
        return suffix == ["shell", "zsh"]
            || suffix == ["shell", "zsh-tool-v1"]
            || (suffix.count >= 4
                && suffix[0] == "runtime"
                && suffix[suffix.count - 2] == "shell"
                && ["zsh", "zsh-tool-v1"].contains(suffix.last))
    }

    /// Per-artifact runtime install used only by admitted provider runs. Its
    /// PATH and ZDOTDIR cannot be overwritten by another app bundle's global
    /// compatibility reconcile. The namespace is content-addressed and owns a
    /// private executable copy, so replacing the source bundle in place cannot
    /// change a running provider's tool-shell target.
    public func runtimeInstaller(for serviceBinaryURL: URL) -> AgentSkillInstaller? {
        let binary = serviceBinaryURL.resolvingSymlinksInPath().standardizedFileURL
        guard binary.lastPathComponent == "RemoteCodeDistillService",
              fileManager.isExecutableFile(atPath: binary.path) else {
            return nil
        }
        guard let digest = Self.serviceBinaryIdentity(at: binary) else { return nil }
        let root = cliBinDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        let artifact = root.appendingPathComponent("RemoteCodeDistillService")
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: artifact.path) {
                guard fileManager.isExecutableFile(atPath: artifact.path),
                      Self.serviceBinaryIdentity(at: artifact) == digest else {
                    return nil
                }
            } else {
                let temporary = root.appendingPathComponent(
                    ".RemoteCodeDistillService.\(UUID().uuidString)"
                )
                try fileManager.copyItem(at: binary, to: temporary)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: temporary.path
                )
                do {
                    try fileManager.moveItem(at: temporary, to: artifact)
                } catch {
                    try? fileManager.removeItem(at: temporary)
                    guard fileManager.isExecutableFile(atPath: artifact.path),
                          Self.serviceBinaryIdentity(at: artifact) == digest else {
                        return nil
                    }
                }
            }
        } catch {
            return nil
        }
        return AgentSkillInstaller(
            claudeSkillsRoot: claudeSkillsRoot,
            codexSkillsRoot: codexSkillsRoot,
            claudeInstructionsURL: claudeInstructionsURL,
            codexInstructionsURL: codexInstructionsURL,
            cliBinDirectory: root.appendingPathComponent("bin", isDirectory: true),
            pathBinDirectory: pathBinDirectory,
            shellBridgeDirectory: root
                .appendingPathComponent("shell", isDirectory: true)
                .appendingPathComponent("zsh-tool-v1", isDirectory: true),
            linksDistillOntoUserPath: false,
            artifactServiceBinaryURL: artifact,
            appPrivateSkillsRoot: appPrivateSkillsRoot,
            remoteCodeOrchestratePackage: remoteCodeOrchestratePackage,
            fileManager: fileManager
        )
    }

    /// Bash's non-interactive startup hook. Grok ACP's persistent terminal uses
    /// Bash on macOS, so the zsh-only bridge is not enough to restore the managed
    /// PATH after a shell snapshot/profile refresh.
    public var providerShellBridgeBashEnvURL: URL {
        providerShellBridgeURL.appendingPathComponent(".bash_env")
    }

    /// A directory that is conventionally on the user's `$PATH`. RemoteCode bridges the
    /// managed `distill` CLI here so it runs from any shell without a hand-made shim.
    public static func defaultPathBinDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    public static func defaultAppPrivateSkillsRoot() -> URL {
        AgentOrchestrationRuntime.defaultPackageURL().deletingLastPathComponent()
    }

    /// Legacy provider-home install path. Prefer `installAppPrivateDistillSkill`.
    /// Kept for tests that exercise the old root; production reconcile no longer
    /// writes into `~/.claude/skills` / `~/.codex/skills` / `~/.grok/skills`.
    public func installDistillSkill(
        for provider: AgentProvider,
        sourceRevision: String,
        installedAt: Date = Date()
    ) throws -> AgentSkillInstallResult {
        try installSkill(
            provider: provider,
            skillID: Self.distillSkillID,
            skillText: Self.distillSkillTemplate,
            sourceURL: Self.distillSourceURL,
            sourceRevision: sourceRevision,
            localVersion: Self.distillLocalVersion,
            installedAt: installedAt
        )
    }

    public func installDistillInstructions(for provider: AgentProvider) throws {
        try upsertDistillInstructions(at: instructionsURL(for: provider))
    }

    /// Install the managed `distill` CLI as a SYMLINK to the native RemoteCodeDistillService
    /// binary, which runs in CLI mode when invoked via the "distill" basename. A Mach-O
    /// symlink — not a shebang script — so there is no Python dependency (N1) and the CLI
    /// is fail-open (writes raw stdin back on any error; see ManagedDistillCLI).
    /// `serviceBinaryURL` is resolved automatically when not provided (tests inject it).
    ///
    /// Idempotent and automatic for any user: repairs missing, dangling, or stale
    /// links under that user's home (`~/.remote-code/bin` + `~/.local/bin` bridge).
    @discardableResult
    public func installDistillCLI(appSupportDirectory: URL, serviceBinaryURL: URL? = nil) throws -> URL {
        try ensureDistillCLI(serviceBinaryURL: serviceBinaryURL)
    }

    /// Ensure the managed `distill` basename and PATH bridge exist and point at a
    /// live `RemoteCodeDistillService`. Safe to call on every Token Saver reconcile
    /// and before every admitted agent turn — no-ops when already healthy.
    ///
    /// Resolution order (works for any macOS user account):
    /// 1. explicit `serviceBinaryURL` when executable
    /// 2. `resolveServiceBinary` (app bundle aux, process siblings, SwiftPM)
    /// 3. recover from any existing healthy managed wrapper in this installer's
    ///    `cliBinDirectory` (e.g. `git`/`claude` still pointing at the service)
    @discardableResult
    public func ensureDistillCLI(serviceBinaryURL: URL? = nil) throws -> URL {
        try fileManager.createDirectory(at: cliBinDirectory, withIntermediateDirectories: true)
        let binary = try resolveServiceBinaryForManagedInstall(preferred: serviceBinaryURL)
        let url = distillCLIURL()
        if distillLinkNeedsRepair(at: url, expectedBinary: binary) {
            try? fileManager.removeItem(at: url)
            try fileManager.createSymbolicLink(at: url, withDestinationURL: binary)
        }
        if linksDistillOntoUserPath {
            linkManagedDistillOntoPath(target: url)
            // Second path-bridge pass: if ~/.local/bin/distill still missing
            // (first attempt failed on a race), retry once.
            if !fileManager.fileExists(atPath: distillPathLinkURL().path) {
                linkManagedDistillOntoPath(target: url)
            }
        }
        guard isHealthyDistillLink(at: url) else {
            throw AgentSkillCLIError.serviceBinaryUnavailable
        }
        return url
    }

    /// True when managed `distill` exists and resolves to an executable service binary.
    public func isDistillCLIHealthy() -> Bool {
        isHealthyDistillLink(at: distillCLIURL())
    }

    public func isDistillCLIPinned(to serviceBinaryURL: URL) -> Bool {
        guard let expected = artifactServiceBinaryURL ?? Optional(serviceBinaryURL),
              fileManager.isExecutableFile(atPath: expected.path),
              symbolicLink(at: distillCLIURL(), pointsTo: expected) else {
            return false
        }
        return Self.serviceBinaryIdentity(at: expected)
            == Self.serviceBinaryIdentity(at: serviceBinaryURL)
    }

    /// The immutable executable selected for an artifact-scoped provider run.
    /// A nil value means this is a legacy/global installer.
    public var pinnedServiceBinaryURL: URL? {
        artifactServiceBinaryURL
    }

    private func resolveServiceBinaryForManagedInstall(preferred: URL?) throws -> URL {
        if let artifactServiceBinaryURL,
           fileManager.isExecutableFile(atPath: artifactServiceBinaryURL.path),
           Self.serviceBinaryIdentity(at: artifactServiceBinaryURL) != nil {
            return artifactServiceBinaryURL
        }
        if let preferred, fileManager.isExecutableFile(atPath: preferred.path) {
            return preferred.resolvingSymlinksInPath()
        }
        // Prefer this installer's managed-bin wrappers (per-user home) before
        // process-global resolution. After app moves/upgrades, wrappers often
        // still point at the live service while Bundle.main / SwiftPM paths lag;
        // also keeps sandboxed test homes from picking up the host SPM binary.
        if let recovered = recoverServiceBinaryFromManagedWrappers() {
            return recovered
        }
        if let resolved = Self.resolveServiceBinary(fileManager: fileManager),
           fileManager.isExecutableFile(atPath: resolved.path) {
            return resolved.resolvingSymlinksInPath()
        }
        throw AgentSkillCLIError.serviceBinaryUnavailable
    }

    /// When the app bundle path changed or Bundle.main is wrong, recover the
    /// service binary from any remaining healthy managed symlink for this user.
    private func recoverServiceBinaryFromManagedWrappers() -> URL? {
        var names = ["claude", "codex", "grok", "git", "npm", "remote-code", "ls", "distill"]
        names.append(contentsOf: WrappedCommandCatalog.commands)
        names.append(contentsOf: (try? fileManager.contentsOfDirectory(atPath: cliBinDirectory.path)) ?? [])
        var seen = Set<String>()
        for name in names where seen.insert(name).inserted {
            let link = cliBinDirectory.appendingPathComponent(name)
            guard let absolute = resolvedSymlinkTarget(at: link),
                  fileManager.isExecutableFile(atPath: absolute.path),
                  absolute.lastPathComponent == "RemoteCodeDistillService"
                    || absolute.path.contains("RemoteCodeDistillService") else {
                continue
            }
            return absolute
        }
        return nil
    }

    private func resolvedSymlinkTarget(at link: URL) -> URL? {
        guard let dest = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            return nil
        }
        if (dest as NSString).isAbsolutePath {
            return URL(fileURLWithPath: dest).resolvingSymlinksInPath()
        }
        return link.deletingLastPathComponent()
            .appendingPathComponent(dest)
            .resolvingSymlinksInPath()
    }

    private func distillLinkNeedsRepair(at url: URL, expectedBinary: URL) -> Bool {
        guard let current = resolvedSymlinkTarget(at: url) else {
            // Missing, or a regular file (legacy script) — always replace.
            return true
        }
        if !fileManager.isExecutableFile(atPath: current.path) {
            return true
        }
        return current.resolvingSymlinksInPath().path
            != expectedBinary.resolvingSymlinksInPath().path
    }

    private func isHealthyDistillLink(at url: URL) -> Bool {
        guard let target = resolvedSymlinkTarget(at: url) else { return false }
        return fileManager.isExecutableFile(atPath: target.path)
    }

    public func uninstallDistillCLI() throws -> AgentSkillUninstallResult {
        let url = distillCLIURL()
        unlinkManagedDistillFromPath(target: url)
        // The managed CLI is our symlink in our managed bin dir — remove it.
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try fileManager.removeItem(at: url)
            return .removed
        }
        // Legacy: a pre-native Python script carrying our markers — clean it up too.
        if fileManager.fileExists(atPath: url.path),
           let text = try? String(contentsOf: url, encoding: .utf8),
           text.contains(Self.distillCLIBeginMarker),
           text.contains(Self.distillCLIEndMarker) {
            try fileManager.removeItem(at: url)
            return .removed
        }
        return .notPresent
    }

    /// Install the RTK-style transparent command wrappers: a symlink per *compressible*
    /// wrapped command in the managed bin dir (`~/.remote-code/bin`, PREPENDED to the agent
    /// PATH only). Exact-output tools (sed, rg, grep, cat, …) are never wrapped — agents
    /// need full stdout. Also removes any legacy exact-output symlinks from older installs.
    /// Provider basenames (`grok`/`claude`/`codex`) are **not** part of this catalog —
    /// see `installProviderProxies()`.
    @discardableResult
    public func installCommandWrappers(
        serviceBinaryURL: URL? = nil,
        searchDirectoriesOverride: [String]? = nil
    ) throws -> [String] {
        try fileManager.createDirectory(at: cliBinDirectory, withIntermediateDirectories: true)
        let binary = try resolveServiceBinaryForManagedInstall(preferred: serviceBinaryURL)
        let searchDirectories = searchDirectoriesOverride ?? systemCommandSearchDirectories()
        let discovered = Set(autoWrappableCommands(searchDirectories: searchDirectories))
        let reserved = Set(
            ProviderProxyCatalog.providers
                + ["distill", Self.agentAppMiddlewareCommand, "rc-retrieve-mcp"]
        )
        // Reconciliation must remove wrappers for commands that disappeared from
        // PATH; otherwise a stale symlink continues to shadow a missing command.
        let stale = ((try? fileManager.contentsOfDirectory(atPath: cliBinDirectory.path)) ?? [])
            .filter { !reserved.contains($0) && !discovered.contains($0) }
        _ = try removeManagedServiceSymlinks(basenames: stale)
        _ = try removeManagedWrapperSymlinks(
            basenames: stale + WrappedCommandCatalog.exactOutputCommands + WrappedCommandCatalog.interactiveCommands,
            binaryURL: binary
        )
        var installed: [String] = []
        for command in discovered.sorted() {
            let link = cliBinDirectory.appendingPathComponent(command)
            if let dest = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
                if dest == binary.path { installed.append(command); continue }
                // Replace an older RemoteCode service link after an app upgrade,
                // but preserve arbitrary user-owned symlinks in the managed bin.
                guard managedServiceSymlink(at: link) else { continue }
                try fileManager.removeItem(at: link)
            } else if fileManager.fileExists(atPath: link.path) {
                // A real (non-symlink) file we did not create — never clobber it.
                continue
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: binary)
            installed.append(command)
        }
        // Always keep the managed `distill` basename next to wrappers for every
        // user. PostToolUse hooks and voluntary `| distill` resolve this path.
        _ = try ensureDistillCLI(serviceBinaryURL: binary)
        if !installed.contains("distill") {
            installed.append("distill")
        }
        return installed
    }

    /// Verify the complete discovered wrapper set, including names that an
    /// install deliberately skipped because a user-owned file occupies the
    /// managed bin. A partial returned list is not sufficient evidence that
    /// the artifact runtime is safe to advertise.
    public func areCommandWrappersPinned(to serviceBinaryURL: URL) -> Bool {
        let expected = serviceBinaryURL.resolvingSymlinksInPath().path
        let discovered = autoWrappableCommands(searchDirectories: systemCommandSearchDirectories())
        return discovered.allSatisfy { command in
            let link = cliBinDirectory.appendingPathComponent(command)
            guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
                return false
            }
            let target = (raw as NSString).isAbsolutePath
                ? URL(fileURLWithPath: raw)
                : link.deletingLastPathComponent().appendingPathComponent(raw)
            return target.resolvingSymlinksInPath().path == expected
        }
    }

    /// Remove the command-wrapper symlinks — but only those still pointing at our service binary,
    /// so a user's own command on the managed path (unexpected) is never deleted.
    /// Includes legacy exact-output basenames so Token Saver off cleans old sed/rg wrappers.
    /// Does **not** remove nested provider proxies (`installProviderProxies`).
    @discardableResult
    public func uninstallCommandWrappers(
        serviceBinaryURL: URL? = nil
    ) throws -> [String] {
        let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager)
        let reserved = Set(
            ProviderProxyCatalog.providers
                + ["distill", Self.agentAppMiddlewareCommand, "rc-retrieve-mcp"]
        )
        let installedNames = ((try? fileManager.contentsOfDirectory(atPath: cliBinDirectory.path)) ?? [])
            .filter { !reserved.contains($0) }
        return try removeManagedWrapperSymlinks(
            basenames: installedNames + WrappedCommandCatalog.symlinkBasenamesToRemove,
            binaryURL: binary
        )
    }

    /// Install nested provider PATH proxies for `claude` / `codex` / `grok`.
    ///
    /// Ownership-safe and idempotent: never clobbers a user-owned regular file in the
    /// managed bin directory. Only creates a symlink when a real provider executable
    /// exists outside the managed bin (so we never shadow a missing CLI). Independent
    /// of Token Saver — available for every thread-scoped provider environment.
    ///
    /// - Parameter searchDirectoriesOverride: test seam; production always discovers
    ///   system PATH minus the managed bin.
    @discardableResult
    public func installProviderProxies(
        serviceBinaryURL: URL? = nil,
        searchDirectoriesOverride: [String]? = nil,
        binDirectory: URL? = nil
    ) throws -> [String] {
        let targetDirectory = binDirectory ?? cliBinDirectory
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let binary = try resolveServiceBinaryForManagedInstall(preferred: serviceBinaryURL)
        let searchDirectories = searchDirectoriesOverride ?? systemCommandSearchDirectories()
        var installed: [String] = []
        for command in ProviderProxyCatalog.providers {
            guard commandExistsOnSystem(command, searchDirectories: searchDirectories) else { continue }
            let link = targetDirectory.appendingPathComponent(command)
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                if symbolicLink(at: link, pointsTo: binary) {
                    installed.append(command)
                }
                // A same-basename target is not ownership evidence. Preserve
                // every symlink that does not resolve to this exact service.
                continue
            } else if fileManager.fileExists(atPath: link.path) {
                // A real (non-symlink) file we did not create — never clobber it.
                continue
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: binary)
            installed.append(command)
        }
        return installed
    }

    /// Install the explicit `remote-code agent-app …` entry point beside the
    /// nested provider proxies. The service dispatches this basename to the
    /// bundled `rc2` client; no second daemon or provider implementation exists.
    @discardableResult
    public func installAgentAppMiddleware(
        serviceBinaryURL: URL? = nil,
        binDirectory: URL? = nil
    ) throws -> URL? {
        let targetDirectory = binDirectory ?? cliBinDirectory
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        guard let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager) else {
            throw AgentSkillCLIError.serviceBinaryUnavailable
        }
        let link = targetDirectory.appendingPathComponent(Self.agentAppMiddlewareCommand)
        if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
            if symbolicLink(at: link, pointsTo: binary) {
                return link
            }
            // A symlink to any other canonical target is user-owned.
            return nil
        } else if fileManager.fileExists(atPath: link.path) {
            // Never overwrite a user-owned executable in the managed directory.
            return nil
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: binary)
        return link
    }

    /// Return the launcher only when the managed alias resolves to the exact
    /// RemoteCode service binary. A missing alias or user-owned file must never
    /// be advertised to provider prompts as a working host launcher.
    public func verifiedAgentAppMiddlewareURL(
        serviceBinaryURL: URL? = nil,
        binDirectory: URL? = nil
    ) -> URL? {
        let targetDirectory = binDirectory ?? cliBinDirectory
        let link = targetDirectory.appendingPathComponent(Self.agentAppMiddlewareCommand)
        guard let rawDestination = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
              let expected = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager)
        else {
            return nil
        }
        let destination = resolvedSymbolicLinkDestination(
            rawDestination,
            relativeTo: link
        )
        guard fileManager.isExecutableFile(atPath: destination.path),
              symbolicLink(at: link, pointsTo: expected)
        else {
            return nil
        }
        return link
    }

    /// Install zsh startup files that preserve the user's real profile and then
    /// restore RemoteCode's managed bin to the front of PATH. Provider CLIs
    /// commonly create login shells (`zsh -lc`) that otherwise reorder the
    /// injected PATH and bypass nested-provider proxies.
    @discardableResult
    public func installProviderShellBridge() throws -> URL {
        let directory = providerShellBridgeURL
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for fileName in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"] {
            let startupRoot = fileName == ".zshenv"
                ? "${RC_REMOTE_CODE_ORIGINAL_ZDOTDIR:-${HOME:-}}"
                : "${RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR:-${RC_REMOTE_CODE_ORIGINAL_ZDOTDIR:-${HOME:-}}}"
            let toolShellInterceptor = fileName == ".zshenv" ? """
            # Codex launches tool calls through an absolute zsh, bypassing PATH
            # wrappers. Hand the untouched -c source to the exact service binary
            # selected by this host before sourcing user startup. The shared
            # managed symlink is deliberately not consulted: another app instance
            # may have repointed it to an incompatible build. Every negative gate
            # runs the original source raw.
            if [[ "${RC_TOKEN_SAVER_DISTILL_HINT:-}" == "1" \
               && "${RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT:-}" == "1" \
               && "${RC_REMOTE_CODE_UNOWNED_TOOL_SHELL:-}" == "1" \
               && "${RC_TOKEN_SAVER_TOOL_SHELL_PROTOCOL:-}" == "1" \
               && "${RC_REMOTE_CODE_TOOL_SHELL_DONE:-}" != "1" \
               && "${RC_TOKEN_SAVER_TOOL_SHELL_DONE:-}" != "1" \
               && -n "${ZSH_EXECUTION_STRING:-}" \
               && -x "${RC_TOKEN_SAVER_TOOL_SHELL_BINARY:-}" ]]; then
              exec "$RC_TOKEN_SAVER_TOOL_SHELL_BINARY" cli tool-shell -- "$ZSH_EXECUTION_STRING"
            fi

            """ : ""
            let body = toolShellInterceptor + """
            # RemoteCode managed provider shell bridge.
            if [[ -n "${RC_REMOTE_CODE_MANAGED_ZDOTDIR:-}" ]]; then
              export ZDOTDIR="\(startupRoot)"
            fi
            if [[ -n "${ZDOTDIR:-}" && "$ZDOTDIR" != "${RC_REMOTE_CODE_MANAGED_ZDOTDIR:-}" && -r "$ZDOTDIR/\(fileName)" ]]; then
              source "$ZDOTDIR/\(fileName)"
            fi
            export RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR="${ZDOTDIR:-${HOME:-${RC_REMOTE_CODE_ORIGINAL_ZDOTDIR:-}}}"
            if [[ -n "${RC_REMOTE_CODE_MANAGED_ZDOTDIR:-}" ]]; then
              export ZDOTDIR="$RC_REMOTE_CODE_MANAGED_ZDOTDIR"
            fi
            if [[ -n "${RC_REMOTE_CODE_MANAGED_BIN:-}" ]]; then
              path=("$RC_REMOTE_CODE_MANAGED_BIN" "${(@)path:#${~${(b)RC_REMOTE_CODE_MANAGED_BIN}}}")
            fi
            if [[ -n "${RC_REMOTE_CODE_PROVIDER_PROXY_BIN:-}" ]]; then
              path=("$RC_REMOTE_CODE_PROVIDER_PROXY_BIN" "${(@)path:#${~${(b)RC_REMOTE_CODE_PROVIDER_PROXY_BIN}}}")
              export PATH
            fi
            """
            try Data((body + "\n").utf8).write(
                to: directory.appendingPathComponent(fileName),
                options: .atomic
            )
        }
        let bashBody = """
        # RemoteCode managed provider Bash bridge. Grok ACP's persistent terminal
        # can restore a shell snapshot after the provider starts; reapply the
        # managed bin after the user's optional BASH_ENV has run.
        if [ -n "${RC_REMOTE_CODE_ORIGINAL_BASH_ENV:-}" ] \
          && [ "${RC_REMOTE_CODE_ORIGINAL_BASH_ENV}" != "${BASH_ENV:-}" ] \
          && [ -r "${RC_REMOTE_CODE_ORIGINAL_BASH_ENV}" ]; then
          . "${RC_REMOTE_CODE_ORIGINAL_BASH_ENV}"
        fi
        if [ -n "${RC_REMOTE_CODE_MANAGED_BIN:-}" ]; then
          case "${PATH:-}" in
            "${RC_REMOTE_CODE_MANAGED_BIN}"|"${RC_REMOTE_CODE_MANAGED_BIN}":*) ;;
            *) PATH="${RC_REMOTE_CODE_MANAGED_BIN}${PATH:+:$PATH}"; export PATH ;;
          esac
        fi
        if [ -n "${RC_REMOTE_CODE_PROVIDER_PROXY_BIN:-}" ]; then
          case ":${PATH:-}:" in
            *:"${RC_REMOTE_CODE_PROVIDER_PROXY_BIN}":*) ;;
            *) PATH="${RC_REMOTE_CODE_PROVIDER_PROXY_BIN}${PATH:+:$PATH}"; export PATH ;;
          esac
        fi
        """
        try Data((bashBody + "\n").utf8).write(
            to: providerShellBridgeBashEnvURL,
            options: .atomic
        )
        return directory
    }

    /// Remove provider-proxy symlinks that still point at our service binary only.
    @discardableResult
    public func uninstallProviderProxies(
        serviceBinaryURL: URL? = nil,
        binDirectory: URL? = nil
    ) throws -> [String] {
        guard let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager)
        else {
            return []
        }
        var removed: [String] = []
        let targetDirectories = binDirectory.map { [$0] } ?? [cliBinDirectory, providerProxyBinURL]
        for targetDirectory in targetDirectories {
            for command in ProviderProxyCatalog.providers {
                let link = targetDirectory.appendingPathComponent(command)
                guard symbolicLink(at: link, pointsTo: binary) else { continue }
                try fileManager.removeItem(at: link)
                if !removed.contains(command) {
                    removed.append(command)
                }
            }
        }
        return removed
    }

    private func symbolicLink(at link: URL, pointsTo expected: URL) -> Bool {
        guard let rawDestination = try? fileManager.destinationOfSymbolicLink(
            atPath: link.path
        ) else {
            return false
        }
        let destination = resolvedSymbolicLinkDestination(
            rawDestination,
            relativeTo: link
        )
        return destination.resolvingSymlinksInPath().standardizedFileURL
            == expected.resolvingSymlinksInPath().standardizedFileURL
    }

    private func managedServiceSymlink(at link: URL) -> Bool {
        guard let destination = resolvedSymlinkTarget(at: link),
              fileManager.isExecutableFile(atPath: destination.path) else {
            return false
        }
        return destination.lastPathComponent == "RemoteCodeDistillService"
            || destination.path.contains("RemoteCodeDistillService")
    }

    private func resolvedSymbolicLinkDestination(
        _ rawDestination: String,
        relativeTo link: URL
    ) -> URL {
        rawDestination.hasPrefix("/")
            ? URL(fileURLWithPath: rawDestination)
            : link.deletingLastPathComponent().appendingPathComponent(rawDestination)
    }

    private func removeManagedWrapperSymlinks(
        basenames: [String],
        binaryURL: URL?
    ) throws -> [String] {
        guard let binaryURL else { return [] }
        var removed: [String] = []
        for command in basenames {
            let link = cliBinDirectory.appendingPathComponent(command)
            guard symbolicLink(at: link, pointsTo: binaryURL) else { continue }
            try fileManager.removeItem(at: link)
            removed.append(command)
        }
        return removed
    }

    private func removeManagedServiceSymlinks(basenames: [String]) throws -> [String] {
        var removed: [String] = []
        for command in basenames {
            let link = cliBinDirectory.appendingPathComponent(command)
            guard managedServiceSymlink(at: link) else { continue }
            try fileManager.removeItem(at: link)
            removed.append(command)
        }
        return removed
    }

    /// Agent command search path (the same dirs the agent's shell sees) minus the managed bin
    /// dir, so "does the real command exist?" never resolves to one of our own wrapper symlinks.
    private func systemCommandSearchDirectories() -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let managed = cliBinDirectory.path
        let joined = ProcessLocator.expandedPath(
            environmentPath: ProcessInfo.processInfo.environment["PATH"],
            homeDirectory: home
        )
        return joined.split(separator: ":").map(String.init).filter { !$0.isEmpty && $0 != managed }
    }

    private func commandExistsOnSystem(_ command: String, searchDirectories: [String]) -> Bool {
        for dir in searchDirectories {
            if fileManager.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(command)) {
                return true
            }
        }
        return false
    }

    /// Discover every executable basename the provider shell can resolve. The
    /// managed bin is excluded by `systemCommandSearchDirectories`, so discovery
    /// never feeds our own symlinks back into the set. Closed exclusions live in
    /// CoreModel and are shared with runtime dispatch.
    private func autoWrappableCommands(searchDirectories: [String]) -> [String] {
        var commands = Set<String>()
        for directory in searchDirectories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where WrappedCommandCatalog.isAutoWrappableCommand(name) {
                let path = (directory as NSString).appendingPathComponent(name)
                guard fileManager.isExecutableFile(atPath: path),
                      let attributes = try? fileManager.attributesOfItem(atPath: path),
                      let type = attributes[.type] as? FileAttributeType,
                      type == .typeRegular || type == .typeSymbolicLink else {
                    continue
                }
                commands.insert(name)
            }
        }
        return commands.sorted()
    }

    private func claudeSettingsURL() -> URL {
        claudeInstructionsURL.deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    private func codexConfigURL() -> URL {
        codexInstructionsURL.deletingLastPathComponent().appendingPathComponent("config.toml")
    }

    /// Install the RETRIEVE-ONLY MCP server (rc_retrieve) into Claude settings.json and
    /// Codex config.toml. Idempotent; preserves any user-authored entries. The server is the
    /// native RemoteCodeDistillService binary in `mcp` mode (no Python — N1).
    public func installRetrieveMCP(serviceBinaryURL: URL? = nil) throws {
        guard let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager) else {
            throw AgentSkillCLIError.serviceBinaryUnavailable
        }
        try installClaudeRetrieveMCP(binary: binary)
        try installCodexRetrieveMCP(binary: binary)
    }

    public func uninstallRetrieveMCP() throws {
        // Claude: drop only our server key, keep the rest of settings.json.
        let claude = claudeSettingsURL()
        if let data = try? Data(contentsOf: claude),
           var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var servers = root["mcpServers"] as? [String: Any] {
            servers.removeValue(forKey: Self.retrieveMCPName)
            root["mcpServers"] = servers
            if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: claude, options: .atomic)
            }
        }
        // Codex: remove our marker block, keep the rest of config.toml.
        let codex = codexConfigURL()
        if let text = try? String(contentsOf: codex, encoding: .utf8) {
            let stripped = Self.removingMarkerBlock(text, begin: Self.mcpBeginMarker, end: Self.mcpEndMarker)
            try? Data(stripped.utf8).write(to: codex, options: .atomic)
        }
    }

    private func installClaudeRetrieveMCP(binary: URL) throws {
        let url = claudeSettingsURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = obj
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[Self.retrieveMCPName] = ["command": binary.path, "args": ["mcp"]]
        root["mcpServers"] = servers
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    private func installCodexRetrieveMCP(binary: URL) throws {
        let url = codexConfigURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let block = """
        \(Self.mcpBeginMarker)
        [mcp_servers.\(Self.retrieveMCPName)]
        command = \(Self.tomlString(binary.path))
        args = ["mcp"]
        \(Self.mcpEndMarker)
        """
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let migrated = Self.removingTOMLTable(existing, named: "mcp_servers.\(Self.retrieveMCPName)")
        let next = Self.upsertMarkerBlock(migrated, begin: Self.mcpBeginMarker, end: Self.mcpEndMarker, block: block)
        try Data(next.utf8).write(to: url, options: .atomic)
    }

    private static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func removingMarkerBlock(_ text: String, begin: String, end: String) -> String {
        guard let b = text.range(of: begin), let e = text.range(of: end), b.lowerBound <= e.upperBound else {
            return text
        }
        var result = text
        result.removeSubrange(b.lowerBound..<e.upperBound)
        return result.replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func upsertMarkerBlock(_ text: String, begin: String, end: String, block: String) -> String {
        if text.range(of: begin) != nil, text.range(of: end) != nil {
            let stripped = removingMarkerBlock(text, begin: begin, end: end)
            let base = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            return base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n"
        }
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n"
    }

    private static func removingTOMLTable(_ text: String, named tableName: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [Substring] = []
        var isRemovingTable = false
        var didRemoveTable = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isExactTOMLTableHeader(trimmed, tableName: tableName) {
                isRemovingTable = true
                didRemoveTable = true
                continue
            }
            if isRemovingTable {
                if trimmed == mcpEndMarker || isTOMLTableHeader(trimmed) {
                    isRemovingTable = false
                } else {
                    continue
                }
            }
            result.append(line)
        }

        return didRemoveTable ? result.joined(separator: "\n") : text
    }

    private static func isExactTOMLTableHeader(_ line: String, tableName: String) -> Bool {
        guard let header = tomlTableHeader(in: line), !header.isArray else { return false }
        let compactName = removingWhitespaceOutsideTOMLQuotes(header.name)
        guard let separator = tableName.firstIndex(of: ".") else {
            return compactName == tableName
        }
        let prefix = tableName[..<separator]
        let leaf = tableName[tableName.index(after: separator)...]
        let prefixes = [String(prefix), "\"\(prefix)\"", "'\(prefix)'"]
        let leaves = [String(leaf), "\"\(leaf)\"", "'\(leaf)'"]
        return prefixes.contains { prefix in
            leaves.contains { leaf in compactName == "\(prefix).\(leaf)" }
        }
    }

    private static func removingWhitespaceOutsideTOMLQuotes(_ value: Substring) -> String {
        var result = ""
        var activeQuote: Character?
        var isEscaped = false

        for character in value {
            if let quote = activeQuote {
                result.append(character)
                if quote == "\"", character == "\\", !isEscaped {
                    isEscaped = true
                    continue
                }
                if character == quote, !isEscaped {
                    activeQuote = nil
                }
                isEscaped = false
            } else if character == "\"" || character == "'" {
                activeQuote = character
                result.append(character)
            } else if !character.isWhitespace {
                result.append(character)
            }
        }
        return result
    }

    private static func isTOMLTableHeader(_ line: String) -> Bool {
        tomlTableHeader(in: line) != nil
    }

    private static func tomlTableHeader(in line: String) -> (name: Substring, isArray: Bool)? {
        guard line.hasPrefix("[") else { return nil }
        let isArray = line.hasPrefix("[[")
        var index = line.index(line.startIndex, offsetBy: isArray ? 2 : 1)
        let nameStart = index
        var activeQuote: Character?
        var isEscaped = false

        while index < line.endIndex {
            let character = line[index]
            if let quote = activeQuote {
                if quote == "\"", character == "\\", !isEscaped {
                    isEscaped = true
                } else {
                    if character == quote, !isEscaped {
                        activeQuote = nil
                    }
                    isEscaped = false
                }
            } else if character == "\"" || character == "'" {
                activeQuote = character
            } else if character == "]" {
                let nameEnd = index
                var remainderStart = line.index(after: index)
                if isArray {
                    guard remainderStart < line.endIndex, line[remainderStart] == "]" else {
                        index = remainderStart
                        continue
                    }
                    remainderStart = line.index(after: remainderStart)
                }
                let remainder = line[remainderStart...].trimmingCharacters(in: .whitespaces)
                guard remainder.isEmpty || remainder.hasPrefix("#") else { return nil }
                return (line[nameStart..<nameEnd], isArray)
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// Resolve only a service executable shipped beside this app/test process.
    /// This intentionally never recovers through the mutable per-user wrapper
    /// directory, so the result is safe to pin into a host-issued capability.
    public static func resolveCurrentServiceBinary(fileManager: FileManager = .default) -> URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "RemoteCodeDistillService"),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled.resolvingSymlinksInPath()
        }
        // Packaged apps also place the service next to the main binary under
        // Contents/MacOS (not only as an "auxiliary executable" lookup).
        if let executables = Bundle.main.executableURL?.deletingLastPathComponent() {
            let sibling = executables.appendingPathComponent("RemoteCodeDistillService")
            if fileManager.isExecutableFile(atPath: sibling.path) {
                return sibling.resolvingSymlinksInPath()
            }
        }
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
        if let sibling = firstServiceSibling(in: [executableDirectory], fileManager: fileManager) {
            return sibling.resolvingSymlinksInPath()
        }
        if let sibling = firstServiceSibling(in: xctestBundleSearchDirectories(), fileManager: fileManager) {
            return sibling.resolvingSymlinksInPath()
        }
        return nil
    }

    /// Resolve the service for legacy managed-wrapper install/repair. Prefer
    /// this process's exact artifact, then retain existing dev/recovery fallbacks.
    public static func resolveServiceBinary(fileManager: FileManager = .default) -> URL? {
        if let current = resolveCurrentServiceBinary(fileManager: fileManager) {
            return current
        }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for candidate in swiftPMServiceBinaryCandidates(in: cwd, fileManager: fileManager) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath()
            }
        }
        // Last resort for any user: recover from their existing managed wrappers
        // under the default home managed bin (installers with custom homes use
        // the instance method recoverServiceBinaryFromManagedWrappers).
        let defaultBin = defaultManagedCLIBinDirectory()
        let probeNames = ["claude", "codex", "grok", "git", "npm", "ls", "remote-code"]
            + WrappedCommandCatalog.commands
        var seen = Set<String>()
        for name in probeNames where seen.insert(name).inserted {
            let link = defaultBin.appendingPathComponent(name)
            guard let dest = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
                continue
            }
            let absolute: URL
            if (dest as NSString).isAbsolutePath {
                absolute = URL(fileURLWithPath: dest).resolvingSymlinksInPath()
            } else {
                absolute = link.deletingLastPathComponent()
                    .appendingPathComponent(dest)
                    .resolvingSymlinksInPath()
            }
            guard fileManager.isExecutableFile(atPath: absolute.path),
                  absolute.lastPathComponent == "RemoteCodeDistillService"
                    || absolute.path.contains("RemoteCodeDistillService") else {
                continue
            }
            return absolute
        }
        // Universal command discovery can leave only a custom-name wrapper after
        // an app move. Scan the managed directory so recovery does not depend on
        // the historical catalog.
        if let names = try? fileManager.contentsOfDirectory(atPath: defaultBin.path) {
            for name in names where seen.insert(name).inserted {
                let link = defaultBin.appendingPathComponent(name)
                guard let dest = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
                    continue
                }
                let absolute: URL = (dest as NSString).isAbsolutePath
                    ? URL(fileURLWithPath: dest).resolvingSymlinksInPath()
                    : link.deletingLastPathComponent()
                        .appendingPathComponent(dest)
                        .resolvingSymlinksInPath()
                guard fileManager.isExecutableFile(atPath: absolute.path),
                      absolute.lastPathComponent == "RemoteCodeDistillService"
                        || absolute.path.contains("RemoteCodeDistillService") else {
                    continue
                }
                return absolute
            }
        }
        return nil
    }

    private static func firstServiceSibling(in directories: [URL], fileManager: FileManager) -> URL? {
        var scannedRoots: Set<String> = []
        for directory in directories {
            for base in directory.ancestorDirectories() where scannedRoots.insert(base.path).inserted {
                let sibling = base.appendingPathComponent("RemoteCodeDistillService")
                if fileManager.isExecutableFile(atPath: sibling.path) {
                    return sibling
                }
            }
        }
        return nil
    }

    private static func xctestBundleSearchDirectories() -> [URL] {
        var directories: [URL] = []
        for argument in CommandLine.arguments.dropFirst() where argument.hasSuffix(".xctest") {
            directories.append(URL(fileURLWithPath: argument).deletingLastPathComponent())
        }
        return directories
    }

    private static func swiftPMServiceBinaryCandidates(in packageRoot: URL, fileManager: FileManager) -> [URL] {
        let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
        var candidates = [
            buildRoot.appendingPathComponent("debug/RemoteCodeDistillService"),
            buildRoot.appendingPathComponent("release/RemoteCodeDistillService")
        ]
        if let triples = try? fileManager.contentsOfDirectory(
            at: buildRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for triple in triples {
                guard (try? triple.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                candidates.append(triple.appendingPathComponent("debug/RemoteCodeDistillService"))
                candidates.append(triple.appendingPathComponent("release/RemoteCodeDistillService"))
            }
        }
        return candidates
    }

    /// Bridge the managed CLI onto the user's `$PATH` (`~/.local/bin/distill`) so `distill`
    /// runs from any shell without a hand-made shim. RemoteCode owns this symlink: it
    /// (re)points a missing/stale link at the managed CLI and replaces a recognizable legacy
    /// distill launcher, but never clobbers an unrelated user file at the same path.
    /// Best-effort — a failure here never fails the managed-CLI install.
    private func linkManagedDistillOntoPath(target: URL) {
        let link = distillPathLinkURL()
        do {
            try fileManager.createDirectory(at: pathBinDirectory, withIntermediateDirectories: true)
            if let dest = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
                if dest == target.path { return }
                try fileManager.removeItem(at: link)
            } else if fileManager.fileExists(atPath: link.path) {
                let existing = (try? String(contentsOf: link, encoding: .utf8)) ?? ""
                guard existing.contains(Self.distillCLIBeginMarker)
                    || existing.contains("distill/src/cli")
                    || existing.contains("dev/distill") else {
                    NSLog("RemoteCode: leaving non-managed \(link.path) on PATH untouched")
                    return
                }
                try fileManager.removeItem(at: link)
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        } catch {
            NSLog("RemoteCode managed distill PATH link failed: \(error)")
        }
    }

    /// Remove the PATH symlink only while it still points at our managed CLI, so a user's
    /// own `distill` on PATH is never deleted when Token Saver is disabled.
    private func unlinkManagedDistillFromPath(target: URL) {
        let link = distillPathLinkURL()
        guard let dest = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
              dest == target.path else {
            return
        }
        try? fileManager.removeItem(at: link)
    }

    @discardableResult
    public func reconcileRemoteCodeOrchestrate(
        installedAt: Date = Date()
    ) throws -> RemoteCodeOrchestrateInstallResult {
        // Never SPM Bundle.module here: its generated accessor only checks the
        // .app root and a hardcoded builder .build path, then fatalErrors —
        // v2.0.85–v2.0.87 crashed every packaged launch through this call.
        let resourceBundle: Bundle
        do {
            resourceBundle = try AgentRuntimeResourceBundle.bundle(fileManager: fileManager)
        } catch {
            throw RemoteCodeOrchestrateInstallError.sourceMissing(
                "Embedded resource bundle: \(AgentRuntimeResourceBundle.bundleFileName)"
            )
        }
        guard let embeddedDirectory = resourceBundle.url(
            forResource: remoteCodeOrchestratePackage.skillID,
            withExtension: nil
        ) else {
            throw RemoteCodeOrchestrateInstallError.sourceMissing(
                "Embedded resource: \(remoteCodeOrchestratePackage.skillID)"
            )
        }
        return try installRemoteCodeOrchestrate(from: embeddedDirectory, installedAt: installedAt)
    }

    public func remoteCodeOrchestrateDirectory() -> URL {
        appPrivateSkillsRoot.appendingPathComponent(remoteCodeOrchestratePackage.skillID, isDirectory: true)
    }

    public func remoteCodeOrchestrateLastKnownGoodDirectory() -> URL {
        appPrivateSkillsRoot.appendingPathComponent(
            "\(remoteCodeOrchestratePackage.skillID).last-known-good",
            isDirectory: true
        )
    }

    public func installRemoteCodeOrchestrate(
        from sourceDirectory: URL,
        installedAt: Date = Date()
    ) throws -> RemoteCodeOrchestrateInstallResult {
        let sourceFiles = try validatedRemoteCodeOrchestrateSource(
            at: sourceDirectory,
            package: remoteCodeOrchestratePackage
        )
        try prepareAppPrivateSkillsRoot()

        let destination = remoteCodeOrchestrateDirectory()
        let current = inspectManagedPackage(at: destination)
        switch current {
        case .unmanaged:
            throw RemoteCodeOrchestrateInstallError.unmanagedCollision(destination.path)
        case .valid(let manifest) where manifestMatchesPinnedPackage(manifest):
            return RemoteCodeOrchestrateInstallResult(action: .skipped, manifest: manifest)
        default:
            break
        }

        // Both RemoteCode.app and the scheduled-task LaunchAgent reconcile at
        // login; the loser of that race can fail the staging/move below after
        // the winner installed the identical pinned package. Losing is success:
        // re-inspect and report .skipped instead of surfacing a session-long
        // install error. Source validation and the unmanaged-collision guard
        // above stay OUTSIDE this catch so a corrupted shipped bundle or a
        // user-owned destination can never be masked by an existing install.
        do {
            return try stageAndActivateRemoteCodeOrchestrate(
                sourceDirectory: sourceDirectory,
                sourceFiles: sourceFiles,
                current: current,
                destination: destination,
                installedAt: installedAt
            )
        } catch {
            if case .valid(let manifest) = inspectManagedPackage(at: destination),
               manifestMatchesPinnedPackage(manifest) {
                return RemoteCodeOrchestrateInstallResult(action: .skipped, manifest: manifest)
            }
            throw error
        }
    }

    private func stageAndActivateRemoteCodeOrchestrate(
        sourceDirectory: URL,
        sourceFiles: [RemoteCodeOrchestrateFile],
        current: ManagedPackageInspection,
        destination: URL,
        installedAt: Date
    ) throws -> RemoteCodeOrchestrateInstallResult {
        let stagingRoot = appPrivateSkillsRoot.appendingPathComponent(".staging", isDirectory: true)
        try prepareOwnedDirectory(stagingRoot)
        let staged = stagingRoot.appendingPathComponent(
            "\(remoteCodeOrchestratePackage.skillID)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staged) }

        for file in sourceFiles {
            let source = sourceDirectory.appendingPathComponent(file.relativePath)
            let target = staged.appendingPathComponent(file.relativePath)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: target)
        }

        let stagedFiles = try validatedRemoteCodeOrchestrateSource(
            at: staged,
            package: remoteCodeOrchestratePackage
        )
        let manifest = RemoteCodeOrchestrateManifest(
            schemaVersion: 1,
            managedBy: "RemoteCode",
            skillID: remoteCodeOrchestratePackage.skillID,
            sourceURL: remoteCodeOrchestratePackage.sourceURL,
            sourceRevision: remoteCodeOrchestratePackage.sourceRevision,
            sourceTreeSHA256: remoteCodeOrchestratePackage.sourceTreeSHA256,
            localVersion: remoteCodeOrchestratePackage.localVersion,
            installPath: destination.path,
            installedAt: installedAt,
            files: stagedFiles
        )
        try encoder.encode(manifest).write(
            to: staged.appendingPathComponent(Self.remoteCodeOrchestrateManifestName),
            options: .atomic
        )
        let runtimeManifest = RemoteCodeOrchestrateRuntimeManifest(
            schemaVersion: 1,
            packageID: remoteCodeOrchestratePackage.skillID,
            sourceRevision: remoteCodeOrchestratePackage.sourceRevision,
            files: Dictionary(uniqueKeysWithValues: stagedFiles.map { ($0.relativePath, $0.sha256) })
        )
        try encoder.encode(runtimeManifest).write(
            to: staged.appendingPathComponent(Self.remoteCodeOrchestrateRuntimeManifestName),
            options: .atomic
        )
        _ = try validateManagedPackage(at: staged)

        let action: RemoteCodeOrchestrateInstallResult.Action
        switch current {
        case .absent:
            try fileManager.moveItem(at: staged, to: destination)
            action = .installed
        case .valid:
            try replaceActivePackage(with: staged, preserveCurrentAsLastKnownGood: true)
            action = .updated
        case .invalidManaged:
            try replaceActivePackage(with: staged, preserveCurrentAsLastKnownGood: false)
            action = .repaired
        case .unmanaged:
            throw RemoteCodeOrchestrateInstallError.unmanagedCollision(destination.path)
        }

        let activated = try validateManagedPackage(at: destination)
        return RemoteCodeOrchestrateInstallResult(action: action, manifest: activated)
    }

    public func remoteCodeOrchestrateStatus() -> RemoteCodeOrchestrateStatus {
        let lastKnownGoodAvailable: Bool
        if case .valid = inspectManagedPackage(at: remoteCodeOrchestrateLastKnownGoodDirectory()) {
            lastKnownGoodAvailable = true
        } else {
            lastKnownGoodAvailable = false
        }

        switch inspectManagedPackage(at: remoteCodeOrchestrateDirectory()) {
        case .absent:
            return RemoteCodeOrchestrateStatus(
                state: .notInstalled,
                manifest: nil,
                lastKnownGoodAvailable: lastKnownGoodAvailable,
                repairReason: nil
            )
        case .unmanaged:
            return RemoteCodeOrchestrateStatus(
                state: .unmanagedCollision,
                manifest: nil,
                lastKnownGoodAvailable: lastKnownGoodAvailable,
                repairReason: "The app-private skill path contains content not owned by RemoteCode."
            )
        case .invalidManaged(let reason):
            return RemoteCodeOrchestrateStatus(
                state: .repairRequired,
                manifest: nil,
                lastKnownGoodAvailable: lastKnownGoodAvailable,
                repairReason: reason
            )
        case .valid(let manifest):
            return RemoteCodeOrchestrateStatus(
                state: manifestMatchesPinnedPackage(manifest) ? .ready : .updateRequired,
                manifest: manifest,
                lastKnownGoodAvailable: lastKnownGoodAvailable,
                repairReason: nil
            )
        }
    }

    @discardableResult
    public func restoreRemoteCodeOrchestrateLastKnownGood() throws -> RemoteCodeOrchestrateManifest {
        let lastKnownGood = remoteCodeOrchestrateLastKnownGoodDirectory()
        guard case .valid(let manifest) = inspectManagedPackage(at: lastKnownGood) else {
            throw RemoteCodeOrchestrateInstallError.lastKnownGoodUnavailable
        }

        let destination = remoteCodeOrchestrateDirectory()
        if case .unmanaged = inspectManagedPackage(at: destination) {
            throw RemoteCodeOrchestrateInstallError.unmanagedCollision(destination.path)
        }

        let displaced = appPrivateSkillsRoot.appendingPathComponent(
            ".repair-displaced-\(UUID().uuidString)",
            isDirectory: true
        )
        let destinationExists = pathEntryExists(destination)
        if destinationExists {
            try fileManager.moveItem(at: destination, to: displaced)
        }
        do {
            try fileManager.moveItem(at: lastKnownGood, to: destination)
        } catch {
            if destinationExists {
                try? fileManager.moveItem(at: displaced, to: destination)
            }
            throw error
        }
        if destinationExists {
            try fileManager.removeItem(at: displaced)
        }
        let activated = try validateManagedPackage(at: destination)
        guard activated == manifest else {
            throw RemoteCodeOrchestrateInstallError.invalidManagedPackage(
                "restored package changed during activation"
            )
        }
        return activated
    }

    static func remoteCodeOrchestrateTreeDigest(_ files: [RemoteCodeOrchestrateFile]) -> String {
        let canonical = files.sorted { $0.relativePath < $1.relativePath }.map {
            "\($0.relativePath)\t\($0.byteCount)\t\($0.sha256)\n"
        }.joined()
        return sha256Hex(Data(canonical.utf8))
    }

    private enum ManagedPackageInspection {
        case absent
        case unmanaged
        case invalidManaged(String)
        case valid(RemoteCodeOrchestrateManifest)
    }

    private struct RemoteCodeOrchestrateRuntimeManifest: Codable {
        let schemaVersion: Int
        let packageID: String
        let sourceRevision: String
        let files: [String: String]
    }

    private func inspectManagedPackage(at directory: URL) -> ManagedPackageInspection {
        guard pathEntryExists(directory) else { return .absent }
        guard !isSymbolicLink(directory), isDirectory(directory) else { return .unmanaged }
        let manifestURL = directory.appendingPathComponent(Self.remoteCodeOrchestrateManifestName)
        guard pathEntryExists(manifestURL), !isSymbolicLink(manifestURL) else {
            return .unmanaged
        }
        do {
            return .valid(try validateManagedPackage(at: directory))
        } catch {
            return .invalidManaged(String(describing: error))
        }
    }

    private func validatedRemoteCodeOrchestrateSource(
        at directory: URL,
        package: RemoteCodeOrchestratePackage,
        ignoredPaths: Set<String> = []
    ) throws -> [RemoteCodeOrchestrateFile] {
        if isSymbolicLink(directory) {
            throw RemoteCodeOrchestrateInstallError.symbolicLink(".")
        }
        guard fileManager.fileExists(atPath: directory.path), isDirectory(directory) else {
            throw RemoteCodeOrchestrateInstallError.sourceMissing(directory.path)
        }

        let allowedPaths = package.allowedPaths
        for path in allowedPaths {
            try validateSafeRelativePath(path)
        }
        guard Set(allowedPaths).count == allowedPaths.count else {
            throw RemoteCodeOrchestrateInstallError.invalidManagedPackage("duplicate allowed path")
        }
        let allowed = Set(allowedPaths)
        let allowedDirectories = Set(allowedPaths.flatMap(Self.parentDirectories))
        var found: [RemoteCodeOrchestrateFile] = []
        var foundPaths = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw RemoteCodeOrchestrateInstallError.sourceMissing(directory.path)
        }

        for case let item as URL in enumerator {
            let relativePath = try relativePath(of: item, under: directory)
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw RemoteCodeOrchestrateInstallError.symbolicLink(relativePath)
            }
            if values.isDirectory == true {
                guard allowedDirectories.contains(relativePath) else {
                    throw RemoteCodeOrchestrateInstallError.unexpectedEntry(relativePath)
                }
                continue
            }
            if ignoredPaths.contains(relativePath) {
                guard values.isRegularFile == true else {
                    throw RemoteCodeOrchestrateInstallError.unexpectedEntry(relativePath)
                }
                continue
            }
            guard values.isRegularFile == true, allowed.contains(relativePath) else {
                throw RemoteCodeOrchestrateInstallError.unexpectedEntry(relativePath)
            }
            let data = try Data(contentsOf: item, options: [.mappedIfSafe])
            found.append(RemoteCodeOrchestrateFile(
                relativePath: relativePath,
                byteCount: data.count,
                sha256: Self.sha256Hex(data)
            ))
            foundPaths.insert(relativePath)
        }

        if let missing = allowed.subtracting(foundPaths).sorted().first {
            throw RemoteCodeOrchestrateInstallError.missingRequiredFile(missing)
        }
        let actualDigest = Self.remoteCodeOrchestrateTreeDigest(found)
        guard actualDigest == package.sourceTreeSHA256 else {
            throw RemoteCodeOrchestrateInstallError.sourceTreeDigestMismatch(
                expected: package.sourceTreeSHA256,
                actual: actualDigest
            )
        }
        return found.sorted { $0.relativePath < $1.relativePath }
    }

    private func validateManagedPackage(at directory: URL) throws -> RemoteCodeOrchestrateManifest {
        let manifestURL = directory.appendingPathComponent(Self.remoteCodeOrchestrateManifestName)
        let manifest = try decoder.decode(RemoteCodeOrchestrateManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1,
              manifest.managedBy == "RemoteCode",
              manifest.skillID == remoteCodeOrchestratePackage.skillID else {
            throw RemoteCodeOrchestrateInstallError.invalidManagedPackage("ownership manifest mismatch")
        }
        let package = RemoteCodeOrchestratePackage(
            skillID: manifest.skillID,
            sourceURL: manifest.sourceURL,
            sourceRevision: manifest.sourceRevision,
            sourceTreeSHA256: manifest.sourceTreeSHA256,
            localVersion: manifest.localVersion,
            allowedPaths: manifest.files.map(\.relativePath)
        )
        let files = try validatedRemoteCodeOrchestrateSource(
            at: directory,
            package: package,
            ignoredPaths: [
                Self.remoteCodeOrchestrateManifestName,
                Self.remoteCodeOrchestrateRuntimeManifestName
            ]
        )
        guard files == manifest.files.sorted(by: { $0.relativePath < $1.relativePath }) else {
            throw RemoteCodeOrchestrateInstallError.invalidManagedPackage("file manifest mismatch")
        }
        let runtimeManifestURL = directory.appendingPathComponent(Self.remoteCodeOrchestrateRuntimeManifestName)
        let runtimeManifest = try decoder.decode(
            RemoteCodeOrchestrateRuntimeManifest.self,
            from: Data(contentsOf: runtimeManifestURL)
        )
        guard runtimeManifest.schemaVersion == 1,
              runtimeManifest.packageID == manifest.skillID,
              runtimeManifest.sourceRevision == manifest.sourceRevision,
              runtimeManifest.files == Dictionary(
                uniqueKeysWithValues: files.map { ($0.relativePath, $0.sha256) }
              ) else {
            throw RemoteCodeOrchestrateInstallError.invalidManagedPackage("runtime manifest mismatch")
        }
        return manifest
    }

    private func manifestMatchesPinnedPackage(_ manifest: RemoteCodeOrchestrateManifest) -> Bool {
        manifest.skillID == remoteCodeOrchestratePackage.skillID
            && manifest.sourceURL == remoteCodeOrchestratePackage.sourceURL
            && manifest.sourceRevision == remoteCodeOrchestratePackage.sourceRevision
            && manifest.sourceTreeSHA256 == remoteCodeOrchestratePackage.sourceTreeSHA256
            && manifest.localVersion == remoteCodeOrchestratePackage.localVersion
    }

    private func replaceActivePackage(with staged: URL, preserveCurrentAsLastKnownGood: Bool) throws {
        let destination = remoteCodeOrchestrateDirectory()
        let lastKnownGood = remoteCodeOrchestrateLastKnownGoodDirectory()
        if preserveCurrentAsLastKnownGood {
            switch inspectManagedPackage(at: lastKnownGood) {
            case .absent:
                break
            case .valid:
                try fileManager.removeItem(at: lastKnownGood)
            case .invalidManaged, .unmanaged:
                throw RemoteCodeOrchestrateInstallError.unmanagedCollision(lastKnownGood.path)
            }
            let stagedLastKnownGood = appPrivateSkillsRoot.appendingPathComponent(
                ".last-known-good-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: stagedLastKnownGood) }
            try fileManager.copyItem(at: destination, to: stagedLastKnownGood)
            _ = try validateManagedPackage(at: stagedLastKnownGood)
            try fileManager.moveItem(at: stagedLastKnownGood, to: lastKnownGood)
        }

        _ = try fileManager.replaceItemAt(
            destination,
            withItemAt: staged,
            backupItemName: nil,
            options: []
        )
    }

    private func prepareAppPrivateSkillsRoot() throws {
        try prepareOwnedDirectory(appPrivateSkillsRoot)
    }

    private func prepareOwnedDirectory(_ directory: URL) throws {
        if pathEntryExists(directory) {
            guard !isSymbolicLink(directory), isDirectory(directory) else {
                throw RemoteCodeOrchestrateInstallError.unmanagedCollision(directory.path)
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func relativePath(of item: URL, under root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = item.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath + "/") else {
            throw RemoteCodeOrchestrateInstallError.unsafeRelativePath(itemPath)
        }
        let relativePath = String(itemPath.dropFirst(rootPath.count + 1))
        try validateSafeRelativePath(relativePath)
        return relativePath
    }

    private func validateSafeRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RemoteCodeOrchestrateInstallError.unsafeRelativePath(path)
        }
    }

    private static func parentDirectories(_ path: String) -> [String] {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return [] }
        return (1..<components.count).map { components.prefix($0).joined(separator: "/") }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func pathEntryExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    public func installSkill(
        provider: AgentProvider,
        skillID: String,
        skillText: String,
        sourceURL: String,
        sourceRevision: String,
        localVersion: String,
        installedAt: Date = Date()
    ) throws -> AgentSkillInstallResult {
        let directory = skillDirectory(provider: provider, skillID: skillID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let skillURL = directory.appendingPathComponent("SKILL.md")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = Data(skillText.utf8)
        let checksum = Self.sha256Hex(data)
        let manifest = AgentSkillManifest(
            provider: provider,
            skillID: skillID,
            sourceURL: sourceURL,
            sourceRevision: sourceRevision,
            localVersion: localVersion,
            sha256: checksum,
            installPath: skillURL.path,
            installedAt: installedAt
        )

        if let existingData = try? Data(contentsOf: skillURL),
           Self.sha256Hex(existingData) == checksum,
           let manifestData = try? Data(contentsOf: manifestURL),
           let existingManifest = try? decoder.decode(AgentSkillManifest.self, from: manifestData),
           existingManifest.sourceRevision == sourceRevision,
           existingManifest.localVersion == localVersion {
            return AgentSkillInstallResult(action: .skipped, manifest: existingManifest)
        }

        try data.write(to: skillURL, options: .atomic)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        return AgentSkillInstallResult(action: .installed, manifest: manifest)
    }

    public func uninstallDistillSkill(for provider: AgentProvider) throws -> AgentSkillUninstallResult {
        try uninstallSkill(provider: provider, skillID: Self.distillSkillID)
    }

    public func uninstallDistillInstructions(for provider: AgentProvider) throws -> AgentSkillUninstallResult {
        try removeDistillInstructions(at: instructionsURL(for: provider))
    }

    public func uninstallSkill(provider: AgentProvider, skillID: String) throws -> AgentSkillUninstallResult {
        let directory = skillDirectory(provider: provider, skillID: skillID)
        // Only remove a skill directory we own. The presence of our manifest.json proves
        // RemoteCode installed it, so we never delete a user-authored skill that happens to
        // share the same name in the shared `~/.claude/skills` / `~/.codex/skills` roots.
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .notPresent
        }
        try fileManager.removeItem(at: directory)
        return .removed
    }

    public func skillDirectory(provider: AgentProvider, skillID: String) -> URL {
        skillsRoot(for: provider).appendingPathComponent(skillID, isDirectory: true)
    }

    public func instructionsURL(for provider: AgentProvider) -> URL {
        switch provider {
        case .claude: return claudeInstructionsURL
        case .codex: return codexInstructionsURL
        case .grok:
            return homeDirectoryURL().appendingPathComponent(".grok/AGENTS.md")
        }
    }

    public func distillCLIURL() -> URL {
        cliBinDirectory.appendingPathComponent("distill")
    }

    /// PATH-reachable symlink that bridges the managed CLI into the shell (`~/.local/bin/distill`).
    public func distillPathLinkURL() -> URL {
        pathBinDirectory.appendingPathComponent("distill")
    }

    private func skillsRoot(for provider: AgentProvider) -> URL {
        switch provider {
        case .claude: return claudeSkillsRoot
        case .codex: return codexSkillsRoot
        case .grok:
            return homeDirectoryURL().appendingPathComponent(".grok/skills", isDirectory: true)
        }
    }

    private func homeDirectoryURL() -> URL {
        claudeSkillsRoot
            .deletingLastPathComponent() // .claude
            .deletingLastPathComponent() // home
    }

    /// PERF: nibble table instead of per-byte `String(format:)` so skill package
    /// file checksums and tree digests avoid 32 formatter calls per digest while
    /// keeping the same CryptoKit lowercase hex contract.
    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    public static func sha256Hex(_ data: Data) -> String {
        hexDigest(SHA256.hash(data: data))
    }

    public static func serviceBinaryIdentity(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hexDigest(hasher.finalize())
    }

    /// True for a runtime copy created by runtimeInstaller(for:) whose
    /// content still matches its 64-hex content-addressed namespace.
    ///
    /// The `.remote-code/runtime/<digest>` shape is part of the host-issued
    /// capability, not merely a convenient directory name. A self-hashing
    /// executable in an arbitrary `/tmp/runtime/...` directory must not be
    /// accepted as an interceptor binary.
    public static func isImmutableRuntimeServiceBinary(
        at url: URL,
        trustedRuntimeRoot: URL? = nil
    ) -> Bool {
        guard let trustedRuntimeRoot else {
            return false
        }
        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        guard standardized.lastPathComponent == "RemoteCodeDistillService" else {
            return false
        }
        let components = standardized.pathComponents
        guard let runtimeIndex = components.lastIndex(of: "runtime"),
              components.count == runtimeIndex + 3,
              runtimeIndex > 0,
              components[runtimeIndex - 1] == ".remote-code",
              components[runtimeIndex + 1].count == 64,
              components[runtimeIndex + 1].allSatisfy({ $0.isHexDigit }),
              serviceBinaryIdentity(at: standardized) == components[runtimeIndex + 1]
        else {
            return false
        }
        let actualRoot = standardized.deletingLastPathComponent()
            .standardizedFileURL
        guard actualRoot == trustedRuntimeRoot.standardizedFileURL else {
            return false
        }
        return true
    }

    /// Returns the artifact runtime root only for the host-created managed-bin
    /// shape. Callers must still compare it with the host-issued runtime-root
    /// environment value before forwarding a child capability.
    public static func runtimeRoot(forManagedBin managedBin: String) -> URL? {
        let bin = URL(fileURLWithPath: managedBin).standardizedFileURL
        guard bin.lastPathComponent == "bin" else { return nil }
        let root = bin.deletingLastPathComponent()
        let components = root.pathComponents
        guard root.lastPathComponent.count == 64,
              root.lastPathComponent.allSatisfy({ $0.isHexDigit }),
              components.dropLast().last == "runtime",
              components.dropLast(2).last == ".remote-code" else {
            return nil
        }
        return root
    }

    /// Resolve the immutable service sibling of a host-issued runtime bin.
    /// This is intentionally stricter than searching PATH: a nested provider
    /// may only borrow the artifact namespace already selected by the host.
    public static func immutableRuntimeServiceBinary(
        forManagedBin managedBin: String,
        trustedRuntimeRoot: URL? = nil
    ) -> URL? {
        guard let runtimeRoot = runtimeRoot(forManagedBin: managedBin),
              let trustedRuntimeRoot,
              runtimeRoot == trustedRuntimeRoot.standardizedFileURL else {
            return nil
        }
        let service = runtimeRoot.appendingPathComponent("RemoteCodeDistillService")
        guard isImmutableRuntimeServiceBinary(
            at: service,
            trustedRuntimeRoot: runtimeRoot
        ) else {
            return nil
        }
        return service.standardizedFileURL
    }

    public static func isCurrentOrImmutableRuntimeServiceBinary(
        _ url: URL,
        current: URL? = nil,
        trustedRuntimeRoot: URL? = nil
    ) -> Bool {
        if let trustedRuntimeRoot,
           isImmutableRuntimeServiceBinary(
               at: url,
               trustedRuntimeRoot: trustedRuntimeRoot
           ) {
            return true
        }
        let currentURL = current ?? resolveCurrentServiceBinary()
        guard let currentURL else {
            return false
        }
        // The live service itself is host-issued. Do not accept a byte-identical
        // copy from an arbitrary path as a substitute for its immutable runtime.
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL
        let current = currentURL.resolvingSymlinksInPath().standardizedFileURL
        guard candidate == current,
              FileManager.default.isExecutableFile(atPath: candidate.path),
              let candidateIdentity = serviceBinaryIdentity(at: candidate),
              let currentIdentity = serviceBinaryIdentity(at: current) else {
            return false
        }
        return candidateIdentity == currentIdentity
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    private func upsertDistillInstructions(at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current: String
        if fileManager.fileExists(atPath: url.path) {
            current = try String(contentsOf: url, encoding: .utf8)
        } else {
            current = ""
        }

        let next: String
        if let range = Self.rangeOfDistillInstructionsBlock(in: current) {
            let replaced = current.replacingCharacters(
                in: range,
                with: "\n\n\(Self.distillAgentInstructionsTemplate)\n\n"
            )
            next = "\(replaced.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        } else {
            let prefix = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : "\(current.trimmingTrailingWhitespaceAndNewlines())\n\n"
            next = "\(prefix)\(Self.distillAgentInstructionsTemplate)\n"
        }

        try Data(next.utf8).write(to: url, options: .atomic)
    }

    private func removeDistillInstructions(at url: URL) throws -> AgentSkillUninstallResult {
        guard fileManager.fileExists(atPath: url.path) else {
            return .notPresent
        }
        let current = try String(contentsOf: url, encoding: .utf8)
        guard let range = Self.rangeOfDistillInstructionsBlock(in: current) else {
            return .notPresent
        }

        let next = current.replacingCharacters(in: range, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if next.isEmpty {
            try fileManager.removeItem(at: url)
        } else {
            try Data("\(next)\n".utf8).write(to: url, options: .atomic)
        }
        return .removed
    }

    // PERF: upsert/remove distill instructions recompiled the begin/end block
    // pattern via range(of:options:.regularExpression) on every Token Saver
    // skill install/uninstall. Compile once; match semantics unchanged.
    private static let distillInstructionsBlockRegex: NSRegularExpression = {
        let begin = NSRegularExpression.escapedPattern(for: distillInstructionsBeginMarker)
        let end = NSRegularExpression.escapedPattern(for: distillInstructionsEndMarker)
        return try! NSRegularExpression(
            pattern: "(?:\\n{0,2})?\(begin)[\\s\\S]*?\(end)(?:\\n{0,2})?"
        )
    }()

    private static func rangeOfDistillInstructionsBlock(in text: String) -> Range<String.Index>? {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = distillInstructionsBlockRegex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range, in: text) else { return nil }
        return range
    }

}

/// Errors surfaced by the managed-CLI install path.
public enum AgentSkillCLIError: Error, Sendable, Equatable {
    /// The native RemoteCodeDistillService binary (which also serves CLI mode) could
    /// not be located, so the managed `distill` symlink cannot be installed.
    case serviceBinaryUnavailable
}

private extension URL {
    func ancestorDirectories() -> [URL] {
        var result: [URL] = []
        var current = self
        while true {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        return result
    }
}

private extension String {
    func trimmingTrailingWhitespaceAndNewlines() -> String {
        guard let last = lastIndex(where: { !$0.isWhitespace }) else {
            return ""
        }
        return String(self[...last])
    }
}
