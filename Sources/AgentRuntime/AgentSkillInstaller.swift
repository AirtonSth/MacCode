import CryptoKit
import Foundation
import CoreModel
import Persistence

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
    public static let distillSkillID = "distill"
    public static let distillSourceURL = "remote-code://token-saver/distill-tool-output"
    public static let distillLocalVersion = "10"
    public static let distillInstructionsBeginMarker = "<!-- distill skill: begin -->"
    public static let distillInstructionsEndMarker = "<!-- distill skill: end -->"
    public static let distillCLIBeginMarker = "# RemoteCode managed distill CLI: begin"
    public static let distillCLIEndMarker = "# RemoteCode managed distill CLI: end"
    public static let mcpBeginMarker = "# RemoteCode managed MCP: begin"
    public static let mcpEndMarker = "# RemoteCode managed MCP: end"
    public static let retrieveMCPName = DistillMCPAdmit.codexServerName
    public static let computerUseMCPName = ComputerUseMCPAdmit.serverName
    public static let legacyExternalHostSkillID = "macos-harness"
    /// Environment signal set only for a logical Desktop (This Mac) run. It is
    /// deliberately explicit so Docker, VM, and remote leftovers cannot inherit
    /// the host MCP from a provider's global configuration.
    public static let computerUseHostAdmissionEnvironmentKey = "RC_REMOTE_CODE_COMPUTER_USE_HOST"
    public static let botSelfConfigMCPName = BotSelfConfigMCPAdmit.serverName
    public static let agentAppMiddlewareCommand = "remote-code"
    public static let remoteCodeOrchestrateManifestName = ".remote-code-install.json"
    public static let remoteCodeOrchestrateRuntimeManifestName = "manifest.json"
    public static let remoteCodeOrchestratePinnedPackage = RemoteCodeOrchestratePackage(
        skillID: "remote-code-orchestrate",
        sourceURL: "https://github.com/samuelfaj/sam-skills/tree/main/sam-orchestrate",
        // Upstream base revision; tree digest is recomputed from the embedded package
        // after local contract edits (skill content must stay complete / no Distill-in-skills).
        sourceRevision: "2c77fa48431bc20e5dc841652079594a3ea918c9",
        sourceTreeSHA256: "9d0d615bae2bca280edebfe0ca15bcaf02f2758fbcb8ebd07ee633a988e180b7",
        localVersion: "9",
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
    description: Token Saver policy for compressing noisy command and tool output locally.
    ---

    # Distill tool output

    Distill is not a conversation mode or user command. It only reduces noisy
    command/tool output before that output enters provider context.

    Command-output / exploration policy (Token Saver — Claude + Codex + Grok, primary + nested + subagents):
    - **Coverage first (mandatory for large surveys):** do **not** flood context with native multi-file `read_file` / `grep` / `list_dir` / tree walks. Order:
      1) When `$RC_GRAPHIFY_ENABLED=1` and `$RC_GRAPHIFY_GRAPH_JSON` is set → `graphify query|path|explain` first.
      2) Else / after graph → shell via `run_terminal_command` / Bash using PATH-wrapped tools (`git`, `bun`, `npm`, `find`, `ls`, tests, builds, …) and/or end with `| distill "<question>"`.
      3) Native file tools only for **small, targeted** slices you need byte-exactly (one file, known path, short range).
    - **Why:** Grok/Codex cannot rewrite native tool output (passive/no `updatedToolOutput`). Claude PostToolUse may compress some tools, but shell wrappers + `| distill` maximize measured savings on all three providers. Prefer shell+compress for noisy builds/tests/logs.
    - MANDATORY default-pipe: for **every** non-GUI pipable shell command whose full stdout you do **not** need byte-exactly next, end with `| distill "<question>"` (`pipefail` when exit status matters). If you only need summary / pass-fail / key lines, you MUST pipe.
      Applies to: build, test, lint, install, docker, kubectl, terraform, find, ls, git/gh/glab (including `gh api`, merges, status), package managers, python/bun one-shots, curl/aws/cloud CLIs, compound scripts, CI/logs, and **any other ordinary command** not listed under NEVER below.
      Host PATH wrappers auto-compress **all subcommands** of wrapped binaries (no read-only allowlist) when terminal-to-agent and above threshold — still pipe `| distill` yourself so extraction is explicit. Same policy for primary, nested subagents, and cross-provider orchestration (Claude/Codex/Grok).
    - NEVER auto-distill raw exact-output when you need every match/slice from: \(WrappedCommandCatalog.exactOutputCommands.joined(separator: ", ")); or git grep/show/cat-file/blame.
      Voluntary `rg … | distill "<question>"` (same for grep / git grep) is allowed when the last pipeline command is distill and you want an extractive answer instead of every match line.
      Also skip: GUI / interactive / TUI apps, non-pipable calls, patches/apply, hash/token copy, or RemoteCodeDistillService unavailable.
    - NEVER Distill skill content: Skill tool output and requested/returned SKILL.md bodies are a protected verbatim category — return them complete (no summary, recovery handle, truncation, or savings accounting).
    - Never call Node, tsx, npm, bun, or a source-checkout CLI for `distill`.
    - When you skip `| distill`, state that briefly (e.g. skip: exact sed/rg; skip: GUI; skip: skill). Omitting `| distill` on a non-exact, non-GUI shell command is a policy violation.
    - Applies to primary agents, same-provider subagents, and cross-provider nested launches (Claude↔Codex↔Grok) whenever Token Saver is admitted.
    - Host/runtime carries the ordinary-output Distill policy; do not require every worker prompt to restate it.
    - If a summary includes `[[rc:<handle>]]`, recover exact bytes with `distill retrieve <handle>`.
    - Wait for `distill` before continuing when you did pipe it.

    Local librarian catalog (01-catalogo.html, Token Saver Distill MCP `remotecode-distill` / `remotecode-distill-retrieve`; tools `rc_stats`, `rc_search`, `rc_catalog`, `rc_ask`, `rc_extract`, `rc_digest`, `rc_pick`, `rc_retrieve`, `rc_compress`) — use it by default on every turn, without the user asking, whenever these tools are listed:
    - Use the FULL tool surface, not just one tool: `rc_search` (find stored handles/blobs BEFORE re-deriving or re-reading), `rc_catalog` (discover enabled catalog operations by id/summary), `rc_ask` (run a discovered op over a handle), `rc_compress` (shrink a large blob before quoting it), `rc_retrieve` (byte-exact original behind `[[rc:handle]]` — whole-blob retrieval is the exception, justify it), `rc_stats` (ledger/handle stats).
    - `rc_ask.op` is a catalog function id. Use the eight schema hints for common work; query `rc_catalog` just in time for other extract/digest/classify/rank/diff/grep-in-handle/draft operations, then call the returned id (examples: test_verdict, ci_job_failures, handle_grep, retrieve_range, extract_schema, pick_candidates, cite_spans, multi_handle_ask). Doing one manually on handle-backed content is a policy violation, same as skipping `| distill`.
    - Generate ops run on the Distill model selected in Settings (1.7B / E4B / OpenAI-compatible API).
    - Host-only catalog ops (screenshot_ocr, doc_text_extract, lsp_query, graphify_query, path_wrappers, …) stay on the Mac; if MCP returns unavailable, do not fake success — read the original natively.
    - Forbidden catalog ids (apply_patch, extract_secret_values, …) are refused. Never ask Distill to ship code or leak secrets.
    - Recover `[[rc:handle]]` with `rc_retrieve`.

    Examples:
    - `graphify query "where is mark-as-completed?" --graph "$RC_GRAPHIFY_GRAPH_JSON"`  # when Graphify active
    - `bun test 2>&1 | distill "Did tests pass? Return PASS or FAIL, followed by failing test names if any."`
    - `git log --oneline -50 | distill "Summarize recent commits by theme."`
    - `python3 script.py 2>&1 | distill "What failed? Key errors only."`
    - `rg -n "func applyGraphify" Sources`  # skip distill — need every match line
    - `rg -n "FAIL|error:" .build | distill "Which tests failed? Keep file:line and assertion text."`  # last command is distill — allowed
    - `sed -n '100,180p' Sources/Foo.swift`  # skip distill — need exact slice

    """

    public static let distillAgentInstructionsTemplate = """
    <!-- distill skill: begin -->
    Distill is only for local command/tool-output reduction. It is not a conversation style or user command.
    Token Saver — Claude/Codex/Grok (primary, nested, subagents): large surveys → Graphify query-first when `$RC_GRAPHIFY_GRAPH_JSON` is set, else shell + PATH wrappers / `| distill`. Avoid flooding native multi-file read_file/grep (Grok/Codex cannot rewrite those; Claude PostToolUse helps but shell coverage is higher). Native reads only for small exact slices.
    MANDATORY default-pipe: for **every** non-GUI pipable shell command whose full stdout you do **not** need byte-exactly next, end with `| distill "<question>"` (`pipefail` when exit status matters). If you only need summary/pass-fail/key lines, you MUST pipe. Host PATH wrappers auto-compress all subcommands of wrapped binaries (incl. gh api; no read-only allowlist); still pipe yourself for an explicit extraction question. Applies primary + nested + cross-provider (Claude/Codex/Grok) whenever Token Saver is admitted.
    NEVER auto-distill raw exact-output (need every line): \(WrappedCommandCatalog.exactOutputCommands.joined(separator: ", ")); git grep/show/cat-file/blame. Voluntary `rg … | distill "<question>"` is allowed when the last pipeline command is distill and you want an extractive answer. Also skip patches/hashes/tokens, GUI/interactive/TUI, non-pipable, or service unavailable — state the skip briefly.
    Uniform JSON arrays may arrive as TOON: a header `[N]{fields}` then one comma-separated row per object (nested groups like `temp{min,max}`). Treat those cells as the JSON fields. If you asked for JSON only, the host keeps JSON.
    Omitting `| distill` on a non-exact, non-GUI shell command is a policy violation.
    NEVER Distill skill content: Skill tool output and requested/returned SKILL bodies must stay complete/verbatim (no summary, `[[rc:]]` handle, truncation, or savings accounting).
    Never invoke Node/tsx/npm/bun or a source-checkout `distill`.
    Host/runtime carries the ordinary-output Distill policy; do not require every worker prompt to restate it.
    Distill MCP catalog tools (`rc_stats`, `rc_search`, `rc_catalog`, `rc_ask`, `rc_extract`, `rc_digest`, `rc_pick`, `rc_retrieve`, `rc_compress`) are used BY DEFAULT whenever listed, without the user asking: `rc_search` handles; `rc_catalog` ops; `rc_ask`/`rc_extract`/`rc_digest`/`rc_pick` run them; `rc_compress` blobs; `rc_retrieve` exact bytes. Doing it manually on handle content is a policy violation. Generate uses the Settings model. Host-only may be unavailable — never fake success; forbidden ops are refused. Recover `[[rc:<handle>]]` with `rc_retrieve` or `distill retrieve`. Wait when used.
    Details and examples live in the managed `distill` SKILL.md.
    <!-- distill skill: end -->
    """

    public static let rcWireAgentInstructionsTemplate = """
    REMOTE_CODE_WIRE_V1
    Current RCW1 Q:G/C/K=task,X=handle;RCW1 A:O/A/E/R/Q+"." iff full tokens<=45% of semantically identical terse text;else same text. Keep literals/negation/order/approval;tools native
    """

    public static let compactSpanAgentInstructionsTemplate = """
    REMOTE_CODE_COMPACT_SPAN_V1
    Item RCS1/1 then H decoded_utf8_len dict_utf8_len record_count ref_count; one D escaped span; record_count L or R lines; END. Escapes only \\\\ \\n \\r \\t. Decode the complete item before acting. Concatenate L literals and D for each R in order. Preserve decoded literals/negation/order. Tools remain native
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

    /// Inject managed Token Saver policies into provider runtime prompts (Claude / Codex / Grok)
    /// only while Token Saver is active (`RC_TOKEN_SAVER_DISTILL_HINT=1`).
    /// Token economy is the paid feature: no `| distill` rules, RCW1 ABI, or
    /// safety ABI when the toggle is off.
    public static func tokenSaverProviderPrompt(_ base: String, environment: [String: String]) -> String {
        let routed = nestedAgentProviderPrompt(base, environment: environment)
        var withDistill: String
        if environment["RC_TOKEN_SAVER_DISTILL_HINT"] == "1" {
            withDistill = managedDistillProviderPrompt(routed)
        } else {
            withDistill = routed
        }
        if environment[TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey] == "1",
           !withDistill.contains(rcWireAgentInstructionsTemplate) {
            withDistill += "\n\n" + rcWireAgentInstructionsTemplate
        }
        if environment[TokenSaverExecutionReceiptSeam.compactSpanCapabilityEnvKey] == "1",
           environment[TokenSaverExecutionReceiptSeam.compactSpanVersionEnvKey] == "1",
           !withDistill.contains(compactSpanAgentInstructionsTemplate) {
            withDistill += "\n\n" + compactSpanAgentInstructionsTemplate
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
        let rewritten = ensuringClaudePostToolUseSettings(
            provider: provider,
            arguments: arguments,
            environment: environment
        )

        let prompt = tokenSaverProviderPrompt("", environment: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              isSupportedProviderTurn(provider: provider, arguments: rewritten)
        else {
            return ensuringCodexProcessMCPOverlays(
                provider: provider,
                arguments: rewritten,
                environment: environment
            )
        }

        switch provider {
        case .grok:
            return mergingProviderPrompt(
                prompt,
                option: "--rules",
                provider: provider,
                arguments: rewritten
            )
        case .distill:
            return rewritten
        case .claude:
            return mergingProviderPrompt(
                prompt,
                option: "--append-system-prompt",
                provider: provider,
                arguments: rewritten
            )
        case .codex:
            let withInstructions: [String]
            let scan = scanProviderArguments(provider: provider, arguments: rewritten)
            guard !scan.malformed else {
                return ensuringCodexProcessMCPOverlays(
                    provider: provider,
                    arguments: rewritten,
                    environment: environment
                )
            }
            let configValues = (scan.optionValues["--config"] ?? [])
                + (scan.optionValues["-c"] ?? [])
            let hasDeveloperOverride = configValues.contains {
                codexDeveloperInstructionsAssignment($0) != nil
            }
            if hasDeveloperOverride {
                withInstructions = mergingCodexDeveloperInstructions(
                    prompt,
                    arguments: rewritten
                )
            } else {
                let quoted = "\""
                    + prompt
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                    + "\""
                withInstructions = ["--config", "developer_instructions=\(quoted)"] + rewritten
            }
            return ensuringCodexProcessMCPOverlays(
                provider: provider,
                arguments: withInstructions,
                environment: environment
            )
        }
    }

    /// Raw nested Codex invocations do not pass through `CodexRunner` or the
    /// app-server adapter. Admit the same four bot MCPs on the process argv so
    /// `codex exec resume` and other strict/raw turns retain the host catalog
    /// without consulting the shared `~/.codex/config.toml`, plus the Token
    /// Saver librarian (with the run's recovery scope) under its own gate.
    static func ensuringCodexProcessMCPOverlays(
        provider: AgentProvider,
        arguments: [String],
        environment: [String: String]
    ) -> [String] {
        guard provider == .codex else { return arguments }
        let subcommandIndex: Int? = {
            var index = 0
            let valueOptions: Set<String> = [
                "--config", "-c", "--model", "-m", "--sandbox", "-s",
                "--ask-for-approval", "-a", "--image", "-i", "--color",
                "--cd", "-C", "--profile", "-p",
            ]
            let flagOptions: Set<String> = [
                "--dangerously-bypass-approvals-and-sandbox", "--ephemeral",
                "--full-auto", "--ignore-user-config", "--json", "--oss",
                "--search", "--skip-git-repo-check", "--strict-config",
            ]
            while index < arguments.count {
                let argument = arguments[index]
                if valueOptions.contains(argument) {
                    guard index + 1 < arguments.count else { return nil }
                    index += 2
                    continue
                }
                if valueOptions.contains(where: { argument.hasPrefix("\($0)=") }) {
                    index += 1
                    continue
                }
                if flagOptions.contains(argument) {
                    index += 1
                    continue
                }
                return argument == "exec" || argument == "app-server" ? index : nil
            }
            return nil
        }()
        guard let subcommandIndex else {
            return arguments
        }
        let names = [
            BotSelfConfigMCPAdmit.serverName,
            BotBrowserMCPAdmit.serverName,
            BotComputerMCPAdmit.serverName,
            BotWebMCPAdmit.serverName,
        ]
        let callerIsScoped = environment[BotSelfConfigCatalog.callerEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasManagedCommand = { (name: String) in
            arguments.contains { $0.contains("mcp_servers.\(name).command=") }
        }
        let hasScopedBotID = { (name: String) in
            arguments.contains { $0.contains("mcp_servers.\(name).env.\(BotSelfConfigCatalog.callerEnvironmentKey)=") }
        }
        var overrides: [String] = []
        if names.contains(where: { !hasManagedCommand($0) || (callerIsScoped && !hasScopedBotID($0)) }) {
            overrides += CodexRunner.botCatalogMCPOverrides(environment: environment)
        }
        // The librarian keeps its own presence check and its own Token Saver
        // gate (`distillMCPOverrides` returns [] when the hint is absent), so a
        // raw argv that already pinned the bot catalog still receives the
        // librarian overlay, and a Token Saver-off run still receives neither.
        if !hasManagedCommand(DistillMCPAdmit.codexServerName) {
            overrides += CodexRunner.distillMCPOverrides(environment: environment)
        }
        guard !overrides.isEmpty else { return arguments }
        switch arguments[subcommandIndex] {
        case "exec":
            // Prompt injection intentionally excludes resumed sessions, but the
            // process-scoped MCP catalog must survive `codex exec resume` after
            // the legacy global config entry is stripped. Administrative,
            // version, and unknown-option invocations still remain exact.
            guard isSupportedCodexExecMCPInvocation(
                arguments: arguments,
                callerIsScoped: callerIsScoped
            ) else {
                return arguments
            }
        case "app-server":
            guard isSupportedCodexAppServerInvocation(
                arguments: arguments,
                subcommandIndex: subcommandIndex
            ) else {
                return arguments
            }
        default:
            return arguments
        }

        // `exec` may have global `--config`/Token Saver options in front of
        // it. Place the overlay before that subcommand so the original skill
        // ABI remains the suffix. A bare app-server/raw exec keeps its
        // subcommand first, which is required by Codex's protocol adapter.
        let insertionIndex: Int
        if subcommandIndex == arguments.startIndex {
            let afterSubcommand = arguments.index(after: subcommandIndex)
            if arguments[subcommandIndex] == "exec",
               afterSubcommand < arguments.endIndex,
               arguments[afterSubcommand] == "resume" {
                insertionIndex = arguments.index(after: afterSubcommand)
            } else {
                insertionIndex = afterSubcommand
            }
        } else {
            insertionIndex = subcommandIndex
        }
        return Array(arguments[..<insertionIndex])
            + overrides
            + Array(arguments[insertionIndex...])
    }

    private static func isSupportedCodexExecMCPInvocation(
        arguments: [String],
        callerIsScoped: Bool
    ) -> Bool {
        let scan = scanProviderArguments(provider: .codex, arguments: arguments)
        guard !scan.malformed,
              scan.positionals.first == "exec",
              scan.flags.isDisjoint(with: ["--version", "-V", "--help", "-h"])
        else {
            return false
        }
        // An unscoped resume is still an administrative/session-control ABI.
        // A bot-scoped resume is the A-005 nested path that previously relied
        // on the now-removed global MCP configuration.
        return scan.positionals.dropFirst().first != "resume" || callerIsScoped
    }

    private static func isSupportedCodexAppServerInvocation(
        arguments: [String],
        subcommandIndex: Int
    ) -> Bool {
        let valueOptions: Set<String> = [
            "-c", "--config", "--listen", "--code-mode-host", "--enable", "--disable",
            "--ws-auth", "--ws-token-file", "--ws-token-sha256", "--ws-shared-secret-file",
            "--ws-issuer", "--ws-audience", "--ws-max-clock-skew-seconds",
        ]
        let flagOptions: Set<String> = ["--stdio", "--analytics-default-enabled"]
        var index = arguments.index(after: subcommandIndex)
        while index < arguments.endIndex {
            let argument = arguments[index]
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.endIndex else { return false }
                index += 2
                continue
            }
            if valueOptions.contains(where: { argument.hasPrefix("\($0)=") }) {
                index += 1
                continue
            }
            if flagOptions.contains(argument) {
                index += 1
                continue
            }
            // Do not rewrite `app-server --help`/`--version` or an option
            // introduced by a newer Codex without knowing its ABI.
            return false
        }
        return true
    }

    /// Inject Claude CLI `--settings` PostToolUse hooks on the raw provider-proxy
    /// path when Token Saver has admitted the Claude PostToolUse lane.
    ///
    /// Fail-open rules:
    /// - Non-Claude providers: unchanged.
    /// - Flag absent / not admitted: unchanged (byte-identical argv).
    /// - Administrative / unsupported turns: unchanged.
    /// - Caller `--settings`: merge in memory; never edit the caller's file.
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
        // Distill-only map so nested proxy merge does not pull filesystem hooks
        // into the caller argv. Agent App streaming path merges those separately.
        guard let ptuHooks = ClaudeRunner.tokenSaverDistillHookSettings(environment: environment) else {
            return arguments
        }
        let settingsArgs = ClaudeRunner.ultracodeSettingsArgs(nil, environment: environment)
        // Merge into the effective (last) inline JSON or JSON settings file.
        // The caller's file is never edited; path-form becomes an equivalent
        // inline object at the same argv position. Both `--settings value` and
        // `--settings=value` are supported by the Claude CLI.
        enum SettingsLocation {
            case separate(valueIndex: Int)
            case inline(argumentIndex: Int)
        }
        let boundary = arguments.firstIndex(of: "--") ?? arguments.endIndex
        var effectiveSettings: (location: SettingsLocation, value: String)?
        var scanIndex = 0
        while scanIndex < boundary {
            let argument = arguments[scanIndex]
            if argument == "--settings" {
                guard scanIndex + 1 < boundary else { return arguments }
                effectiveSettings = (.separate(valueIndex: scanIndex + 1), arguments[scanIndex + 1])
                scanIndex += 2
                continue
            }
            if argument.hasPrefix("--settings=") {
                effectiveSettings = (
                    .inline(argumentIndex: scanIndex),
                    String(argument.dropFirst("--settings=".count))
                )
            }
            scanIndex += 1
        }
        if let effectiveSettings {
            let existing = effectiveSettings.value
            let existingData: Data? = {
                if existing.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                    return existing.data(using: .utf8)
                }
                return FileManager.default.contents(atPath: existing)
            }()
            if let existingData,
               var existingObject = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                var hooks = existingObject["hooks"] as? [String: Any] ?? [:]
                let existingPost = hooks["PostToolUse"] as? [[String: Any]] ?? []
                let requiredPost = ptuHooks["PostToolUse"] as? [[String: Any]] ?? []
                let existingJSON = (try? JSONSerialization.data(
                    withJSONObject: existingPost,
                    options: [.sortedKeys]
                )).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let mergedPost = existingJSON.contains("distill hook post-tool-use")
                    ? existingPost
                    : existingPost + requiredPost
                if !mergedPost.isEmpty {
                    hooks["PostToolUse"] = mergedPost
                    existingObject["hooks"] = hooks
                    if let merged = try? JSONSerialization.data(
                        withJSONObject: existingObject,
                        options: [.sortedKeys]
                    ),
                       let mergedJSON = String(data: merged, encoding: .utf8) {
                        var out = arguments
                        switch effectiveSettings.location {
                        case .separate(let valueIndex):
                            out[valueIndex] = mergedJSON
                        case .inline(let argumentIndex):
                            out[argumentIndex] = "--settings=" + mergedJSON
                        }
                        return out
                    }
                }
            }
            // Unknown/non-JSON settings remain byte-identical (fail open).
            return arguments
        }
        return settingsArgs + arguments
    }

    private static func mergingCodexDeveloperInstructions(
        _ prompt: String,
        arguments: [String]
    ) -> [String] {
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        enum OverrideLocation {
            case separate(valueIndex: Int)
            case inline(argumentIndex: Int, option: String)
        }
        var effectiveOverride: (
            location: OverrideLocation,
            assignment: CodexDeveloperInstructionsAssignment
        )?
        let boundary = arguments.firstIndex(of: "--") ?? arguments.endIndex
        var index = 0
        while index < boundary {
            let argument = arguments[index]
            if argument == "--config" || argument == "-c" {
                guard index + 1 < boundary else { return arguments }
                let value = arguments[index + 1]
                if let assignment = codexDeveloperInstructionsAssignment(value) {
                    effectiveOverride = (
                        .separate(valueIndex: index + 1),
                        assignment
                    )
                }
                index += 2
                continue
            }
            if let option = ["--config", "-c"].first(where: {
                argument.hasPrefix("\($0)=")
            }) {
                let value = String(argument.dropFirst(option.count + 1))
                if let assignment = codexDeveloperInstructionsAssignment(value) {
                    effectiveOverride = (
                        .inline(argumentIndex: index, option: option),
                        assignment
                    )
                }
            }
            index += 1
        }
        guard let effectiveOverride else { return arguments }
        let encoded = effectiveOverride.assignment.encoded
        if encoded.contains("TOKEN_SAVER_SAFETY_ABI_V1") {
            return arguments
        }
        let delimiter: String
        if encoded.hasPrefix("\"\"\"") && encoded.hasSuffix("\"\"\"") {
            delimiter = "\"\"\""
        } else if encoded.hasPrefix("'''") && encoded.hasSuffix("'''") {
            delimiter = "'''"
        } else if encoded.hasPrefix("\"") && encoded.hasSuffix("\"") {
            delimiter = "\""
        } else if encoded.hasPrefix("'") && encoded.hasSuffix("'") {
            delimiter = "'"
        } else {
            // Codex accepts an unquoted fallback value and gives the last
            // override precedence. Treat it as caller text, then canonicalize
            // the merged result to a TOML basic string.
            delimiter = ""
        }
        let body = delimiter.isEmpty
            ? encoded
            : String(encoded.dropFirst(delimiter.count).dropLast(delimiter.count))
        let mergedEncoded: String
        if delimiter.isEmpty || delimiter.hasPrefix("'") {
            // TOML literal strings do not interpret \n or escaping. Re-encode
            // their semantic value as a basic string before appending policy.
            let escapedBody = body
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            mergedEncoded = "\"" + escapedBody + "\\n\\n" + escapedPrompt + "\""
        } else {
            mergedEncoded = delimiter + body + "\\n\\n" + escapedPrompt + delimiter
        }
        let value = "developer_instructions=" + mergedEncoded
            + effectiveOverride.assignment.trailingComment
        var merged = arguments
        switch effectiveOverride.location {
        case .separate(let valueIndex):
            merged[valueIndex] = value
        case .inline(let argumentIndex, let option):
            merged[argumentIndex] = option + "=" + value
        }
        return merged
    }

    /// Decode only the TOML assignment shape that Codex treats as its effective
    /// developer prompt. Values remain encoded so merging can preserve basic vs
    /// multiline semantics without implementing a general TOML parser.
    private struct CodexDeveloperInstructionsAssignment {
        let encoded: String
        let trailingComment: String
    }

    private static func codexDeveloperInstructionsAssignment(
        _ configuration: String
    ) -> CodexDeveloperInstructionsAssignment? {
        guard let equals = configuration.firstIndex(of: "=") else { return nil }
        let key = configuration[..<equals]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard key == "developer_instructions" else { return nil }
        let rawValue = configuration[configuration.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let (encoded, comment) = splitCodexTOMLValueAndComment(rawValue)
        guard !encoded.isEmpty else { return nil }
        return CodexDeveloperInstructionsAssignment(
            encoded: encoded,
            trailingComment: comment.map { " # " + $0 } ?? ""
        )
    }

    /// Split a single TOML value from a trailing comment without treating `#`
    /// inside basic, literal, or multiline strings as comment syntax.
    private static func splitCodexTOMLValueAndComment(
        _ rawValue: String
    ) -> (value: String, comment: String?) {
        let characters = Array(rawValue)
        var index = 0
        var quote: Character?
        var tripleQuoted = false
        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if activeQuote == "\"", character == "\\", !tripleQuoted {
                    index = min(index + 2, characters.count)
                    continue
                }
                if character == activeQuote {
                    if tripleQuoted {
                        if index + 2 < characters.count,
                           characters[index + 1] == activeQuote,
                           characters[index + 2] == activeQuote {
                            quote = nil
                            tripleQuoted = false
                            index += 3
                            continue
                        }
                    } else {
                        quote = nil
                    }
                }
                index += 1
                continue
            }
            if character == "#" {
                let value = String(characters[..<index])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let comment = String(characters[(index + 1)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (value, comment)
            }
            if character == "\"" || character == "'" {
                quote = character
                tripleQuoted = index + 2 < characters.count
                    && characters[index + 1] == character
                    && characters[index + 2] == character
                index += tripleQuoted ? 3 : 1
                continue
            }
            index += 1
        }
        return (rawValue.trimmingCharacters(in: .whitespacesAndNewlines), nil)
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
        case .distill:
            return false
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
        case .distill:
            return false
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
                "--session-id", "--resume", "-r", "--mcp-config"
            ]
        case .distill:
            return []
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
        case .distill:
            return []
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
        return TokenSaverProviderSafetyABI.appendingExactlyOnce(to: withDistill, enabled: true)
    }

    /// App-private Distill package directory (mirrors remote-code-orchestrate layout).
    public func distillAppPrivateDirectory() -> URL {
        appPrivateSkillsRoot.appendingPathComponent(Self.distillSkillID, isDirectory: true)
    }

    /// Install Distill into RemoteCode Application Support only — never into
    /// `~/.claude/skills`, `~/.codex/skills`, or `~/.grok/skills`.
    @discardableResult
    public func installAppPrivateDistillSkill(
        sourceRevision: String = "remote-code-native-wire-v1",
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
        if let existingData = try? Data(contentsOf: skillURL, options: .mappedIfSafe),
           Self.sha256Hex(existingData) == checksum,
           let manifestData = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
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

    /// Remove only artifacts that the pre-native RemoteCode installer owned.
    /// A manifest source check protects a user-authored skill with the same id;
    /// the managed-bin entry is always app-owned and may be removed when it is
    /// a symlink to that legacy executable.
    public func uninstallLegacyExternalHostArtifacts() throws {
        let legacySourceURL = "https://github.com/browser-use/" + Self.legacyExternalHostSkillID
        for provider in AgentProvider.allCases {
            let directory = skillDirectory(provider: provider, skillID: Self.legacyExternalHostSkillID)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
                  let manifest = try? decoder.decode(AgentSkillManifest.self, from: data),
                  manifest.sourceURL == legacySourceURL else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
        let managedLink = cliBinDirectory.appendingPathComponent(Self.legacyExternalHostSkillID)
        guard isSymbolicLink(managedLink),
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: managedLink.path),
              destination.contains(Self.legacyExternalHostSkillID) else {
            return
        }
        try? fileManager.removeItem(at: managedLink)
    }

    private let claudeSkillsRoot: URL
    private let codexSkillsRoot: URL
    private let claudeInstructionsURL: URL
    private let codexInstructionsURL: URL
    private let cliBinDirectory: URL
    private let pathBinDirectory: URL
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

    public var providerShellBridgeURL: URL {
        cliBinDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("shell/zsh", isDirectory: true)
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
        linkManagedDistillOntoPath(target: url)
        // Second path-bridge pass: if ~/.local/bin/distill still missing (first
        // attempt failed on a race), retry once.
        if !fileManager.fileExists(atPath: distillPathLinkURL().path) {
            linkManagedDistillOntoPath(target: url)
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

    private func resolveServiceBinaryForManagedInstall(preferred: URL?) throws -> URL {
        if let preferred, fileManager.isExecutableFile(atPath: preferred.path) {
            return preferred.resolvingSymlinksInPath()
        }
        let usesProductionManagedBin = cliBinDirectory.standardizedFileURL.path
            == Self.defaultManagedCLIBinDirectory().standardizedFileURL.path
        if usesProductionManagedBin {
            // A running app bundle is authoritative. Recovering the shared
            // wrapper first let an older concurrently-running build repoint the
            // current app back to its stale service binary.
            if let resolved = Self.resolveServiceBinary(fileManager: fileManager),
               fileManager.isExecutableFile(atPath: resolved.path) {
                return resolved.resolvingSymlinksInPath()
            }
            if let recovered = recoverServiceBinaryFromManagedWrappers() {
                return recovered
            }
        } else {
            // Sandboxed/custom homes must not pick up a process-global build.
            if let recovered = recoverServiceBinaryFromManagedWrappers() {
                return recovered
            }
            if let resolved = Self.resolveServiceBinary(fileManager: fileManager),
               fileManager.isExecutableFile(atPath: resolved.path) {
                return resolved.resolvingSymlinksInPath()
            }
        }
        throw AgentSkillCLIError.serviceBinaryUnavailable
    }

    /// When the app bundle path changed or Bundle.main is wrong, recover the
    /// service binary from any remaining healthy managed symlink for this user.
    private func recoverServiceBinaryFromManagedWrappers() -> URL? {
        var names = ["claude", "codex", "grok", "git", "npm", "remote-code", "ls", "distill"]
        names.append(contentsOf: WrappedCommandCatalog.commands)
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
           let text = (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap { String(data: $0, encoding: .utf8) },
           text.contains(Self.distillCLIBeginMarker),
           text.contains(Self.distillCLIEndMarker) {
            try fileManager.removeItem(at: url)
            return .removed
        }
        return .notPresent
    }

    /// Install the global interceptor symlink for every executable command visible on the
    /// system PATH in the managed bin dir (`~/.remote-code/bin`, PREPENDED to the agent PATH
    /// only). Exact-output tools (sed, rg, grep, cat, …) are intercepted but pass through raw
    /// stdout by policy. Provider basenames and shebang interpreters stay on their native paths.
    /// Provider basenames (`grok`/`claude`/`codex`) are **not** part of this catalog —
    /// see `installProviderProxies()`.
    /// - Parameter searchDirectoriesOverride: effective provider/workspace PATH directories.
    @discardableResult
    public func installCommandWrappers(
        serviceBinaryURL: URL? = nil,
        searchDirectoriesOverride: [String]? = nil
    ) throws -> [String] {
        try fileManager.createDirectory(at: cliBinDirectory, withIntermediateDirectories: true)
        guard let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager) else {
            throw AgentSkillCLIError.serviceBinaryUnavailable
        }
        // Drop leftover Distill symlinks that are not catalog wrappers or
        // always-on controllers. A stray `node` wrapper makes
        // `#!/usr/bin/env node` (Homebrew Codex) start the sidecar instead.
        _ = try pruneUnmanagedManagedBinSymlinks(
            keeping: reservedManagedBinBasenames(includingCommandWrappers: true),
            serviceBinaryURL: binary
        )
        let searchDirectories = (searchDirectoriesOverride ?? systemCommandSearchDirectories())
            .filter { !$0.isEmpty && $0 != cliBinDirectory.path }
        var candidates = WrappedCommandCatalog.commands
        for directory in searchDirectories {
            let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
            candidates.append(contentsOf: names.sorted())
        }
        var seen = Set<String>()
        var installed: [String] = []
        for command in candidates {
            guard seen.insert(command).inserted,
                  !command.isEmpty,
                  !command.contains("/"),
                  !WrappedCommandCatalog.isShebangInterpreter(command),
                  !ProviderProxyCatalog.providerSet.contains(command),
                  command != "distill",
                  command != "remote-code",
                  command != "rc-retrieve-mcp"
            else { continue }
            guard commandExistsOnSystem(command, searchDirectories: searchDirectories) else { continue }
            let link = cliBinDirectory.appendingPathComponent(command)
            if let dest = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
                if dest == binary.path { installed.append(command); continue }
                try? fileManager.removeItem(at: link) // replace a stale managed symlink
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

    /// Remove the command-wrapper symlinks — but only those still pointing at our service binary,
    /// so a user's own command on the managed path (unexpected) is never deleted.
    /// Includes legacy exact-output basenames so Token Saver off cleans old sed/rg wrappers.
    /// Does **not** remove nested provider proxies (`installProviderProxies`).
    @discardableResult
    public func uninstallCommandWrappers(
        serviceBinaryURL: URL? = nil
    ) throws -> [String] {
        let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager)
        let removedCatalog = try removeManagedWrapperSymlinks(
            basenames: WrappedCommandCatalog.symlinkBasenamesToRemove,
            binaryURL: binary
        )
        let removedExtras = try pruneUnmanagedManagedBinSymlinks(
            keeping: reservedManagedBinBasenames(includingCommandWrappers: false),
            serviceBinaryURL: binary
        )
        var seen = Set<String>()
        var ordered: [String] = []
        for name in removedCatalog + removedExtras where seen.insert(name).inserted {
            ordered.append(name)
        }
        return ordered
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
        searchDirectoriesOverride: [String]? = nil
    ) throws -> [String] {
        try fileManager.createDirectory(at: cliBinDirectory, withIntermediateDirectories: true)
        guard let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager) else {
            throw AgentSkillCLIError.serviceBinaryUnavailable
        }
        let searchDirectories = searchDirectoriesOverride ?? systemCommandSearchDirectories()
        var installed: [String] = []
        for command in ProviderProxyCatalog.providers {
            guard commandExistsOnSystem(command, searchDirectories: searchDirectories) else { continue }
            let link = cliBinDirectory.appendingPathComponent(command)
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                if symbolicLink(at: link, pointsTo: binary) {
                    installed.append(command)
                    continue
                }
                guard isRecognizedRemoteCodeServiceSymlink(link) else {
                    // A same-basename target alone is not ownership evidence.
                    // Preserve foreign aliases even inside the managed directory.
                    continue
                }
                try fileManager.removeItem(at: link)
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
        serviceBinaryURL: URL? = nil
    ) throws -> URL? {
        try fileManager.createDirectory(at: cliBinDirectory, withIntermediateDirectories: true)
        guard let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager) else {
            throw AgentSkillCLIError.serviceBinaryUnavailable
        }
        let link = cliBinDirectory.appendingPathComponent(Self.agentAppMiddlewareCommand)
        if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
            if symbolicLink(at: link, pointsTo: binary) {
                return link
            }
            guard isRecognizedRemoteCodeServiceSymlink(link) else {
                // A symlink to any unrecognized target is user-owned.
                return nil
            }
            try fileManager.removeItem(at: link)
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
        serviceBinaryURL: URL? = nil
    ) -> URL? {
        let link = cliBinDirectory.appendingPathComponent(Self.agentAppMiddlewareCommand)
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
            let body = """
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
              export PATH
            fi
            """
            try Data((body + "\n").utf8).write(
                to: directory.appendingPathComponent(fileName),
                options: .atomic
            )
        }
        return directory
    }

    /// Remove provider-proxy symlinks that still point at our service binary only.
    @discardableResult
    public func uninstallProviderProxies(
        serviceBinaryURL: URL? = nil
    ) throws -> [String] {
        guard let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager)
        else {
            return []
        }
        var removed: [String] = []
        for command in ProviderProxyCatalog.providers {
            let link = cliBinDirectory.appendingPathComponent(command)
            guard symbolicLink(at: link, pointsTo: binary) else { continue }
            try fileManager.removeItem(at: link)
            removed.append(command)
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

    private func resolvedSymbolicLinkDestination(
        _ rawDestination: String,
        relativeTo link: URL
    ) -> URL {
        rawDestination.hasPrefix("/")
            ? URL(fileURLWithPath: rawDestination)
            : link.deletingLastPathComponent().appendingPathComponent(rawDestination)
    }

    /// Managed aliases survive app moves and isolated build directories. Repair
    /// only targets whose path shape identifies a RemoteCode build, bundle, or
    /// content-addressed runtime; a same-named arbitrary executable stays foreign.
    private func isRecognizedRemoteCodeServiceSymlink(_ link: URL) -> Bool {
        guard let rawDestination = try? fileManager.destinationOfSymbolicLink(
            atPath: link.path
        ) else {
            return false
        }
        let destination = resolvedSymbolicLinkDestination(
            rawDestination,
            relativeTo: link
        ).standardizedFileURL
        guard destination.lastPathComponent == "RemoteCodeDistillService" else {
            return false
        }
        let path = destination.path
        return path.contains("/RemoteCode.app/Contents/MacOS/")
            || isRemoteCodeAppBundleService(destination)
            || path.contains("/.build/")
            || path.contains("/Build/Products/")
            || path.contains("/.remote-code/runtime/")
            || path.contains("/remote-code-macos-la-bootstrap-")
    }

    /// Development and canary builds may use a product name other than
    /// `RemoteCode.app`. The bundle identifier is the stable ownership marker;
    /// relying on the product name stranded managed aliases on an older build.
    private func isRemoteCodeAppBundleService(_ destination: URL) -> Bool {
        let macOSDirectory = destination.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        let appBundle = contentsDirectory.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS",
              contentsDirectory.lastPathComponent == "Contents",
              appBundle.pathExtension == "app",
              let plistData = fileManager.contents(
                atPath: contentsDirectory.appendingPathComponent("Info.plist").path
              ),
              let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
              ) as? [String: Any],
              let bundleIdentifier = plist["CFBundleIdentifier"] as? String
        else {
            return false
        }
        return bundleIdentifier == "io.remotecode.desktop"
            || bundleIdentifier.hasPrefix("io.remotecode.desktop.")
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

    /// Basenames that may keep a Distill symlink in the managed bin.
    func reservedManagedBinBasenames(includingCommandWrappers: Bool) -> Set<String> {
        var names = Set(ProviderProxyCatalog.providers)
        names.insert(Self.agentAppMiddlewareCommand)
        names.insert("distill")
        names.insert("rc-retrieve-mcp")
        if includingCommandWrappers {
            for command in WrappedCommandCatalog.commands where !WrappedCommandCatalog.isShebangInterpreter(command) {
                names.insert(command)
            }
        }
        return names
    }

    /// Remove Distill-owned symlinks that are not in `reserved`.
    /// Never deletes a regular file or a symlink that points elsewhere.
    /// Ownership is the target name (`RemoteCodeDistillService`), not a single
    /// build path — leftovers from a relocated app still shadow `node`.
    @discardableResult
    public func pruneUnmanagedManagedBinSymlinks(
        keeping reserved: Set<String>,
        serviceBinaryURL: URL? = nil
    ) throws -> [String] {
        _ = serviceBinaryURL
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cliBinDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var removed: [String] = []
        for url in entries {
            let name = url.lastPathComponent
            if reserved.contains(name) { continue }
            guard isRemoteCodeDistillServiceSymlink(url) else { continue }
            try fileManager.removeItem(at: url)
            removed.append(name)
        }
        return removed
    }

    private func isRemoteCodeDistillServiceSymlink(_ link: URL) -> Bool {
        guard let dest = resolvedSymlinkTarget(at: link) else { return false }
        return dest.lastPathComponent == "RemoteCodeDistillService"
            || dest.path.contains("RemoteCodeDistillService")
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
        // PERF: single pass avoids the map + filter intermediates on the
        // install path; kept directories identical.
        var kept: [String] = []
        for part in joined.split(separator: ":") where !part.isEmpty && part != managed {
            kept.append(String(part))
        }
        return kept
    }

    private func commandExistsOnSystem(_ command: String, searchDirectories: [String]) -> Bool {
        for dir in searchDirectories {
            if fileManager.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(command)) {
                return true
            }
        }
        return false
    }

    private func claudeSettingsURL() -> URL {
        claudeInstructionsURL.deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    private func codexConfigURL() -> URL {
        codexInstructionsURL.deletingLastPathComponent().appendingPathComponent("config.toml")
    }

    /// Install the librarian MCP server (`RemoteCodeDistillService mcp`) into Codex
    /// config.toml as the file-level fallback. Idempotent; preserves any
    /// user-authored entries. RemoteCode-spawned Codex turns get the same
    /// server per process instead (`CodexRunner.distillMCPOverrides`, which
    /// also carries the run's recovery scope and replaces this table by name);
    /// Claude does NOT read `mcpServers` from settings.json (an installed entry
    /// never spawned and `claude mcp list` omits it), so both Claude engines
    /// admit the server per spawn instead
    /// (ClaudeRunner.botPeerMCPConfigJSON / ClaudeAgentSDKBridgeAdapter.botPeerMCPServers),
    /// and Grok admits it per ACP session (GrokACPClient.sessionMCPServers).
    /// `uninstallRetrieveMCP` still purges the legacy Claude settings.json entry.
    public func installRetrieveMCP(serviceBinaryURL: URL? = nil) throws {
        guard let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager) else {
            throw AgentSkillCLIError.serviceBinaryUnavailable
        }
        try installCodexRetrieveMCP(binary: binary)
    }

    /// Admit the host-queued computer-use MCP into Claude and Codex configs.
    /// Idempotent; leftover / user-authored servers stay. Not Token Saver gated.
    public func installComputerUseMCP(serviceBinaryURL: URL? = nil) throws {
        guard let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager) else {
            throw AgentSkillCLIError.serviceBinaryUnavailable
        }
        try installClaudeComputerUseMCP(binary: binary)
        try installCodexComputerUseMCP(binary: binary)
    }

    /// One managed bot MCP older installers persisted into the shared configs.
    private struct ManagedBotMCPResidue {
        let serverName: String
        let tomlBeginMarker: String
        let tomlEndMarker: String
    }

    private static let selfConfigMCPResidue = ManagedBotMCPResidue(
        serverName: BotSelfConfigMCPAdmit.serverName,
        tomlBeginMarker: BotSelfConfigMCPAdmit.tomlBeginMarker,
        tomlEndMarker: BotSelfConfigMCPAdmit.tomlEndMarker
    )
    private static let browserMCPResidue = ManagedBotMCPResidue(
        serverName: BotBrowserMCPAdmit.serverName,
        tomlBeginMarker: BotBrowserMCPAdmit.tomlBeginMarker,
        tomlEndMarker: BotBrowserMCPAdmit.tomlEndMarker
    )
    private static let computerMCPResidue = ManagedBotMCPResidue(
        serverName: BotComputerMCPAdmit.serverName,
        tomlBeginMarker: BotComputerMCPAdmit.tomlBeginMarker,
        tomlEndMarker: BotComputerMCPAdmit.tomlEndMarker
    )
    private static let webMCPResidue = ManagedBotMCPResidue(
        serverName: BotWebMCPAdmit.serverName,
        tomlBeginMarker: BotWebMCPAdmit.tomlBeginMarker,
        tomlEndMarker: BotWebMCPAdmit.tomlEndMarker
    )

    /// Strip every managed bot MCP residue in a single pass over the shared
    /// configs. The per-server entry points each opened and scanned both files,
    /// so running them back to back read `~/.claude/settings.json` and
    /// `~/.codex/config.toml` four times on the pre-turn path. This pass leaves
    /// the same bytes (the removals are idempotent and target disjoint entries)
    /// and rewrites each file at most once.
    public func stripManagedBotMCPResidue() throws {
        try stripManagedBotMCPResidue([
            Self.selfConfigMCPResidue,
            Self.browserMCPResidue,
            Self.computerMCPResidue,
            Self.webMCPResidue,
        ])
    }

    private func stripManagedBotMCPResidue(_ residues: [ManagedBotMCPResidue]) throws {
        try stripClaudeManagedMCP(serverNames: residues.map(\.serverName))
        try stripCodexManagedMCP(residues: residues)
    }

    /// Bot catalog MCP is per-process on every provider:
    /// Claude `--mcp-config` / SDK `mcp_servers`, Codex `-c`, Grok ACP `session/new`.
    /// `~/.claude/settings.json` is a dead location (`claude mcp list` omits it;
    /// Distill retrieve already stopped writing there). `~/.codex/config.toml` is
    /// shared with ChatGPT.app and leaks one stdio child per conversation.
    /// Grok never had a global file. Install strips legacy Claude/Codex entries.
    public func installBotSelfConfigMCP(serviceBinaryURL: URL? = nil) throws {
        _ = serviceBinaryURL
        try stripManagedBotMCPResidue([Self.selfConfigMCPResidue])
    }

    public func installBotBrowserMCP(serviceBinaryURL: URL? = nil) throws {
        _ = serviceBinaryURL
        try stripManagedBotMCPResidue([Self.browserMCPResidue])
    }

    public func installBotComputerMCP(serviceBinaryURL: URL? = nil) throws {
        _ = serviceBinaryURL
        try stripManagedBotMCPResidue([Self.computerMCPResidue])
    }

    public func installBotWebMCP(serviceBinaryURL: URL? = nil) throws {
        _ = serviceBinaryURL
        try stripManagedBotMCPResidue([Self.webMCPResidue])
    }

    /// Remove the pre-native managed host entry from the shared configs once.
    /// Runtime admission is process-local, so this only ever deletes residue —
    /// and it must not rewrite a config it has nothing to delete from. Both
    /// branches ran on every launch: the Claude one re-serialized the user's
    /// `settings.json` whenever it had any `mcpServers` (reformatting a file
    /// Claude Code owns), and the Codex one replaced the 16 KB
    /// `~/.codex/config.toml` that ChatGPT.app shares, byte for byte, opening a
    /// lost-update window against a concurrent writer for no reason.
    public func uninstallComputerUseMCP() throws {
        let claude = claudeSettingsURL()
        if let data = try? Data(contentsOf: claude, options: .mappedIfSafe),
           var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var servers = root["mcpServers"] as? [String: Any],
           servers[ComputerUseMCPAdmit.serverName] != nil {
            servers.removeValue(forKey: ComputerUseMCPAdmit.serverName)
            root["mcpServers"] = servers
            if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: claude, options: .atomic)
            }
        }
        let codex = codexConfigURL()
        if let text = (try? Data(contentsOf: codex, options: .mappedIfSafe)).flatMap { String(data: $0, encoding: .utf8) } {
            let stripped = Self.removingMarkerBlock(
                text,
                begin: ComputerUseMCPAdmit.tomlBeginMarker,
                end: ComputerUseMCPAdmit.tomlEndMarker
            )
            guard stripped != text else { return }
            try? Data(stripped.utf8).write(to: codex, options: .atomic)
        }
    }

    private func installClaudeComputerUseMCP(binary: URL) throws {
        let url = claudeSettingsURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = obj
        }
        let existing = root["mcpServers"] as? [String: Any] ?? [:]
        root["mcpServers"] = ComputerUseMCPAdmit.admitClaude(existing: existing, command: binary.path)
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    private func installCodexComputerUseMCP(binary: URL) throws {
        let url = codexConfigURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = ((try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap { String(data: $0, encoding: .utf8) }) ?? ""
        let next = ComputerUseMCPAdmit.admitCodexTOML(existing: existing, command: binary.path)
        try Data(next.utf8).write(to: url, options: .atomic)
    }

    /// ChatGPT.app and RemoteCode-spawned Codex share `~/.codex/config.toml`.
    /// Persisting host-catalog MCP there leaks one stdio child per Codex
    /// conversation. Strip legacy managed blocks; admit per-process instead.
    /// One read and at most one rewrite for the whole residue set.
    private func stripCodexManagedMCP(residues: [ManagedBotMCPResidue]) throws {
        let url = codexConfigURL()
        guard fileManager.fileExists(atPath: url.path),
              let text = (try? Data(contentsOf: url, options: .mappedIfSafe))
                .flatMap({ String(data: $0, encoding: .utf8) })
        else { return }
        // Coarse gate over the whole set: every marker carries the markers'
        // shared prefix and every table header spells a server name verbatim,
        // so a text without either cannot carry any of these residues. Clean
        // configs (the per-turn case) stop here instead of paying the line scan
        // and Foundation's per-residue searches. Both needles are derived from
        // the catalog, so renaming a server cannot strand a residue.
        let markerNeedle = Self.sharedPrefix(of: residues.flatMap { [$0.tomlBeginMarker, $0.tomlEndMarker] })
        let leafNeedle = Self.sharedPrefix(of: residues.map(\.serverName))
        guard (!markerNeedle.isEmpty && text.contains(markerNeedle))
                || (!leafNeedle.isEmpty && text.contains(leafNeedle))
        else { return }
        var stripped = text
        for residue in residues {
            stripped = Self.removingManagedMCP(
                stripped,
                begin: residue.tomlBeginMarker,
                end: residue.tomlEndMarker,
                tableName: "mcp_servers.\(residue.serverName)"
            )
        }
        guard stripped != text else { return }
        try Data(stripped.utf8).write(to: url, options: .atomic)
    }

    /// Longest common prefix of `values`; empty when they share nothing.
    private static func sharedPrefix(of values: [String]) -> String {
        guard var prefix = values.first else { return "" }
        for value in values.dropFirst() {
            while !value.hasPrefix(prefix) {
                guard !prefix.isEmpty else { return "" }
                prefix.removeLast()
            }
        }
        return prefix
    }

    /// Claude Code does not spawn `mcpServers` from settings.json (live:
    /// `claude mcp list` omits RemoteCode bot entries). Strip leftover keys so
    /// a future Claude that starts reading this file cannot leak stdio servers
    /// into interactive `claude` / Claude.app the way Codex leaked into ChatGPT.
    /// One read and at most one rewrite for the whole residue set.
    private func stripClaudeManagedMCP(serverNames: [String]) throws {
        let url = claudeSettingsURL()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any]
        else { return }
        var removedAny = false
        for serverName in serverNames where servers[serverName] != nil {
            servers.removeValue(forKey: serverName)
            removedAny = true
        }
        guard removedAny else { return }
        root["mcpServers"] = servers
        guard let out = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try out.write(to: url, options: .atomic)
    }

    /// Purge the legacy global librarian MCP from the shared configs. Runs on
    /// every Token Saver lifecycle application with the feature off, so it must
    /// not rewrite a config it has nothing to delete from: the Claude branch
    /// re-serialized (and reformatted) a `settings.json` that Claude Code owns,
    /// and the Codex branch replaced the `~/.codex/config.toml` that
    /// ChatGPT.app shares, byte for byte, opening a lost-update window.
    public func uninstallRetrieveMCP() throws {
        // Claude: drop only our server key, keep the rest of settings.json.
        let claude = claudeSettingsURL()
        if let data = try? Data(contentsOf: claude, options: .mappedIfSafe),
           var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var servers = root["mcpServers"] as? [String: Any],
           servers[Self.retrieveMCPName] != nil {
            servers.removeValue(forKey: Self.retrieveMCPName)
            root["mcpServers"] = servers
            if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: claude, options: .atomic)
            }
        }
        // Codex: remove our marker block, keep the rest of config.toml.
        let codex = codexConfigURL()
        if let text = (try? Data(contentsOf: codex, options: .mappedIfSafe)).flatMap { String(data: $0, encoding: .utf8) } {
            let stripped = Self.removingMarkerBlock(text, begin: Self.mcpBeginMarker, end: Self.mcpEndMarker)
            guard stripped != text else { return }
            try? Data(stripped.utf8).write(to: codex, options: .atomic)
        }
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
        let existing = ((try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap { String(data: $0, encoding: .utf8) }) ?? ""
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

    /// Remove every legacy managed block plus the equivalent unmarked TOML
    /// table. The latter is the live Codex format written by older installers;
    /// marker-only stripping left that table active in the shared config.
    /// Returns `text` untouched unless one of the three passes below can match.
    private static func removingManagedMCP(
        _ text: String,
        begin: String,
        end: String,
        tableName: String
    ) -> String {
        // A marker block needs `begin`, a dangling marker needs `end`, and a
        // table header always spells its leaf name verbatim (quoted or spaced
        // headers still carry the name). Without any of the three the line scan
        // and the rewrites below cannot change a byte, so a clean shared config
        // — the per-turn case — skips the scan entirely.
        let leaf = tomlTableLeaf(tableName)
        guard text.range(of: begin) != nil
                || text.range(of: end) != nil
                || (!leaf.isEmpty && text.range(of: leaf) != nil)
        else { return text }
        var result = text
        while let start = result.range(of: begin) {
            if let stop = result.range(of: end, range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<stop.upperBound)
            } else {
                // A truncated marker is still our unique ownership marker. Remove
                // only the marker line; the table pass below removes its table
                // without consuming a following user-authored table.
                result.removeSubrange(start)
            }
        }
        while result.range(of: end) != nil {
            result = result.replacingOccurrences(of: end, with: "")
        }
        result = removingTOMLTable(result, named: tableName)
        guard result != text else { return text }
        let normalized = result
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "" : normalized + "\n"
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

    private static func tomlTableLeaf(_ tableName: String) -> Substring {
        guard let separator = tableName.firstIndex(of: ".") else { return tableName[...] }
        return tableName[tableName.index(after: separator)...]
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

    /// Resolve the RemoteCodeDistillService binary (which also serves CLI mode) the same
    /// way the service controller does: bundled aux executable, then a sibling of the
    /// current executable, then SwiftPM build products and XCTest bundle siblings (for dev/tests).
    public static func resolveServiceBinary(fileManager: FileManager = .default) -> URL? {
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
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        if let sibling = firstServiceSibling(in: [executableDirectory], fileManager: fileManager) {
            return sibling.resolvingSymlinksInPath()
        }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for candidate in swiftPMServiceBinaryCandidates(in: cwd, fileManager: fileManager) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath()
            }
        }
        if let sibling = firstServiceSibling(in: xctestBundleSearchDirectories(), fileManager: fileManager) {
            return sibling.resolvingSymlinksInPath()
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
                let existing = ((try? Data(contentsOf: link, options: .mappedIfSafe)).flatMap { String(data: $0, encoding: .utf8) }) ?? ""
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

        // First missing in sorted order for a deterministic error — min over
        // the difference, no sorted array over every missing file.
        if let missing = allowed.subtracting(foundPaths).min() {
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

    private func mappedString(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let str = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: url.path])
        }
        return str
    }

    private func validateManagedPackage(at directory: URL) throws -> RemoteCodeOrchestrateManifest {
        let manifestURL = directory.appendingPathComponent(Self.remoteCodeOrchestrateManifestName)
        let manifest = try decoder.decode(RemoteCodeOrchestrateManifest.self, from: Data(contentsOf: manifestURL, options: .mappedIfSafe))
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
            from: Data(contentsOf: runtimeManifestURL, options: .mappedIfSafe)
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

        if let existingData = try? Data(contentsOf: skillURL, options: .mappedIfSafe),
           Self.sha256Hex(existingData) == checksum,
           let manifestData = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
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
        case .grok, .distill:
            return homeDirectoryURL().appendingPathComponent(".grok/AGENTS.md")
        }
    }

    public func distillCLIURL() -> URL {
        cliBinDirectory.appendingPathComponent("distill")
    }

    /// Managed Grok PreToolUse hook that appends `| distill` on wrap-eligible shells.
    /// Token Saver reconcile installs this; Token Saver off removes it.
    public static let grokPreToolPipeHookFileName = "remotecode-token-saver-pretool-pipe.json"

    public func grokHooksDirectory() -> URL {
        homeDirectoryURL().appendingPathComponent(".grok/hooks", isDirectory: true)
    }

    public func grokPreToolPipeHookURL() -> URL {
        grokHooksDirectory().appendingPathComponent(Self.grokPreToolPipeHookFileName)
    }

    public static func grokPreToolPipeHookCommand(distillPath: String) -> String {
        "\(distillPath) hook pre-tool-pipe"
    }

    /// Install a trusted global Grok hook (`~/.grok/hooks/…`) so Token-Saver-admitted
    /// Grok — Agent App, headless, nested, and standalone CLI — actually pipes
    /// wrap-eligible `run_terminal_command` via PreToolUse `updatedInput`.
    /// The hook binary re-checks live admission and fail-opens when Token Saver is off.
    public func installGrokPreToolPipeHook() throws {
        try fileManager.createDirectory(at: grokHooksDirectory(), withIntermediateDirectories: true)
        let command = Self.grokPreToolPipeHookCommand(distillPath: distillCLIURL().path)
        let payload: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash|run_terminal_command|run_terminal_cmd",
                        "hooks": [
                            [
                                "type": "command",
                                "command": command,
                                "timeout": 5,
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: grokPreToolPipeHookURL(), options: .atomic)
    }

    @discardableResult
    public func uninstallGrokPreToolPipeHook() throws -> AgentSkillUninstallResult {
        let url = grokPreToolPipeHookURL()
        guard fileManager.fileExists(atPath: url.path) else { return .notPresent }
        try fileManager.removeItem(at: url)
        return .removed
    }

    /// Managed Grok PostToolUse hook that compresses built-in tool results
    /// (`read_file` / `list_dir` / `web_fetch`) through `updatedToolOutput`.
    /// Token Saver reconcile installs this; Token Saver off removes it.
    public static let grokPostToolUseHookFileName = "remotecode-token-saver-posttool.json"

    /// Built-in Grok tools whose replacement shape is verified. Shell
    /// (`run_terminal_command`) stays on the wrapper/PreToolUse pipe lane, and
    /// `grep` (search matches) plus mutation tools stay byte-exact.
    public static let grokPostToolUseHookMatcher = "read_file|list_dir|web_fetch"

    public func grokPostToolUseHookURL() -> URL {
        grokHooksDirectory().appendingPathComponent(Self.grokPostToolUseHookFileName)
    }

    public static func grokPostToolUseHookCommand(distillPath: String) -> String {
        "\(distillPath) hook post-tool-use-grok"
    }

    /// Install the trusted global Grok PostToolUse replacement hook
    /// (`~/.grok/hooks/…`). Grok ≥ 1.0.34 delivers a settings-file hook's
    /// `updatedToolOutput` to the model after validating it against the ran tool's
    /// own output shape; the hook binary re-checks live admission and fail-opens
    /// when Token Saver is off, the sidecar is down, or the shape is not one of the
    /// verified ones.
    public func installGrokPostToolUseHook() throws {
        try fileManager.createDirectory(at: grokHooksDirectory(), withIntermediateDirectories: true)
        let command = Self.grokPostToolUseHookCommand(distillPath: distillCLIURL().path)
        let payload: [String: Any] = [
            "hooks": [
                "PostToolUse": [
                    [
                        "matcher": Self.grokPostToolUseHookMatcher,
                        "hooks": [
                            [
                                "type": "command",
                                "command": command,
                                "timeout": 45,
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: grokPostToolUseHookURL(), options: .atomic)
    }

    @discardableResult
    public func uninstallGrokPostToolUseHook() throws -> AgentSkillUninstallResult {
        let url = grokPostToolUseHookURL()
        guard fileManager.fileExists(atPath: url.path) else { return .notPresent }
        try fileManager.removeItem(at: url)
        return .removed
    }

    /// PATH-reachable symlink that bridges the managed CLI into the shell (`~/.local/bin/distill`).
    public func distillPathLinkURL() -> URL {
        pathBinDirectory.appendingPathComponent("distill")
    }

    private func skillsRoot(for provider: AgentProvider) -> URL {
        switch provider {
        case .claude: return claudeSkillsRoot
        case .codex: return codexSkillsRoot
        case .grok, .distill:
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
            current = try mappedString(at: url)
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
        let current = try mappedString(at: url)
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
