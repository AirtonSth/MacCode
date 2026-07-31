import CoreModel
import Darwin
import Foundation

public enum ProviderAgentAppOutputFormat: String, Sendable, Equatable {
    case text = "text"
    case json = "json"
    case grokJSON = "grok-json"
}

/// Lossless bridge from a nested provider CLI into `remote-code agent-app`.
///
/// `runtimeProfile` is set only for the closed `sam-grok-worker-v1` ABI. General
/// nested Claude/Codex/Grok turns omit it so the host Agent App path owns Token
/// Saver (PATH wrappers, dialect, Claude PostToolUse) like a UI subagent.
public struct ProviderAgentAppDelegation: Sendable, Equatable {
    public let provider: AgentProvider
    public let promptFile: String
    public let model: String
    public let reasoningEffort: AgentReasoningEffort
    public let permissionMode: AgentPermissionMode
    public let outputFormat: ProviderAgentAppOutputFormat
    public let runtimeProfile: AgentAppRuntimeProfile?

    public init(
        provider: AgentProvider,
        promptFile: String,
        model: String,
        reasoningEffort: AgentReasoningEffort,
        permissionMode: AgentPermissionMode,
        outputFormat: ProviderAgentAppOutputFormat,
        runtimeProfile: AgentAppRuntimeProfile? = nil
    ) {
        self.provider = provider
        self.promptFile = promptFile
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.permissionMode = permissionMode
        self.outputFormat = outputFormat
        self.runtimeProfile = runtimeProfile
    }

    public var arguments: [String] {
        var args = [
            "agent-app", provider.rawValue,
            "--prompt-file", promptFile
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            args.append(contentsOf: ["--model", trimmedModel])
        }
        args.append(contentsOf: [
            "--permission", permissionMode.rawValue,
            "--reasoning-effort", reasoningEffort.rawValue,
            "--output-format", outputFormat.rawValue
        ])
        if let runtimeProfile {
            args.append(contentsOf: ["--runtime-profile", runtimeProfile.rawValue])
        }
        return args
    }
}

public enum ProviderProxyUsageCaptureFormat: Sendable, Equatable {
    case grokJSON
    case grokJSONLines
    case claudeJSON
    case claudeJSONLines
    case codexJSONLines

    public var isLineDelimited: Bool {
        switch self {
        case .grokJSON, .claudeJSON:
            return false
        case .grokJSONLines, .claudeJSONLines, .codexJSONLines:
            return true
        }
    }
}

public enum ProviderProxyPermissionRequest: Sendable, Equatable {
    case inherited
    case explicit(AgentPermissionMode)
    case invalid(String)
}

public struct ProviderProxyUsageUpdate: Sendable, Equatable {
    public let effective: AssistantTokenUsage
    public let delta: AssistantTokenUsage?

    public init(effective: AssistantTokenUsage, delta: AssistantTokenUsage?) {
        self.effective = effective
        self.delta = delta
    }
}

/// Reconciles provider JSONL usage without double-counting a final cumulative
/// snapshot after earlier incremental request events.
public struct ProviderProxyUsageAccumulator: Sendable {
    private var incremental = AssistantTokenUsage(semantics: .incremental)
    private var cumulative = AssistantTokenUsage(semantics: .cumulative)
    private var lastEffective = AssistantTokenUsage()
    private var hasUsage = false

    public init() {}

    public var effective: AssistantTokenUsage? {
        guard hasUsage else { return nil }
        return AssistantTokenUsage.merging(incremental, with: cumulative)
    }

    public mutating func record(_ usage: AssistantTokenUsage) -> ProviderProxyUsageUpdate {
        switch usage.resolvedSemantics {
        case .incremental:
            incremental = Self.adding(incremental, usage)
        case .cumulative:
            cumulative = AssistantTokenUsage.merging(cumulative, with: usage)
        }
        hasUsage = true
        let next = effective ?? usage
        let delta = Self.delta(from: lastEffective, to: next)
        lastEffective = next
        return ProviderProxyUsageUpdate(effective: next, delta: delta)
    }

    fileprivate static func adding(
        _ lhs: AssistantTokenUsage,
        _ rhs: AssistantTokenUsage
    ) -> AssistantTokenUsage {
        func add(_ lhs: Int, _ rhs: Int) -> Int {
            let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
            return overflow ? Int.max : sum
        }
        func addOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
            guard lhs != nil || rhs != nil else { return nil }
            return add(lhs ?? 0, rhs ?? 0)
        }
        func maxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
            guard lhs != nil || rhs != nil else { return nil }
            return max(lhs ?? 0, rhs ?? 0)
        }
        return AssistantTokenUsage(
            inputTokens: add(lhs.inputTokens, rhs.inputTokens),
            outputTokens: add(lhs.outputTokens, rhs.outputTokens),
            totalTokens: add(lhs.totalTokens, rhs.totalTokens),
            contextWindow: maxOptional(lhs.contextWindow, rhs.contextWindow),
            compactsAutomatically: rhs.compactsAutomatically ?? lhs.compactsAutomatically,
            uncachedInputTokens: addOptional(lhs.uncachedInputTokens, rhs.uncachedInputTokens),
            cacheCreationInputTokens: addOptional(
                lhs.cacheCreationInputTokens,
                rhs.cacheCreationInputTokens
            ),
            cacheReadInputTokens: addOptional(lhs.cacheReadInputTokens, rhs.cacheReadInputTokens),
            reportedCostMicros: addOptional(lhs.reportedCostMicros, rhs.reportedCostMicros),
            contextTokens: rhs.contextTokens ?? lhs.contextTokens,
            semantics: .incremental
        )
    }

    private static func delta(
        from previous: AssistantTokenUsage,
        to current: AssistantTokenUsage
    ) -> AssistantTokenUsage? {
        func subtract(_ current: Int, _ previous: Int) -> Int {
            max(0, current - min(current, max(0, previous)))
        }
        func subtractOptional(_ current: Int?, _ previous: Int?) -> Int? {
            guard current != nil || previous != nil else { return nil }
            return subtract(current ?? 0, previous ?? 0)
        }
        let total = subtract(current.totalTokens, previous.totalTokens)
        guard total > 0 else { return nil }
        return AssistantTokenUsage(
            inputTokens: subtract(current.inputTokens, previous.inputTokens),
            outputTokens: subtract(current.outputTokens, previous.outputTokens),
            totalTokens: total,
            contextWindow: current.contextWindow,
            compactsAutomatically: current.compactsAutomatically,
            uncachedInputTokens: subtractOptional(
                current.uncachedInputTokens,
                previous.uncachedInputTokens
            ),
            cacheCreationInputTokens: subtractOptional(
                current.cacheCreationInputTokens,
                previous.cacheCreationInputTokens
            ),
            cacheReadInputTokens: subtractOptional(
                current.cacheReadInputTokens,
                previous.cacheReadInputTokens
            ),
            reportedCostMicros: subtractOptional(
                current.reportedCostMicros,
                previous.reportedCostMicros
            ),
            contextTokens: current.contextTokens,
            semantics: .incremental
        )
    }
}

public struct ProviderProxyUsageCommitAttempt: Sendable, Equatable {
    public let delta: AssistantTokenUsage
    public let session: AssistantTokenUsage
    public let eligibleRunCandidate: Int

    public init(
        delta: AssistantTokenUsage,
        session: AssistantTokenUsage,
        eligibleRunCandidate: Int
    ) {
        self.delta = delta
        self.session = session
        self.eligibleRunCandidate = eligibleRunCandidate
    }
}

public struct ProviderProxyUsagePersistenceResult: Sendable, Equatable {
    public let persisted: Bool
    public let eligibleRunRecorded: Bool

    public init(persisted: Bool, eligibleRunRecorded: Bool) {
        self.persisted = persisted
        self.eligibleRunRecorded = eligibleRunRecorded
    }
}

/// Holds provider-reported usage until the local ledger confirms persistence.
/// Failed writes remain pending and are combined with later observations, so
/// advancing the provider accumulator can never silently drop a token delta.
public struct ProviderProxyUsageCommitBuffer: Sendable {
    private var pendingDelta: AssistantTokenUsage?
    private var latestSession: AssistantTokenUsage?
    private var hasRecordedEligibleRun = false

    public init() {}

    public var eligibleRunCandidate: Int {
        hasRecordedEligibleRun ? 0 : 1
    }

    public mutating func enqueue(
        delta: AssistantTokenUsage,
        session: AssistantTokenUsage
    ) {
        guard delta.totalTokens > 0 else { return }
        if let pendingDelta {
            self.pendingDelta = ProviderProxyUsageAccumulator.adding(
                pendingDelta,
                delta
            )
        } else {
            pendingDelta = delta
        }
        latestSession = session
    }

    /// Attempts the pending write at most `maxAttempts` times. `retryDelay` is
    /// invoked only between failed attempts; production supplies bounded
    /// backoff while unit tests keep this state machine deterministic.
    @discardableResult
    public mutating func persistPending(
        maxAttempts: Int,
        retryDelay: (Int) -> Void = { _ in },
        persist: (ProviderProxyUsageCommitAttempt) -> ProviderProxyUsagePersistenceResult
    ) -> Bool {
        guard pendingDelta != nil else { return true }
        guard maxAttempts > 0 else { return false }

        for attemptIndex in 0..<maxAttempts {
            if attemptIndex > 0 {
                retryDelay(attemptIndex)
            }
            guard let pendingDelta, let latestSession else { return true }
            let result = persist(ProviderProxyUsageCommitAttempt(
                delta: pendingDelta,
                session: latestSession,
                eligibleRunCandidate: eligibleRunCandidate
            ))
            guard result.persisted else { continue }

            self.pendingDelta = nil
            self.latestSession = nil
            if result.eligibleRunRecorded {
                hasRecordedEligibleRun = true
            }
            return true
        }
        return false
    }
}

/// Bounded line framing for provider JSONL. Stdout forwarding is independent:
/// callers write each raw chunk first, then feed a copy here for telemetry.
public struct ProviderProxyJSONLineDecoder: Sendable {
    private var pending = Data()
    private var discardingOversizedLine = false
    private let maximumLineBytes: Int

    public init(maximumLineBytes: Int = 4 * 1_024 * 1_024) {
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    public mutating func append(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        if discardingOversizedLine {
            guard let newline = chunk.firstIndex(of: 0x0A) else { return [] }
            discardingOversizedLine = false
            let remainder = chunk[chunk.index(after: newline)...]
            return append(Data(remainder))
        }

        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if line.count <= maximumLineBytes {
                lines.append(line)
            }
        }
        if pending.count > maximumLineBytes {
            pending.removeAll(keepingCapacity: false)
            discardingOversizedLine = true
        }
        return lines
    }

    public mutating func finish() -> [Data] {
        guard !discardingOversizedLine, !pending.isEmpty else {
            pending.removeAll(keepingCapacity: false)
            discardingOversizedLine = false
            return []
        }
        var line = pending
        pending.removeAll(keepingCapacity: false)
        if line.last == 0x0D { line.removeLast() }
        return [line]
    }
}

/// Idempotent finalization state. A failed persistence attempt releases the
/// claim so a later caller can retry; only a successful commit is terminal.
public struct ProviderProxyFinalizationTracker: Sendable {
    private var inFlight = Set<UUID>()
    private var finalized = Set<UUID>()

    public init() {}

    public mutating func claim(_ runId: UUID) -> Bool {
        guard !inFlight.contains(runId), !finalized.contains(runId) else {
            return false
        }
        inFlight.insert(runId)
        return true
    }

    public mutating func complete(_ runId: UUID, succeeded: Bool) {
        inFlight.remove(runId)
        if succeeded { finalized.insert(runId) }
    }

    public func isFinalized(_ runId: UUID) -> Bool {
        finalized.contains(runId)
    }
}

/// Pure policy for the RemoteCode nested-provider PATH controller.
///
/// The OS half (spawn, streams, receipts) lives in `RemoteCodeDistillService`;
/// everything here is deterministic and free of process I/O so unit tests cover
/// resolution, recursion avoidance, node ids, and status mapping without spawning.
///
/// Contract:
/// - Resolve the real provider executable outside the managed bin / self.
/// - Never parse prompts, transcripts, tool output, or secrets into node ids.
/// - Fail open: missing real binary or missing telemetry scope is a non-proxy path.
/// - Do not invent Token Saver admission; the parent environment is authoritative.
public enum ProviderProxyPolicy {
    public static var providerCommands: Set<String> { ProviderProxyCatalog.providerSet }

    public static func isProviderProxy(_ command: String) -> Bool {
        ProviderProxyCatalog.isProviderProxyCommand(command)
    }

    public static func commandBasename(_ command: String) -> String {
        ProviderProxyCatalog.commandBasename(command)
    }

    /// The transparent stream seam: forward the original chunk first, then
    /// inspect a copy for complete JSONL events. The returned telemetry can
    /// never rewrite, delay, or replace provider stdout bytes.
    public static func forwardAndDecodeJSONLines(
        _ chunk: Data,
        decoder: inout ProviderProxyJSONLineDecoder,
        forward: (Data) -> Void
    ) -> [Data] {
        forward(chunk)
        return decoder.append(chunk)
    }

    public static func rawUsageEligibleRuns(
        tokenSaverAdmitted: Bool,
        candidate: Int
    ) -> Int {
        tokenSaverAdmitted ? max(0, candidate) : 0
    }

    // MARK: - telemetry scope (content-free)

    /// Upgrade the legacy Token Saver thread key into the always-on lifecycle
    /// key before paid-lane scrubbing. This keeps hierarchy visible when Token
    /// Saver is disabled without preserving any paid capability.
    public static func alwaysOnTelemetryEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        guard environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"] == nil,
              let legacyThread = environment["RC_TOKEN_SAVER_THREAD_ID"],
              UUID(uuidString: legacyThread) != nil else {
            return environment
        }
        var updated = environment
        updated["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"] = legacyThread
        return updated
    }

    /// Thread-scoped Subagents telemetry is present when the host injected the
    /// always-on scope keys. Token Saver lanes are orthogonal and not required.
    public static func hasTelemetryScope(environment: [String: String]) -> Bool {
        let thread = (environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"]
            ?? environment["RC_TOKEN_SAVER_THREAD_ID"]
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = (environment["REMOTE_CODE_AGENT_PROVIDER"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !thread.isEmpty && UUID(uuidString: thread) != nil && AgentProvider(rawValue: provider) != nil
    }

    /// Apply the live host gate to inherited paid-lane variables. The managed
    /// bin and `RC_REMOTE_CODE_*` routing stay intact because provider proxies
    /// and explicit Agent App delegation are always-on lifecycle plumbing.
    public static func paidRuntimeEnvironment(
        environment: [String: String],
        tokenSaverRuntimeActive: Bool,
        graphifyRuntimeActive: Bool
    ) -> [String: String] {
        var updated = environment
        if !tokenSaverRuntimeActive {
            for key in environment.keys
            where key.hasPrefix("RC_TOKEN_SAVER_")
                || key.hasPrefix("RC_DISTILL_")
                || key.hasPrefix("RC_GRAPHIFY_")
                || key == "REMOTE_CODE_DISTILL_STATE_PATH" {
                updated.removeValue(forKey: key)
            }
            return updated
        }
        if !graphifyRuntimeActive {
            for key in environment.keys where key.hasPrefix("RC_GRAPHIFY_") {
                updated.removeValue(forKey: key)
            }
        }
        return updated
    }

    /// Retarget one raw provider process to its recorded external child. This
    /// is what makes a provider that launches another provider form a real
    /// generation chain instead of attributing every descendant to the root.
    ///
    /// `tokenSaverEnvironment` must be rebuilt from a host-validated receipt
    /// for `targetProvider`. When it is absent (or the child was not recorded),
    /// paid lanes fail open while always-on routing remains.
    public static func childScopedEnvironment(
        environment: [String: String],
        targetProvider: AgentProvider,
        childRunId: String?,
        childDelegationCapability: String?,
        tokenSaverEnvironment: [String: String]?
    ) -> [String: String] {
        var updated = environment
        updated["REMOTE_CODE_AGENT_PROVIDER"] = targetProvider.rawValue
        updated["REMOTE_CODE_PROVIDER_INSTANCE_ID"] = targetProvider.rawValue
        // A parent bearer must never cross a provider boundary. The child gets
        // only the independently-issued capability bound to its own receipt.
        updated.removeValue(
            forKey: AgentDelegationCapabilityTransport.environmentKey
        )

        guard let childRunId,
              UUID(uuidString: childRunId) != nil else {
            updated.removeValue(forKey: "RC_REMOTE_CODE_ROOT_RUN_ID")
            return paidRuntimeEnvironment(
                environment: updated,
                tokenSaverRuntimeActive: false,
                graphifyRuntimeActive: false
            )
        }

        updated["RC_REMOTE_CODE_ROOT_RUN_ID"] = childRunId
        if let childDelegationCapability,
           AgentDelegationCapabilityTransport.isWellFormed(
            childDelegationCapability
           ) {
            updated[AgentDelegationCapabilityTransport.environmentKey] =
                childDelegationCapability
        }
        guard let tokenSaverEnvironment else {
            return paidRuntimeEnvironment(
                environment: updated,
                tokenSaverRuntimeActive: false,
                graphifyRuntimeActive: false
            )
        }
        for key in updated.keys where key.hasPrefix("RC_TOKEN_SAVER_") {
            updated.removeValue(forKey: key)
        }
        // This hook is Claude-only. A Claude parent cannot leak it into a
        // Codex/Grok child, and a Claude child receives it only when the
        // retargeted, host-validated environment explicitly includes it.
        updated.removeValue(forKey: "REMOTE_CODE_DISTILL_STATE_PATH")
        updated.merge(tokenSaverEnvironment) { _, receiptValue in receiptValue }
        // Root and attempt are deliberately the same external-child identity:
        // there is one raw provider process and one lifecycle receipt.
        updated["RC_TOKEN_SAVER_ROOT_RUN_ID"] = childRunId
        updated["RC_TOKEN_SAVER_ATTEMPT_ID"] = childRunId
        return updated
    }

    /// Claude exposes the PostToolUse lane; Codex and Grok do not. Recompute
    /// this capability at every provider boundary instead of copying the
    /// parent's provider-specific shape.
    public static func childPostToolUseCapability(
        targetProvider: AgentProvider,
        distillAvailable: Bool
    ) -> Bool? {
        switch targetProvider {
        case .claude:
            return distillAvailable
        case .codex, .grok:
            return nil
        }
    }

    // MARK: - raw provider permission ceiling

    /// Parse only provider permission/sandbox flags. No argument is rewritten;
    /// this value is solely compared with the persisted parent receipt before
    /// spawn. Flags after `--` are prompt/positional content and are ignored.
    public static func explicitPermissionRequest(
        providerBasename: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) -> ProviderProxyPermissionRequest {
        guard let provider = AgentProvider(
            rawValue: commandBasename(providerBasename)
        ) else {
            return .inherited
        }

        var candidates: [AgentPermissionMode] = []
        var sandbox: AgentPermissionMode?
        var bypassApproval = false
        var sawPermissionFlag = false
        var sawArgumentSandbox = false
        var invalidReason: String?

        func parsePermissionMode(_ raw: String) -> AgentPermissionMode? {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "default", "plan", "manual", "dontask", "delegate",
                 "supervised", "ask", "askbeforeedits":
                return .supervised
            case "acceptedits", "accept-edits", "auto", "auto_accept_edits", "workspace":
                return .autoAcceptEdits
            case "bypasspermissions", "bypass-permissions", "full_access":
                return .fullAccess
            default:
                return nil
            }
        }

        func parseSandbox(_ raw: String) -> AgentPermissionMode? {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "read-only", "readonly":
                return .supervised
            case "workspace", "workspace-write", "workspace_write":
                return .autoAcceptEdits
            case "danger-full-access", "danger_full_access", "bypasspermissions":
                return .fullAccess
            default:
                return nil
            }
        }

        func parseApproval(_ raw: String) -> Bool? {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().replacingOccurrences(of: "\"", with: "") {
            case "never":
                return true
            case "untrusted", "on-failure", "on-request", "default":
                return false
            default:
                return nil
            }
        }

        func parseCodexConfig(_ raw: String) {
            let pair = raw.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else {
                sawPermissionFlag = true
                candidates.append(.fullAccess)
                return
            }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1]
            switch key {
            case "approval_policy":
                sawPermissionFlag = true
                guard let parsed = parseApproval(value) else {
                    invalidReason = "unknown Codex approval_policy"
                    return
                }
                bypassApproval = bypassApproval || parsed
            case "sandbox_mode", "sandbox":
                sawPermissionFlag = true
                guard let parsed = parseSandbox(
                    value.replacingOccurrences(of: "\"", with: "")
                ) else {
                    invalidReason = "unknown Codex sandbox mode"
                    return
                }
                sandbox = sawArgumentSandbox
                    ? Self.broaderPermission(sandbox, parsed)
                    : parsed
                sawArgumentSandbox = true
            default:
                // Arbitrary Codex config can enable hooks/MCP processes or add
                // roots outside the visible sandbox flags. Only the two
                // permission keys above have a closed, parseable authority ABI.
                sawPermissionFlag = true
                candidates.append(.fullAccess)
            }
        }

        let valueFlags: Set<String> = {
            switch provider {
            case .codex:
                return [
                    "--sandbox", "-s", "--ask-for-approval", "-a", "--config", "-c",
                    "--model", "-m", "--image", "-i", "--color", "--cd", "-C",
                    "--profile", "-p", "--add-dir", "--local-provider",
                    "--output-schema", "-o", "--output-last-message",
                    "--enable", "--disable", "--remote", "--remote-auth-token-env"
                ]
            case .claude:
                return [
                    "--permission-mode", "--model", "--effort", "--output-format",
                    "--input-format", "--tools", "--allowedTools", "--allowed-tools",
                    "--disallowedTools", "--disallowed-tools",
                    "--append-system-prompt", "--system-prompt", "--setting-sources",
                    "--settings", "--session-id", "--resume", "-r", "--add-dir",
                    "--cwd", "--worktree", "-w", "--fallback-model", "--json-schema",
                    "--max-budget-usd", "--name", "-n", "--prompt-suggestions",
                    "--remote-control-session-name-prefix", "--system-prompt-file",
                    "--append-system-prompt-file", "--betas", "--mcp-config",
                    "--plugin-dir", "--plugin-url", "--debug-file", "--file",
                    "--agent", "--agents", "--from-pr", "--remote-control"
                ]
            case .grok:
                return [
                    "--permission-mode", "--sandbox", "--prompt-file", "-p",
                    "--model", "-m", "--effort", "--reasoning-effort",
                    "--output-format", "--disallowed-tools", "--allowed-tools",
                    "--allow", "--deny", "--tools", "--rules", "--json-schema",
                    "--max-turns", "--prompt-json", "--system-prompt-override",
                    "--cwd", "--worktree", "-w", "--worktree-ref", "--debug-file",
                    "--leader-socket", "--agent", "--agents", "--session-id", "--resume"
                ]
            }
        }()
        let fullAccessValueFlags: Set<String> = {
            switch provider {
            case .codex:
                return [
                    "--profile", "-p", "--cd", "-C", "--add-dir",
                    "-o", "--output-last-message", "--enable", "--disable",
                    "--remote", "--remote-auth-token-env"
                ]
            case .claude:
                return [
                    "--setting-sources", "--settings", "--session-id",
                    "--resume", "-r", "--add-dir", "--cwd", "--worktree", "-w",
                    "--mcp-config", "--plugin-dir", "--plugin-url", "--debug-file",
                    "--file", "--agent", "--agents", "--from-pr", "--remote-control"
                ]
            case .grok:
                return [
                    "--cwd", "--worktree", "-w", "--worktree-ref", "--debug-file",
                    "--leader-socket", "--agent", "--agents", "--session-id", "--resume"
                ]
            }
        }()
        let safeBooleanFlags: Set<String> = {
            switch provider {
            case .codex:
                return [
                    "--full-auto", "--strict-config", "--oss", "--skip-git-repo-check",
                    "--ephemeral", "--ignore-user-config", "--ignore-rules", "--json",
                    "--no-alt-screen", "--help", "-h", "--version", "-V"
                ]
            case .claude:
                return [
                    "--print", "-p", "--no-session-persistence", "--verbose", "--bare",
                    "--brief", "--no-chrome", "--disable-slash-commands",
                    "--exclude-dynamic-system-prompt-sections", "--forward-subagent-text",
                    "--include-hook-events", "--include-partial-messages",
                    "--replay-user-messages", "--strict-mcp-config", "--safe-mode",
                    "--ax-screen-reader", "--help", "-h", "--version", "-v"
                ]
            case .grok:
                return [
                    "--always-approve", "--no-memory", "--no-subagents", "--no-auto-update",
                    "--disable-web-search", "--fullscreen", "--minimal", "--no-alt-screen",
                    "--no-plan", "--verbatim", "--help", "-h", "--version", "-v"
                ]
            }
        }()
        let fullAccessBooleanFlags: Set<String> = {
            switch provider {
            case .codex:
                return [
                    "--dangerously-bypass-approvals-and-sandbox",
                    "--dangerously-bypass-hook-trust", "--search"
                ]
            case .claude:
                return [
                    "--dangerously-skip-permissions",
                    "--allow-dangerously-skip-permissions", "--chrome", "--ide",
                    "--bg", "--background", "--tmux"
                ]
            case .grok:
                return [
                    "--dangerously-skip-permissions", "--experimental-memory",
                    "--restore-code", "--oauth", "--continue", "-c",
                    "--fork-session", "--debug"
                ]
            }
        }()
        let fullAccessSubcommands: Set<String> = {
            switch provider {
            case .codex:
                return [
                    "login", "logout", "mcp", "plugin", "mcp-server", "app-server",
                    "remote-control", "app", "update", "sandbox", "debug", "apply",
                    "resume", "archive", "delete", "unarchive", "fork", "cloud",
                    "exec-server", "features"
                ]
            case .claude:
                return [
                    "agents", "auth", "auto-mode", "gateway", "install", "mcp",
                    "plugin", "plugins", "project", "setup-token", "ultrareview",
                    "update", "upgrade"
                ]
            case .grok:
                return [
                    "dashboard", "export", "leader", "login", "logout", "mcp",
                    "memory", "plugin", "sessions", "setup", "trace", "update",
                    "worktree", "wrap"
                ]
            }
        }()

        if provider == .grok,
           let inheritedSandbox = environment["GROK_SANDBOX"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !inheritedSandbox.isEmpty {
            sawPermissionFlag = true
            guard let parsed = parseSandbox(inheritedSandbox) else {
                return .invalid("unknown GROK_SANDBOX mode")
            }
            sandbox = Self.broaderPermission(sandbox, parsed)
        }

        var index = 0
        var sawTopLevelToken = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }

            if !argument.hasPrefix("-") || argument == "-" {
                if !sawTopLevelToken {
                    sawTopLevelToken = true
                    if fullAccessSubcommands.contains(argument) {
                        sawPermissionFlag = true
                        candidates.append(.fullAccess)
                    }
                }
                index += 1
                continue
            }

            switch (provider, argument) {
            case (.codex, "--dangerously-bypass-approvals-and-sandbox"):
                sawPermissionFlag = true
                candidates.append(.fullAccess)
                index += 1
                continue
            case (.codex, "--full-auto"):
                sawPermissionFlag = true
                // Codex defines this as the complete workspace-write shortcut,
                // not an approval-only dimension.
                sandbox = .autoAcceptEdits
                sawArgumentSandbox = true
                index += 1
                continue
            case (.claude, "--dangerously-skip-permissions"),
                 (.grok, "--dangerously-skip-permissions"):
                sawPermissionFlag = true
                candidates.append(.fullAccess)
                index += 1
                continue
            case (.grok, "--always-approve"):
                sawPermissionFlag = true
                bypassApproval = true
                index += 1
                continue
            default:
                break
            }

            if fullAccessBooleanFlags.contains(argument) {
                sawPermissionFlag = true
                candidates.append(.fullAccess)
                index += 1
                continue
            }
            if safeBooleanFlags.contains(argument) {
                index += 1
                continue
            }

            if valueFlags.contains(argument) {
                guard index + 1 < arguments.count else {
                    return .invalid("missing value for \(argument)")
                }
                let value = arguments[index + 1]
                switch argument {
                case "--permission-mode":
                    sawPermissionFlag = true
                    guard let parsed = parsePermissionMode(value) else {
                        return .invalid("unknown permission mode")
                    }
                    candidates.append(parsed)
                case "--sandbox", "-s":
                    sawPermissionFlag = true
                    guard let parsed = parseSandbox(value) else {
                        return .invalid("unknown sandbox mode")
                    }
                    sandbox = sawArgumentSandbox
                        ? Self.broaderPermission(sandbox, parsed)
                        : parsed
                    sawArgumentSandbox = true
                case "--ask-for-approval", "-a":
                    sawPermissionFlag = true
                    guard let parsed = parseApproval(value) else {
                        return .invalid("unknown approval policy")
                    }
                    bypassApproval = bypassApproval || parsed
                case "--config", "-c":
                    if provider == .codex { parseCodexConfig(value) }
                case "--profile", "-p":
                    if provider == .codex {
                        // A profile may supply sandbox/approval configuration
                        // that is not visible in argv.
                        sawPermissionFlag = true
                        candidates.append(.fullAccess)
                    }
                case "--settings", "--setting-sources":
                    if provider == .claude {
                        // External settings can change permission rules and
                        // hooks; enforce the maximum possible authority.
                        sawPermissionFlag = true
                        candidates.append(.fullAccess)
                    }
                case "--cd", "-C", "--add-dir", "--cwd", "--worktree":
                    // Any caller-selected working tree/root can escape the
                    // parent's scoped workspace. Until canonical containment
                    // is proven by the host, require a full-access parent.
                    sawPermissionFlag = true
                    candidates.append(.fullAccess)
                default:
                    break
                }
                if fullAccessValueFlags.contains(argument) {
                    sawPermissionFlag = true
                    candidates.append(.fullAccess)
                }
                index += 2
                continue
            }

            if let equals = argument.firstIndex(of: "=") {
                let flag = String(argument[..<equals])
                let value = String(argument[argument.index(after: equals)...])
                if valueFlags.contains(flag) {
                    switch flag {
                    case "--permission-mode":
                        sawPermissionFlag = true
                        guard let parsed = parsePermissionMode(value) else {
                            return .invalid("unknown permission mode")
                        }
                        candidates.append(parsed)
                    case "--sandbox", "-s":
                        sawPermissionFlag = true
                        guard let parsed = parseSandbox(value) else {
                            return .invalid("unknown sandbox mode")
                        }
                        sandbox = sawArgumentSandbox
                            ? Self.broaderPermission(sandbox, parsed)
                            : parsed
                        sawArgumentSandbox = true
                    case "--ask-for-approval", "-a":
                        sawPermissionFlag = true
                        guard let parsed = parseApproval(value) else {
                            return .invalid("unknown approval policy")
                        }
                        bypassApproval = bypassApproval || parsed
                    case "--config", "-c":
                        if provider == .codex { parseCodexConfig(value) }
                    case "--profile", "-p":
                        if provider == .codex {
                            sawPermissionFlag = true
                            candidates.append(.fullAccess)
                        }
                    case "--settings", "--setting-sources":
                        if provider == .claude {
                            sawPermissionFlag = true
                            candidates.append(.fullAccess)
                        }
                    case "--cd", "-C", "--add-dir", "--cwd", "--worktree":
                        sawPermissionFlag = true
                        candidates.append(.fullAccess)
                    default:
                        break
                    }
                    if fullAccessValueFlags.contains(flag) {
                        sawPermissionFlag = true
                        candidates.append(.fullAccess)
                    }
                    index += 1
                    continue
                }
            }
            // A new provider option can enable plugins, hooks, MCP processes,
            // filesystem roots, or direct management actions. Until its
            // authority ABI is explicitly classified above, require the maximum
            // parent ceiling. Values of known options were consumed already, and
            // everything after `--` was excluded before reaching this branch.
            sawPermissionFlag = true
            candidates.append(.fullAccess)
            index += 1
        }

        if let invalidReason { return .invalid(invalidReason) }
        if bypassApproval {
            // Approval suppression is its own authority dimension. A sandbox
            // may bound filesystem access, but `never` / `--always-approve`
            // removes the parent's opportunity to review every other provider
            // action. The one exact sam-grok-worker ABI is promoted to a
            // host-controlled Agent App turn before raw parsing reaches here.
            candidates.append(.fullAccess)
        }
        if let sandbox {
            let effectiveSandbox: AgentPermissionMode
            switch sandbox {
            case .supervised:
                effectiveSandbox = .supervised
            case .autoAcceptEdits:
                // Approval policy changes prompting, not filesystem authority:
                // workspace-write can still edit and is never supervised.
                effectiveSandbox = .autoAcceptEdits
            case .fullAccess:
                effectiveSandbox = .fullAccess
            }
            candidates.append(effectiveSandbox)
        } else if sawPermissionFlag, provider != .claude {
            // A permission/approval dimension without a proven sandbox leaves
            // Codex/Grok filesystem authority to provider config or
            // environment. Claude's permission-mode is its complete authority
            // ABI, while its separate settings/root-extending flags above
            // already require full access.
            candidates.append(.fullAccess)
        }
        guard sawPermissionFlag || !candidates.isEmpty else { return .inherited }
        return .explicit(candidates.reduce(.supervised) {
            Self.broaderPermission($0, $1) ?? $0
        })
    }

    public static func isPermissionMode(
        _ requested: AgentPermissionMode,
        noBroaderThan parent: AgentPermissionMode
    ) -> Bool {
        permissionRank(requested) <= permissionRank(parent)
    }

    /// Raw provider defaults can be widened by user configuration and inherited
    /// environment outside argv. An absent explicit restriction therefore
    /// requires the full-access parent ceiling.
    public static func effectiveRawPermissionRequest(
        _ parsed: ProviderProxyPermissionRequest
    ) -> ProviderProxyPermissionRequest {
        switch parsed {
        case .inherited:
            return .explicit(.fullAccess)
        case .explicit, .invalid:
            return parsed
        }
    }

    private static func broaderPermission(
        _ lhs: AgentPermissionMode?,
        _ rhs: AgentPermissionMode
    ) -> AgentPermissionMode? {
        guard let lhs else { return rhs }
        return permissionRank(rhs) > permissionRank(lhs) ? rhs : lhs
    }

    private static func permissionRank(_ mode: AgentPermissionMode) -> Int {
        switch mode {
        case .supervised: return 0
        case .autoAcceptEdits: return 1
        case .fullAccess: return 2
        }
    }

    /// Extract metadata without treating prompt/value payloads as flags.
    /// Everything after `--` remains provider-owned positional content.
    public static func optionValue(
        _ names: Set<String>,
        in arguments: [String]
    ) -> String? {
        let otherValueFlags: Set<String> = [
            "-p", "--prompt", "--prompt-file", "--rules",
            "--append-system-prompt", "--system-prompt", "--tools",
            "--allowed-tools", "--allowedTools", "--disallowed-tools",
            "--disallowedTools", "--settings", "--setting-sources",
            "--output-format", "--input-format", "--permission-mode",
            "--sandbox", "--ask-for-approval", "-a", "--config", "-c",
            "--effort", "--reasoning-effort", "--image", "--cd", "-C",
            "--profile", "--add-dir", "--local-provider", "--color"
        ]
        let otherBooleanFlags: Set<String> = [
            "--always-approve", "--no-memory", "--no-subagents",
            "--no-auto-update", "--print", "--verbose",
            "--no-session-persistence", "--json", "--full-auto",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-skip-permissions"
        ]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            if names.contains(argument) {
                guard index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            if let name = names.first(where: {
                argument.hasPrefix("\($0)=")
            }) {
                return String(argument.dropFirst(name.count + 1))
            }
            if otherValueFlags.contains(argument) {
                guard index + 1 < arguments.count else { return nil }
                index += 2
            } else if otherBooleanFlags.contains(argument) {
                index += 1
            } else {
                // Unknown flags and positionals make value boundaries
                // ambiguous. Never scan through prompt-like data for metadata.
                return nil
            }
        }
        return nil
    }

    // MARK: - Agent App middleware

    /// Parse only the exact argv emitted by `sam-grok-worker`'s deterministic
    /// resolver. The recognized contract has a lossless Agent App mapping:
    /// prompt-file, model and effort stay unchanged; workspace+always-approve
    /// becomes `auto_accept_edits`; Grok JSON remains a JSON object with `text`.
    ///
    /// This parser is deliberately independent of process environment and I/O.
    /// Any alias, duplicate, terminator, extra flag, positional argument, or
    /// missing member fails closed to the raw provider path.
    public static func samGrokWorkerAgentAppDelegation(
        providerBasename: String,
        arguments: [String]
    ) -> ProviderAgentAppDelegation? {
        guard commandBasename(providerBasename) == AgentProvider.grok.rawValue else {
            return nil
        }

        let valueFlags: Set<String> = [
            "--prompt-file", "--model", "--effort",
            "--output-format", "--sandbox", "--disallowed-tools"
        ]
        let booleanFlags: Set<String> = [
            "--always-approve", "--no-memory",
            "--no-subagents", "--no-auto-update"
        ]
        var values: [String: String] = [:]
        var booleans = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument != "--", !argument.contains("=") else { return nil }
            if valueFlags.contains(argument) {
                guard values[argument] == nil,
                      index + 1 < arguments.count else {
                    return nil
                }
                values[argument] = arguments[index + 1]
                index += 2
                continue
            }
            if booleanFlags.contains(argument) {
                guard booleans.insert(argument).inserted else { return nil }
                index += 1
                continue
            }
            return nil
        }

        guard values.count == valueFlags.count,
              booleans == booleanFlags,
              let promptFile = values["--prompt-file"],
              (promptFile as NSString).isAbsolutePath,
              !promptFile.isEmpty,
              values["--model"] == "grok-4.5",
              let effortValue = values["--effort"],
              let effort = AgentReasoningEffort(rawValue: effortValue),
              [.low, .medium, .high, .xhigh, .max].contains(effort),
              values["--output-format"] == "json",
              values["--sandbox"] == "workspace",
              values["--disallowed-tools"] == "Agent" else {
            return nil
        }
        return ProviderAgentAppDelegation(
            provider: .grok,
            promptFile: promptFile,
            model: "grok-4.5",
            reasoningEffort: effort,
            permissionMode: .autoAcceptEdits,
            outputFormat: .grokJSON,
            runtimeProfile: .samGrokWorkerV1
        )
    }

    /// Promote a nested shell-launched provider CLI into Agent App when the turn
    /// ABI is agent-shaped and a host-materialized absolute `promptFile` is ready.
    ///
    /// Fail closed (return nil → raw provider proxy with Token Saver) for:
    /// administrative subcommands, version/help, relative prompt paths, or
    /// unknown option shapes. Does not invent Token Saver admission — the host
    /// Agent App pipeline applies its own receipt.
    ///
    /// Callers must materialize stdin / inline prompts into `promptFile` first.
    public static func nestedCLIAgentAppDelegation(
        providerBasename: String,
        arguments: [String],
        promptFile: String
    ) -> ProviderAgentAppDelegation? {
        let absolutePrompt = promptFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (absolutePrompt as NSString).isAbsolutePath,
              !absolutePrompt.isEmpty,
              let provider = AgentProvider(rawValue: commandBasename(providerBasename))
        else {
            return nil
        }
        // Prefer the closed sam-grok-worker mapping when the argv is exact.
        if let exact = samGrokWorkerAgentAppDelegation(
            providerBasename: providerBasename,
            arguments: arguments
        ) {
            return exact
        }

        switch provider {
        case .claude:
            return nestedClaudeAgentAppDelegation(arguments: arguments, promptFile: absolutePrompt)
        case .codex:
            return nestedCodexAgentAppDelegation(arguments: arguments, promptFile: absolutePrompt)
        case .grok:
            return nestedGrokAgentAppDelegation(arguments: arguments, promptFile: absolutePrompt)
        }
    }

    /// Whether the nested CLI can be promoted once a prompt file is available.
    /// Used to decide whether to read stdin / write a temp prompt before spawn.
    public static func nestedCLIAgentAppEligible(
        providerBasename: String,
        arguments: [String]
    ) -> Bool {
        guard let provider = AgentProvider(rawValue: commandBasename(providerBasename)) else {
            return false
        }
        if samGrokWorkerAgentAppDelegation(
            providerBasename: providerBasename,
            arguments: arguments
        ) != nil {
            return true
        }
        switch provider {
        case .claude:
            return nestedClaudeAgentAppEligible(arguments: arguments)
        case .codex:
            return nestedCodexAgentAppEligible(arguments: arguments)
        case .grok:
            return nestedGrokAgentAppEligible(arguments: arguments)
        }
    }

    /// Extract an absolute `--prompt-file` from argv when present and well-formed.
    public static func nestedCLIPromptFile(arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return nil }
            if argument == "--prompt-file", index + 1 < arguments.count {
                let path = arguments[index + 1]
                return (path as NSString).isAbsolutePath ? path : nil
            }
            if argument.hasPrefix("--prompt-file=") {
                let path = String(argument.dropFirst("--prompt-file=".count))
                return (path as NSString).isAbsolutePath ? path : nil
            }
            index += 1
        }
        return nil
    }

    /// Inline prompt text from common provider flags/positionals (not stdin).
    public static func nestedCLIInlinePrompt(
        providerBasename: String,
        arguments: [String]
    ) -> String? {
        guard let provider = AgentProvider(rawValue: commandBasename(providerBasename)) else {
            return nil
        }
        switch provider {
        case .claude:
            return nestedClaudeInlinePrompt(arguments: arguments)
        case .codex:
            return nestedCodexInlinePrompt(arguments: arguments)
        case .grok:
            return nestedGrokInlinePrompt(arguments: arguments)
        }
    }

    // MARK: - nested CLI parsers (private)

    private static func nestedClaudeAgentAppEligible(arguments: [String]) -> Bool {
        let scan = scanNestedArguments(
            arguments,
            valueOptions: [
                "--model", "--effort", "--output-format", "--input-format",
                "--permission-mode", "--tools", "--allowed-tools", "--allowedTools",
                "--disallowed-tools", "--disallowedTools", "--append-system-prompt",
                "--system-prompt", "--setting-sources", "--settings",
                "--session-id", "--resume", "-r"
            ],
            flagOptions: [
                "--continue", "-c", "--debug", "--disable-slash-commands",
                "--fork-session", "--help", "-h", "--ide", "--include-partial-messages",
                "--no-session-persistence", "--print", "-p", "--strict-mcp-config",
                "--verbose", "--version", "-V"
            ]
        )
        guard !scan.malformed else { return false }
        if scan.flags.contains("--version") || scan.flags.contains("-V")
            || scan.flags.contains("--help") || scan.flags.contains("-h") {
            return false
        }
        let admin: Set<String> = [
            "agents", "auth", "config", "doctor", "install",
            "mcp", "plugin", "plugins", "update"
        ]
        if let first = scan.positionals.first, admin.contains(first) {
            return false
        }
        // Session continuation is host-owned on Agent App; keep raw for resume.
        if !scan.flags.isDisjoint(with: ["--resume", "-r", "--continue", "-c", "--session-id", "--fork-session"]) {
            return false
        }
        // Agent App cannot honor a restricted tool allowlist (`--tools Read,Glob,Grep`
        // on sam-claude-advisor). Keep those turns on the raw proxy so PostToolUse
        // still compresses without elevating plan-only advisors to full tools.
        if let tools = scan.optionValues["--tools"]?.last
            ?? scan.optionValues["--allowed-tools"]?.last
            ?? scan.optionValues["--allowedTools"]?.last {
            let normalized = tools
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            let fullish: Set<String> = ["*", "default", "all"]
            if !normalized.isEmpty, normalized.allSatisfy({ !fullish.contains($0) }) {
                return false
            }
        }
        return scan.flags.contains("--print") || scan.flags.contains("-p")
    }

    private static func nestedClaudeAgentAppDelegation(
        arguments: [String],
        promptFile: String
    ) -> ProviderAgentAppDelegation? {
        guard nestedClaudeAgentAppEligible(arguments: arguments) else { return nil }
        let scan = scanNestedArguments(
            arguments,
            valueOptions: [
                "--model", "--effort", "--output-format", "--input-format",
                "--permission-mode", "--tools", "--allowed-tools", "--allowedTools",
                "--disallowed-tools", "--disallowedTools", "--append-system-prompt",
                "--system-prompt", "--setting-sources", "--settings",
                "--session-id", "--resume", "-r"
            ],
            flagOptions: [
                "--continue", "-c", "--debug", "--disable-slash-commands",
                "--fork-session", "--help", "-h", "--ide", "--include-partial-messages",
                "--no-session-persistence", "--print", "-p", "--strict-mcp-config",
                "--verbose", "--version", "-V"
            ]
        )
        guard !scan.malformed else { return nil }
        let model = scan.optionValues["--model"]?.last ?? ""
        let effort = AgentReasoningEffort(
            rawValue: scan.optionValues["--effort"]?.last ?? "medium"
        ) ?? .medium
        let permission = mapClaudePermission(
            scan.optionValues["--permission-mode"]?.last
        )
        let output: ProviderAgentAppOutputFormat = {
            switch (scan.optionValues["--output-format"]?.last ?? "").lowercased() {
            case "json": return .json
            case "grok-json": return .grokJSON
            default: return .text
            }
        }()
        return ProviderAgentAppDelegation(
            provider: .claude,
            promptFile: promptFile,
            model: model,
            reasoningEffort: effort == .ultracode ? .xhigh : effort,
            permissionMode: permission,
            outputFormat: output,
            runtimeProfile: nil
        )
    }

    private static func nestedClaudeInlinePrompt(arguments: [String]) -> String? {
        let scan = scanNestedArguments(
            arguments,
            valueOptions: [
                "--model", "--effort", "--output-format", "--input-format",
                "--permission-mode", "--tools", "--allowed-tools", "--allowedTools",
                "--disallowed-tools", "--disallowedTools", "--append-system-prompt",
                "--system-prompt", "--setting-sources", "--settings",
                "--session-id", "--resume", "-r"
            ],
            flagOptions: [
                "--continue", "-c", "--debug", "--disable-slash-commands",
                "--fork-session", "--help", "-h", "--ide", "--include-partial-messages",
                "--no-session-persistence", "--print", "-p", "--strict-mcp-config",
                "--verbose", "--version", "-V"
            ]
        )
        guard !scan.malformed else { return nil }
        // Prefer explicit positionals after flags (claude --print "prompt").
        let joined = scan.positionals.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func mapClaudePermission(_ raw: String?) -> AgentPermissionMode {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "acceptedits", "accept-edits", "auto", "workspace":
            return .autoAcceptEdits
        case "bypasspermissions", "bypass-permissions", "dontask", "full_access", "full-access":
            return .fullAccess
        default:
            return .supervised
        }
    }

    private static func nestedCodexAgentAppEligible(arguments: [String]) -> Bool {
        let scan = scanNestedArguments(
            arguments,
            valueOptions: [
                "--sandbox", "--ask-for-approval", "-a", "--config", "-c",
                "--model", "-m", "--image", "--color", "--cd", "-C",
                "--profile", "-p"
            ],
            flagOptions: [
                "--dangerously-bypass-approvals-and-sandbox", "--ephemeral",
                "--full-auto", "--help", "-h", "--ignore-user-config", "--json",
                "--oss", "--search", "--skip-git-repo-check", "--strict-config",
                "--version", "-V"
            ]
        )
        guard !scan.malformed else { return false }
        if scan.flags.contains("--version") || scan.flags.contains("-V")
            || scan.flags.contains("--help") || scan.flags.contains("-h") {
            return false
        }
        guard scan.positionals.first == "exec" else { return false }
        // `codex exec resume` is session continuation — keep raw.
        if scan.positionals.dropFirst().first == "resume" { return false }
        return true
    }

    private static func nestedCodexAgentAppDelegation(
        arguments: [String],
        promptFile: String
    ) -> ProviderAgentAppDelegation? {
        guard nestedCodexAgentAppEligible(arguments: arguments) else { return nil }
        let scan = scanNestedArguments(
            arguments,
            valueOptions: [
                "--sandbox", "--ask-for-approval", "-a", "--config", "-c",
                "--model", "-m", "--image", "--color", "--cd", "-C",
                "--profile", "-p"
            ],
            flagOptions: [
                "--dangerously-bypass-approvals-and-sandbox", "--ephemeral",
                "--full-auto", "--help", "-h", "--ignore-user-config", "--json",
                "--oss", "--search", "--skip-git-repo-check", "--strict-config",
                "--version", "-V"
            ]
        )
        guard !scan.malformed else { return nil }
        let model = scan.optionValues["--model"]?.last
            ?? scan.optionValues["-m"]?.last
            ?? ""
        let permission: AgentPermissionMode = {
            if scan.flags.contains("--dangerously-bypass-approvals-and-sandbox")
                || scan.flags.contains("--full-auto") {
                return .fullAccess
            }
            return .autoAcceptEdits
        }()
        let output: ProviderAgentAppOutputFormat =
            scan.flags.contains("--json") ? .json : .text
        return ProviderAgentAppDelegation(
            provider: .codex,
            promptFile: promptFile,
            model: model,
            reasoningEffort: .medium,
            permissionMode: permission,
            outputFormat: output,
            runtimeProfile: nil
        )
    }

    private static func nestedCodexInlinePrompt(arguments: [String]) -> String? {
        let scan = scanNestedArguments(
            arguments,
            valueOptions: [
                "--sandbox", "--ask-for-approval", "-a", "--config", "-c",
                "--model", "-m", "--image", "--color", "--cd", "-C",
                "--profile", "-p"
            ],
            flagOptions: [
                "--dangerously-bypass-approvals-and-sandbox", "--ephemeral",
                "--full-auto", "--help", "-h", "--ignore-user-config", "--json",
                "--oss", "--search", "--skip-git-repo-check", "--strict-config",
                "--version", "-V"
            ]
        )
        guard !scan.malformed, scan.positionals.first == "exec" else { return nil }
        let rest = scan.positionals.dropFirst().filter { $0 != "resume" }
        let joined = rest.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func nestedGrokAgentAppEligible(arguments: [String]) -> Bool {
        if samGrokWorkerAgentAppDelegation(
            providerBasename: "grok",
            arguments: arguments
        ) != nil {
            return true
        }
        let scan = scanNestedArguments(
            arguments,
            valueOptions: [
                "--prompt-file", "--prompt", "-p", "--rules",
                "--permission-mode", "--sandbox", "--model", "-m",
                "--effort", "--reasoning-effort", "--output-format",
                "--input-format", "--disallowed-tools", "--allowed-tools",
                "--settings", "--resume", "-r", "--session-id"
            ],
            flagOptions: [
                "--always-approve", "--auto-update", "--continue",
                "--help", "-h", "--list-models", "--memory", "--no-auto-update",
                "--no-memory", "--no-plan", "--no-subagents", "--plan",
                "--subagents", "--version", "-V"
            ]
        )
        guard !scan.malformed else { return false }
        if scan.flags.contains("--version") || scan.flags.contains("-V")
            || scan.flags.contains("--help") || scan.flags.contains("-h")
            || scan.flags.contains("--list-models") {
            return false
        }
        if !scan.flags.isDisjoint(with: ["--resume", "-r", "--continue", "--session-id", "--fork-session"]) {
            return false
        }
        // Agent turn needs an explicit prompt channel (file, flag, or stdin later).
        let hasPromptChannel =
            scan.optionValues["--prompt-file"]?.contains(where: { !$0.isEmpty }) == true
            || scan.optionValues["--prompt"]?.contains(where: { !$0.isEmpty }) == true
            || scan.optionValues["-p"]?.contains(where: { !$0.isEmpty }) == true
            || !scan.positionals.isEmpty
        // Empty positionals + no prompt flags still eligible if stdin will supply prompt
        // (headless agent patterns). Require at least model or always-approve/sandbox
        // agent shape — not bare `grok` with nothing.
        if hasPromptChannel { return true }
        return scan.optionValues["--model"]?.isEmpty == false
            || scan.flags.contains("--always-approve")
            || scan.optionValues["--sandbox"] != nil
    }

    private static func nestedGrokAgentAppDelegation(
        arguments: [String],
        promptFile: String
    ) -> ProviderAgentAppDelegation? {
        if let exact = samGrokWorkerAgentAppDelegation(
            providerBasename: "grok",
            arguments: arguments
        ) {
            return exact
        }
        guard nestedGrokAgentAppEligible(arguments: arguments) else { return nil }
        let scan = scanNestedArguments(
            arguments,
            valueOptions: [
                "--prompt-file", "--prompt", "-p", "--rules",
                "--permission-mode", "--sandbox", "--model", "-m",
                "--effort", "--reasoning-effort", "--output-format",
                "--input-format", "--disallowed-tools", "--allowed-tools",
                "--settings", "--resume", "-r", "--session-id"
            ],
            flagOptions: [
                "--always-approve", "--auto-update", "--continue",
                "--help", "-h", "--list-models", "--memory", "--no-auto-update",
                "--no-memory", "--no-plan", "--no-subagents", "--plan",
                "--subagents", "--version", "-V"
            ]
        )
        guard !scan.malformed else { return nil }
        let model = scan.optionValues["--model"]?.last
            ?? scan.optionValues["-m"]?.last
            ?? "grok-4.5"
        let effortRaw = scan.optionValues["--effort"]?.last
            ?? scan.optionValues["--reasoning-effort"]?.last
            ?? "medium"
        let effort = AgentReasoningEffort(rawValue: effortRaw) ?? .medium
        let permission: AgentPermissionMode = {
            if scan.flags.contains("--always-approve") { return .fullAccess }
            switch (scan.optionValues["--permission-mode"]?.last ?? "").lowercased() {
            case "acceptedits", "accept-edits", "auto", "workspace":
                return .autoAcceptEdits
            case "full_access", "full-access", "bypasspermissions":
                return .fullAccess
            default:
                return .supervised
            }
        }()
        let output: ProviderAgentAppOutputFormat = {
            switch (scan.optionValues["--output-format"]?.last ?? "").lowercased() {
            case "json": return .json
            case "grok-json": return .grokJSON
            default: return .text
            }
        }()
        return ProviderAgentAppDelegation(
            provider: .grok,
            promptFile: promptFile,
            model: model,
            reasoningEffort: effort,
            permissionMode: permission,
            outputFormat: output,
            runtimeProfile: nil
        )
    }

    private static func nestedGrokInlinePrompt(arguments: [String]) -> String? {
        let scan = scanNestedArguments(
            arguments,
            valueOptions: [
                "--prompt-file", "--prompt", "-p", "--rules",
                "--permission-mode", "--sandbox", "--model", "-m",
                "--effort", "--reasoning-effort", "--output-format",
                "--input-format", "--disallowed-tools", "--allowed-tools",
                "--settings", "--resume", "-r", "--session-id"
            ],
            flagOptions: [
                "--always-approve", "--auto-update", "--continue",
                "--help", "-h", "--list-models", "--memory", "--no-auto-update",
                "--no-memory", "--no-plan", "--no-subagents", "--plan",
                "--subagents", "--version", "-V"
            ]
        )
        guard !scan.malformed else { return nil }
        if let prompt = scan.optionValues["--prompt"]?.last
            ?? scan.optionValues["-p"]?.last {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let joined = scan.positionals.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private struct NestedArgScan {
        var flags = Set<String>()
        var optionValues: [String: [String]] = [:]
        var positionals: [String] = []
        var malformed = false
    }

    private static func scanNestedArguments(
        _ arguments: [String],
        valueOptions: Set<String>,
        flagOptions: Set<String>
    ) -> NestedArgScan {
        let optionBoundary = arguments.firstIndex(of: "--") ?? arguments.endIndex
        var scan = NestedArgScan()
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
            if let option = valueOptions.first(where: { argument.hasPrefix("\($0)=") }) {
                scan.flags.insert(option)
                scan.optionValues[option, default: []].append(
                    String(argument.dropFirst(option.count + 1))
                )
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                guard flagOptions.contains(argument) else {
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
        if optionBoundary < arguments.count {
            // Everything after `--` is prompt content for some CLIs.
            let tail = arguments[(optionBoundary + 1)...].joined(separator: " ")
            if !tail.isEmpty { scan.positionals.append(tail) }
        }
        return scan
    }

    /// Target provider for the explicit `remote-code agent-app …` ABI. Parse
    /// only rc2's documented leading global flags so prompt text containing
    /// `agent-app <provider>` can never be mistaken for command metadata.
    public static func agentAppProvider(arguments: [String]) -> AgentProvider? {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--socket", "--timeout":
                guard index + 1 < arguments.count else { return nil }
                index += 2
            case "--json":
                index += 1
            case "--":
                index += 1
                guard index < arguments.count else { return nil }
                fallthrough
            default:
                guard arguments[index] == "agent-app",
                      index + 1 < arguments.count else {
                    return nil
                }
                return AgentProvider(rawValue: arguments[index + 1])
            }
        }
        return nil
    }

    public static func agentAppSocketPath(
        environment: [String: String],
        bundledSocketPath: String?
    ) -> String? {
        if let explicit = environment["RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        guard let bundledSocketPath = bundledSocketPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !bundledSocketPath.isEmpty else {
            return nil
        }
        return bundledSocketPath
    }

    // MARK: - raw provider usage

    /// Raw provider invocations retain their exact CLI ABI. The bounded
    /// exceptions where usage can be observed without changing that ABI are
    /// Grok's prompt-file JSON result and Claude's print-mode JSON result:
    /// stdout can be tee'd byte for byte while the finalized object is parsed
    /// for provider-reported usage.
    public static func usageCaptureFormat(
        providerBasename: String,
        arguments: [String]
    ) -> ProviderProxyUsageCaptureFormat? {
        let provider = commandBasename(providerBasename)
        if provider == AgentProvider.codex.rawValue {
            // `codex exec --json` is a documented non-interactive JSONL ABI.
            // Resume is intentionally excluded because its usage is cumulative
            // over a pre-existing provider session.
            guard arguments.first == "exec" else { return nil }
            let valueFlags: Set<String> = [
                "--config", "-c", "--image", "-i", "--model", "-m",
                "--profile", "-p", "--sandbox", "-s", "--cd", "-C",
                "--add-dir", "--local-provider", "--output-schema",
                "--color", "--output-last-message", "-o"
            ]
            var sawJSON = false
            var firstPositional: String?
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" { break }
                if argument == "--json" {
                    sawJSON = true
                    index += 1
                    continue
                }
                if valueFlags.contains(argument) {
                    guard index + 1 < arguments.count else { return nil }
                    index += 2
                    continue
                }
                if let equals = argument.firstIndex(of: "="),
                   valueFlags.contains(String(argument[..<equals])) {
                    index += 1
                    continue
                }
                if !argument.hasPrefix("-") {
                    firstPositional = argument
                    break
                }
                index += 1
            }
            guard firstPositional != "resume" else { return nil }
            return sawJSON ? .codexJSONLines : nil
        }

        let valueFlags: Set<String>
        let booleanFlags: Set<String>
        switch provider {
        case AgentProvider.grok.rawValue:
            valueFlags = [
                "--prompt-file", "-p", "--model", "-m", "--effort",
                "--reasoning-effort", "--output-format", "--sandbox",
                "--permission-mode", "--disallowed-tools", "--allowed-tools", "--rules"
            ]
            booleanFlags = [
                "--always-approve", "--no-memory", "--no-subagents",
                "--no-auto-update"
            ]
        case AgentProvider.claude.rawValue:
            valueFlags = [
                "--model", "--effort", "--permission-mode", "--tools",
                "--allowedTools", "--disallowedTools", "--output-format",
                "--input-format", "--append-system-prompt", "--system-prompt",
                "--setting-sources", "--settings"
            ]
            booleanFlags = [
                "--print", "-p", "--no-session-persistence", "--verbose"
            ]
        default:
            return nil
        }

        let continuationFlags: Set<String> = [
            "--resume", "-r", "--continue", "-c", "--session-id",
            "--resume-session", "--conversation-id", "--thread-id",
            "--fork-session"
        ]
        var promptFile: String?
        var promptArgumentCount = 0
        var outputFormat: String?
        var printFlagCount = 0
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            // A terminator changes every following token into provider-owned
            // positional input. Piping stdout in that shape could change TTY or
            // interactive behavior, so usage capture must stay off.
            guard argument != "--" else { return nil }

            let flagName = argument.split(separator: "=", maxSplits: 1)
                .first.map(String.init) ?? argument
            guard !continuationFlags.contains(flagName) else {
                // Final JSON on resumed/continued sessions is cumulative and
                // cannot be attributed as a fresh Token Saver run.
                return nil
            }
            if provider == AgentProvider.claude.rawValue,
               (argument == "--print" || argument == "-p") {
                guard booleanFlags.contains(argument) else { return nil }
                printFlagCount += 1
                index += 1
                continue
            }

            if valueFlags.contains(argument) {
                guard index + 1 < arguments.count else {
                    return nil
                }
                let value = arguments[index + 1]
                if argument == "--prompt-file" {
                    guard promptFile == nil, value.hasPrefix("/") else { return nil }
                    promptFile = value
                } else if argument == "-p" {
                    promptArgumentCount += 1
                } else if argument == "--output-format" {
                    guard outputFormat == nil, !value.isEmpty else { return nil }
                    outputFormat = value
                }
                index += 2
                continue
            }

            if let equals = argument.firstIndex(of: "=") {
                let flag = String(argument[..<equals])
                let value = String(argument[argument.index(after: equals)...])
                guard valueFlags.contains(flag) else { return nil }
                if flag == "--prompt-file" {
                    guard promptFile == nil, value.hasPrefix("/") else { return nil }
                    promptFile = value
                } else if flag == "-p" {
                    promptArgumentCount += 1
                } else if flag == "--output-format" {
                    guard outputFormat == nil, !value.isEmpty else { return nil }
                    outputFormat = value
                }
                index += 1
                continue
            }

            guard booleanFlags.contains(argument) else {
                // Unknown flags/positionals may alter output or interactivity.
                return nil
            }
            index += 1
        }
        switch provider {
        case AgentProvider.grok.rawValue:
            guard promptFile != nil || promptArgumentCount == 1,
                  printFlagCount == 0 else {
                return nil
            }
            switch outputFormat {
            case "json": return .grokJSON
            case "streaming-json": return .grokJSONLines
            default: return nil
            }
        case AgentProvider.claude.rawValue:
            guard promptFile == nil, printFlagCount == 1 else { return nil }
            switch outputFormat {
            case "json": return .claudeJSON
            case "stream-json": return .claudeJSONLines
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Parse only provider-reported usage from Grok's finalized JSON object.
    /// Prompt/result content is neither returned nor persisted.
    public static func grokJSONTokenUsage(from data: Data) -> AssistantTokenUsage? {
        providerJSONTokenUsage(from: data, provider: .grok)
    }

    /// Parse provider billing from Claude's non-interactive `--print
    /// --output-format json` result. This mirrors the Agent App parser's
    /// preference for cumulative `modelUsage` and never returns result content.
    public static func claudeJSONTokenUsage(from data: Data) -> AssistantTokenUsage? {
        providerJSONTokenUsage(from: data, provider: .claude)
    }

    /// Parse one complete JSONL event. Only provider-reported token fields are
    /// accepted; text length and event counts are never converted into tokens.
    public static func streamJSONTokenUsage(
        from data: Data,
        provider: AgentProvider
    ) -> AssistantTokenUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            return nil
        }
        switch provider {
        case .codex:
            let type = (object["type"] as? String ?? "").lowercased()
            if type == "thread.token_usage" || type == "token_usage" {
                var wrapper: [String: Any] = ["usage": object]
                if let cost = object["total_cost_usd"] ?? object["totalCostUSD"] {
                    wrapper["total_cost_usd"] = cost
                }
                return providerJSONTokenUsage(object: wrapper, provider: .codex)
            }
            guard object["usage"] != nil || object["token_usage"] != nil else {
                return nil
            }
            return providerJSONTokenUsage(object: object, provider: .codex)
        case .claude:
            let type = (object["type"] as? String ?? "").lowercased()
            if type == "assistant",
               let message = object["message"] as? [String: Any],
               let messageUsage = message["usage"] as? [String: Any],
               var usage = providerJSONTokenUsage(
                   object: ["usage": messageUsage],
                   provider: .claude
               ) {
                usage.semantics = .incremental
                return usage
            }
            guard type == "result"
                    || object["modelUsage"] != nil
                    || object["model_usage"] != nil else {
                return nil
            }
            return providerJSONTokenUsage(object: object, provider: .claude)
        case .grok:
            guard object["usage"] != nil
                    || object["token_usage"] != nil
                    || object["modelUsage"] != nil
                    || object["model_usage"] != nil else {
                return nil
            }
            return providerJSONTokenUsage(object: object, provider: .grok)
        }
    }

    private static func providerJSONTokenUsage(
        from data: Data,
        provider: AgentProvider
    ) -> AssistantTokenUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return providerJSONTokenUsage(object: object, provider: provider)
    }

    private static func providerJSONTokenUsage(
        object: [String: Any],
        provider: AgentProvider
    ) -> AssistantTokenUsage? {
        if let modelUsage = object["modelUsage"] as? [String: Any]
            ?? object["model_usage"] as? [String: Any] {
            var uncached = 0
            var cacheCreation = 0
            var cacheRead = 0
            var output = 0
            var contextWindow: Int?
            var modelCostUSD = 0.0
            var modelCostComplete = true
            var modelCount = 0
            for value in modelUsage.values {
                guard let usage = value as? [String: Any] else { continue }
                modelCount += 1
                guard let nextUncached = checkedAdd(
                    uncached,
                    nonnegativeInt(usage["inputTokens"] ?? usage["input_tokens"]) ?? 0
                ),
                let nextCacheCreation = checkedAdd(
                    cacheCreation,
                    nonnegativeInt(
                    usage["cacheCreationInputTokens"] ?? usage["cache_creation_input_tokens"]
                    ) ?? 0
                ),
                let nextCacheRead = checkedAdd(
                    cacheRead,
                    nonnegativeInt(
                    usage["cacheReadInputTokens"] ?? usage["cache_read_input_tokens"]
                    ) ?? 0
                ),
                let nextOutput = checkedAdd(
                    output,
                    nonnegativeInt(usage["outputTokens"] ?? usage["output_tokens"]) ?? 0
                ) else {
                    return nil
                }
                uncached = nextUncached
                cacheCreation = nextCacheCreation
                cacheRead = nextCacheRead
                output = nextOutput
                if let cost = finiteNonnegativeDouble(
                    usage["costUSD"] ?? usage["cost_usd"]
                ) {
                    modelCostUSD += cost
                    if !modelCostUSD.isFinite {
                        modelCostComplete = false
                    }
                } else {
                    modelCostComplete = false
                }
                if let window = nonnegativeInt(
                    usage["contextWindow"] ?? usage["context_window"]
                ) {
                    contextWindow = max(contextWindow ?? 0, window)
                }
            }
            if provider == .grok, cacheRead == 0,
               let usage = object["usage"] as? [String: Any] {
                cacheRead = nonnegativeInt(
                    usage["cache_read_input_tokens"] ?? usage["cacheReadInputTokens"]
                ) ?? 0
            }
            guard let input = checkedSum([uncached, cacheCreation, cacheRead]),
                  let total = checkedAdd(input, output) else {
                return nil
            }
            guard modelCount > 0, total > 0 || contextWindow != nil else { return nil }
            let cost = reportedCostMicros(object: object)
                ?? (modelCostComplete ? costMicros(fromUSD: modelCostUSD) : nil)
            return AssistantTokenUsage(
                inputTokens: input,
                outputTokens: output,
                totalTokens: total,
                contextWindow: contextWindow,
                uncachedInputTokens: uncached,
                cacheCreationInputTokens: cacheCreation > 0 ? cacheCreation : nil,
                cacheReadInputTokens: cacheRead > 0 ? cacheRead : nil,
                reportedCostMicros: cost,
                contextTokens: nil,
                semantics: .cumulative
            )
        }

        guard let usage = object["usage"] as? [String: Any]
            ?? object["token_usage"] as? [String: Any] else {
            return nil
        }
        let reportedInput = nonnegativeInt(
            usage["input_tokens"] ?? usage["inputTokens"]
        ) ?? 0
        let cacheCreation = nonnegativeInt(
            usage["cache_creation_input_tokens"] ?? usage["cacheCreationInputTokens"]
        ) ?? 0
        let cacheRead = nonnegativeInt(
            usage["cache_read_input_tokens"] ?? usage["cacheReadInputTokens"]
                ?? usage["cached_input_tokens"] ?? usage["cachedInputTokens"]
        ) ?? 0
        let output = nonnegativeInt(
            usage["output_tokens"] ?? usage["outputTokens"]
        ) ?? 0
        let reasoning = nonnegativeInt(
            usage["reasoning_tokens"] ?? usage["reasoningTokens"]
        ) ?? 0
        let uncached: Int
        let input: Int
        if provider == .codex {
            // Codex reports cached input as a subset of input_tokens.
            input = reportedInput
            uncached = max(0, reportedInput - cacheRead)
        } else {
            uncached = reportedInput
            guard let summedInput = checkedSum([uncached, cacheCreation, cacheRead]) else {
                return nil
            }
            input = summedInput
        }
        // Providers may expose reasoning as a subset of output, or as the only
        // output counter. Taking the larger value covers both shapes without
        // billing the same reasoning tokens twice when total_tokens is absent.
        let billedOutput = max(output, reasoning)
        guard let computedTotal = checkedAdd(input, billedOutput) else { return nil }
        let total = nonnegativeInt(
            usage["total_tokens"] ?? usage["totalTokens"]
        ) ?? computedTotal
        guard total > 0 || input > 0 || output > 0 else { return nil }
        guard let contextTokens = checkedAdd(input, billedOutput) else { return nil }
        return AssistantTokenUsage(
            inputTokens: input,
            outputTokens: billedOutput,
            totalTokens: total,
            contextWindow: nonnegativeInt(
                usage["context_window"] ?? usage["contextWindow"]
            ),
            uncachedInputTokens: uncached,
            cacheCreationInputTokens: cacheCreation > 0 ? cacheCreation : nil,
            cacheReadInputTokens: cacheRead > 0 ? cacheRead : nil,
            reportedCostMicros: reportedCostMicros(object: object),
            contextTokens: contextTokens > 0 ? contextTokens : nil,
            semantics: .cumulative
        )
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private static func checkedSum(_ values: [Int]) -> Int? {
        values.reduce(Optional(0)) { partial, value in
            partial.flatMap { checkedAdd($0, value) }
        }
    }

    private static func nonnegativeInt(_ value: Any?) -> Int? {
        let parsed: Int?
        switch value {
        case let int as Int:
            parsed = int
        case let number as NSNumber:
            let double = number.doubleValue
            parsed = double.isFinite
                && double.rounded(.towardZero) == double
                && double < Double(Int.max)
                ? Int(double)
                : nil
        case let string as String:
            parsed = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            parsed = nil
        }
        guard let parsed, parsed >= 0 else { return nil }
        return parsed
    }

    private static func reportedCostMicros(object: [String: Any]) -> Int? {
        let usage = object["usage"] as? [String: Any]
        let usd: Double?
        if let value = finiteNonnegativeDouble(
            object["total_cost_usd"] ?? object["totalCostUSD"]
                ?? usage?["cost_usd"] ?? usage?["costUSD"]
        ) {
            usd = value
        } else if let ticks = finiteNonnegativeDouble(
            usage?["cost_in_usd_ticks"] ?? usage?["costInUsdTicks"]
        ) {
            usd = ticks / 10_000_000_000
        } else {
            usd = nil
        }
        return costMicros(fromUSD: usd)
    }

    private static func costMicros(fromUSD usd: Double?) -> Int? {
        guard let usd else { return nil }
        let micros = (usd * 1_000_000).rounded()
        guard micros.isFinite, micros <= Double(Int.max) else { return nil }
        return Int(micros)
    }

    private static func finiteNonnegativeDouble(_ value: Any?) -> Double? {
        let parsed: Double?
        switch value {
        case let double as Double:
            parsed = double
        case let number as NSNumber:
            parsed = number.doubleValue
        case let string as String:
            parsed = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            parsed = nil
        }
        guard let parsed, parsed.isFinite, parsed >= 0 else { return nil }
        return parsed
    }

    // MARK: - node id (bounded, content-free)

    /// Stable bounded node id: provider + invocation metadata only.
    /// Never includes argv prompt text, file contents, or secrets.
    public static func makeNodeId(
        providerBasename: String,
        processIdentifier: Int32,
        monotonicNanos: UInt64
    ) -> String {
        let provider = sanitizeToken(commandBasename(providerBasename), fallback: "provider")
        let pid = max(0, processIdentifier)
        let hex = String(monotonicNanos, radix: 16)
        let raw = "nested.\(provider).\(pid).\(hex)"
        return String(raw.prefix(128))
    }

    private static func sanitizeToken(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return fallback }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let filtered = String(trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
        return filtered.isEmpty ? fallback : filtered
    }

    // MARK: - exit status → AgentRunStatus

    /// Map a child process termination to Subagents receipt status.
    /// - exit 0 → completed
    /// - SIGINT / SIGTERM (uncaught signal) → cancelled
    /// - any other nonzero / signal → failed
    public static func runStatus(
        wasUncaughtSignal: Bool,
        terminationStatus: Int32,
        forwardedSignal: Int32? = nil
    ) -> AgentRunStatus {
        if let forwardedSignal, forwardedSignal == SIGINT || forwardedSignal == SIGTERM {
            return .cancelled
        }
        if wasUncaughtSignal {
            if terminationStatus == SIGINT || terminationStatus == SIGTERM {
                return .cancelled
            }
            return .failed
        }
        if terminationStatus == 0 {
            return .completed
        }
        return .failed
    }

    // MARK: - real-binary resolution (recursion guard)

    /// Resolve the real provider executable, skipping the managed bin and any
    /// candidate that resolves to this proxy binary itself.
    public static func resolveRealExecutable(
        command: String,
        pathEntries: [String],
        managedBinDirectory: String,
        isExecutableFile: (String) -> Bool,
        resolvesToSelf: (String) -> Bool
    ) -> String? {
        CommandWrapPolicy.resolveRealExecutable(
            command: command,
            pathEntries: pathEntries,
            managedBinDirectory: managedBinDirectory,
            isExecutableFile: isExecutableFile,
            resolvesToSelf: resolvesToSelf
        )
    }

    /// Whether a PATH candidate under the managed bin is a provider proxy shim
    /// that host launchers must skip so top-level turns use the real CLI.
    public static func isManagedProviderProxyPath(
        command: String,
        candidatePath: String,
        managedBinDirectory: String,
        symlinkDestination: (String) -> String?
    ) -> Bool {
        guard isProviderProxy(command) else { return false }
        let managed = normalizedDirectory(managedBinDirectory)
        let candidateDir = normalizedDirectory((candidatePath as NSString).deletingLastPathComponent)
        guard candidateDir == managed else { return false }
        // Symlink to our service (or any non-regular destination we own) counts.
        if let dest = symlinkDestination(candidatePath) {
            let base = (dest as NSString).lastPathComponent
            if base == "RemoteCodeDistillService" || dest.contains("RemoteCodeDistillService") {
                return true
            }
            // Any symlink we placed in managed bin for a provider basename is a proxy.
            return true
        }
        return false
    }

    private static func normalizedDirectory(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
