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
    public static let distillSkillID = "distill"
    public static let distillSourceURL = "https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md"
    public static let distillLocalVersion = "7"
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
    Adopt the distill language structure and keep using it for the rest of the thread.

    Core behavior (token-efficient dialect — sparse by default):
    - Registers: R0 micro | R1 work | R2 tool (tool path is `| distill`, not chat prefixes).
    - R0 micro (greeting, yes/no, trivial status, conversational only): **O-only**.
      One short line in the user's language. No S/C/D/R/N/P. No restating the user. No English meta.
      Example: `O: bem, obrigado — pronto pro próximo`
    - R1 work (code, PR, debug, plan, multi-step): **O-first**, sparse optional fields.
      Prefixes (use only when needed): S=state, C=context, D=action, R=risk, N=no-go, P=proof.
      Never pad to six lines. Do not restate the user prompt in C. One idea per line.
      Prefer short atoms over prose. Exact paths/commands/IDs when useful.
    - Do not use Military English boilerplate on R0. On R1 keep short command-style English for ops fields; put user-facing answer in O (user language when the user wrote non-English).
    - No filler. No long prose unless the user asks for explanation.
    - Surfaced thinking: R0 none; R1 sparse distill lines only; keep secrets out.
    - Hard caps: R0 ≤2 lines / ~60 tokens; R1 status ≤4 lines; R1 implement ≤12 lines unless user asks for detail.

    Thread behavior:
    - Prefer R0 for micro chat. Escalate to R1 only when the turn does real work.
    - Do not output a rewritten/compressed version of the latest user prompt unless the user explicitly asks to compress text.
    - Emit `Dict:` early only when aliases reduce repetition (never secrets/people/paths/URLs as aliases).

    Command-output policy (Token Saver — REQUIRED for eligible ordinary noisy output; never distill exact-payload tools or skill content):
    - MANDATORY: for every high-volume / noisy / pipable ordinary command, pipe through the RemoteCode-managed `distill` CLI with an explicit extraction prompt and `pipefail` when exit status matters. Do not skip because the host wrapper "might" compress — if the command is eligible, end with `| distill "<question>"` unless an exact-output rule below forbids it.
      Required for: build, test, lint, install, docker, kubectl, terraform, find, ls (large listings), git log/status/diff (summaries), package managers, long CI/logs, and any other noisy ordinary stdout that is not exact-output.
      Many catalog commands also auto-compress via the host PATH wrapper; still pipe `| distill` yourself when the wrapper may not apply (compound scripts, python/bun one-shots, tools outside the wrap catalog, or when you need a targeted extraction question).
    - NEVER pipe `| distill` for exact-output commands — the agent needs the full stdout for the next step:
      search/match: rg, grep, egrep, fgrep, ag, ugrep, git grep
      line/stream edit or dump: sed, awk, cat, head, tail, nl, cut, tr, paste
      exact compare/bytes: diff, cmp, od, hexdump, xxd, base64
      structure extractors when parsing: jq, yq
      Also skip for: patches/apply, hash/token copy, interactive/TUI, non-pipable calls, or unavailable RemoteCodeDistillService.
    - NEVER Distill skill content: Skill tool output and requested/returned SKILL.md bodies are a protected verbatim category — return them complete (no summary, recovery handle, truncation, or savings accounting).
    - Never call Node, tsx, npm, bun, or a source-checkout CLI for `distill`.
    - When you skip `| distill`, state that briefly (e.g. skip: exact sed/rg output; skip: skill content). Omitting `| distill` on eligible noisy commands is a policy violation.
    - Applies to primary agents, same-provider subagents, and cross-provider nested launches (Claude↔Codex↔Grok) whenever Token Saver is admitted.
    - Host/runtime carries the ordinary-output Distill policy; do not require every worker prompt to restate it.
    - If a summary includes `[[rc:<handle>]]`, recover exact bytes with `distill retrieve <handle>`.
    - Wait for `distill` before continuing when you did pipe it.

    Examples:
    - `bun test 2>&1 | distill "Did tests pass? Return PASS or FAIL, followed by failing test names if any."`
    - `git log --oneline -50 | distill "Summarize recent commits by theme."`
    - `rg -n "func applyGraphify" Sources`  # skip distill — need every match line
    - `sed -n '100,180p' Sources/Foo.swift`  # skip distill — need exact slice

    Source reference:
    - https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md
    """

    public static let distillAgentInstructionsTemplate = """
    <!-- distill skill: begin -->
    CRITICAL: Use `/distill` dialect for provider turns — **sparse, O-first, mode-aware** (not a fixed 6-line S/C/D tax).
    Registers: **R0 micro** (greeting/yes-no/trivial status) = `O:` only, user language, ≤2 lines; no S/C/D/R/N/P, no user restatement.
    **R1 work** (code/PR/debug/plan) = O-first; add S/C/D/R/N/P only when needed; never pad to six lines; short atoms; caps: status ≤4 lines, implement ≤12 unless asked.
    Prefixes when used: S=state, C=context, D=action, R=risk, O=outcome, N=no-go, P=proof.
    Dict/`#` vars only when they reduce repetition. Never alias secrets, people, IDs, paths, URLs.
    Do not return a rewritten/compressed copy of the user's prompt unless explicitly asked to compress text.
    Token Saver — MANDATORY for eligible ordinary noisy output on primary agents, same-provider subagents, and cross-provider nested runs (Claude/Codex/Grok). Use managed `distill` with an explicit extraction prompt; use `pipefail` when exit status matters.
    REQUIRED to pipe: build/test/lint/install/docker/kubectl/terraform, large find/ls, git log/status/diff summaries, package managers, long logs, and any noisy ordinary stdout that is not exact-output. Many catalog commands auto-compress via the host wrapper; still pipe yourself when the wrapper may not apply or you need a targeted question: `<cmd> | distill "<question>"`. Omitting `| distill` on eligible noisy commands is a policy violation.
    NEVER pipe `| distill` for exact-output tools (agent needs full stdout): rg, grep, egrep, fgrep, sed, awk, cat, head, tail, nl, cut, tr, diff, jq, yq, git grep/show/cat-file/blame; also patches/hashes/tokens, interactive/TUI, non-pipable, or service unavailable — state the skip briefly.
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
    public static func providerProxyArguments(
        provider: AgentProvider,
        arguments: [String],
        environment: [String: String]
    ) -> [String] {
        let prompt = tokenSaverProviderPrompt("", environment: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              isSupportedProviderTurn(provider: provider, arguments: arguments)
        else {
            return arguments
        }

        switch provider {
        case .grok:
            return mergingProviderPrompt(
                prompt,
                option: "--rules",
                provider: provider,
                arguments: arguments
            )
        case .claude:
            return mergingProviderPrompt(
                prompt,
                option: "--append-system-prompt",
                provider: provider,
                arguments: arguments
            )
        case .codex:
            let scan = scanProviderArguments(provider: provider, arguments: arguments)
            guard !scan.malformed else { return arguments }
            let configValues = (scan.optionValues["--config"] ?? [])
                + (scan.optionValues["-c"] ?? [])
            let hasDeveloperOverride = configValues.contains {
                $0.hasPrefix("developer_instructions=")
            }
            guard !hasDeveloperOverride else { return arguments }
            let quoted = "\""
                + prompt
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                + "\""
            return ["--config", "developer_instructions=\(quoted)"] + arguments
        }
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
    @discardableResult
    public func installDistillCLI(appSupportDirectory: URL, serviceBinaryURL: URL? = nil) throws -> URL {
        try fileManager.createDirectory(at: cliBinDirectory, withIntermediateDirectories: true)
        let url = distillCLIURL()
        guard let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager) else {
            throw AgentSkillCLIError.serviceBinaryUnavailable
        }
        try? fileManager.removeItem(at: url) // replace any prior symlink or legacy script
        try fileManager.createSymbolicLink(at: url, withDestinationURL: binary)
        linkManagedDistillOntoPath(target: url)
        return url
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
    public func installCommandWrappers(serviceBinaryURL: URL? = nil) throws -> [String] {
        try fileManager.createDirectory(at: cliBinDirectory, withIntermediateDirectories: true)
        guard let binary = serviceBinaryURL ?? Self.resolveServiceBinary(fileManager: fileManager) else {
            throw AgentSkillCLIError.serviceBinaryUnavailable
        }
        // Drop exact-output wrappers left by older catalogs (sed/rg/cat/…).
        _ = try removeManagedWrapperSymlinks(
            basenames: WrappedCommandCatalog.exactOutputCommands,
            binaryURL: binary
        )
        let searchDirectories = systemCommandSearchDirectories()
        var installed: [String] = []
        for command in WrappedCommandCatalog.commands {
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
        return try removeManagedWrapperSymlinks(
            basenames: WrappedCommandCatalog.symlinkBasenamesToRemove,
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

    /// Resolve the RemoteCodeDistillService binary (which also serves CLI mode) the same
    /// way the service controller does: bundled aux executable, then a sibling of the
    /// current executable, then SwiftPM build products and XCTest bundle siblings (for dev/tests).
    public static func resolveServiceBinary(fileManager: FileManager = .default) -> URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "RemoteCodeDistillService"),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        if let sibling = firstServiceSibling(in: [executableDirectory], fileManager: fileManager) {
            return sibling
        }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for candidate in swiftPMServiceBinaryCandidates(in: cwd, fileManager: fileManager) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        if let sibling = firstServiceSibling(in: xctestBundleSearchDirectories(), fileManager: fileManager) {
            return sibling
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

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func upsertDistillInstructions(at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current: String
        if fileManager.fileExists(atPath: url.path) {
            current = try String(contentsOf: url, encoding: .utf8)
        } else {
            current = ""
        }

        let pattern = Self.distillInstructionsBlockPattern
        let next: String
        if let range = current.range(of: pattern, options: .regularExpression) {
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
        guard let range = current.range(of: Self.distillInstructionsBlockPattern, options: .regularExpression) else {
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

    private static var distillInstructionsBlockPattern: String {
        "(?:\\n{0,2})?\(Self.distillInstructionsBeginMarker)[\\s\\S]*?\(Self.distillInstructionsEndMarker)(?:\\n{0,2})?"
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
