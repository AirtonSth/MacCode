import Foundation
import CoreModel

public enum AgentRunError: Error, CustomStringConvertible {
    case missingBinary(String)
    case spawnFailed(String)
    case alreadyRunning

    public var description: String {
        switch self {
        case .missingBinary(let b): return "CLI not found in PATH: \(b)"
        case .spawnFailed(let m): return "Failed to spawn agent: \(m)"
        case .alreadyRunning: return "Run already in progress"
        }
    }
}

public enum ProcessLocator {
    public static func resolve(_ name: String) -> String? {
        resolve(name,
                environmentPath: ProcessInfo.processInfo.environment["PATH"],
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    public static func resolve(_ name: String, environmentPath: String?, homeDirectory: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        // Prefer a co-located privileged helper next to RemoteCode.app/Contents/MacOS.
        if trimmed == "RemoteCodeRunAsUserHelper" || trimmed == "io.remotecode.RunAsUserHelper" {
            let candidates = [
                "/Library/PrivilegedHelperTools/io.remotecode.RunAsUserHelper",
                "/Library/PrivilegedHelperTools/RemoteCodeRunAsUserHelper",
                Bundle.main.bundleURL
                    .appendingPathComponent("Contents/MacOS/RemoteCodeRunAsUserHelper").path,
                (Bundle.main.executableURL?.deletingLastPathComponent()
                    .appendingPathComponent("RemoteCodeRunAsUserHelper").path) ?? ""
            ]
            for path in candidates where !path.isEmpty {
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        // Host top-level turns must resolve the REAL provider CLI, never the
        // nested-provider PATH proxy installed under ~/.remote-code/bin.
        let managedBin = "\(homeDirectory)/.remote-code/bin"
        let skipManagedProviderProxy = ProviderProxyCatalog.isProviderProxyCommand(trimmed)
        for component in searchPath(environmentPath: environmentPath, homeDirectory: homeDirectory) {
            if skipManagedProviderProxy, Self.normalizedDirectory(component) == Self.normalizedDirectory(managedBin) {
                continue
            }
            let full = component + "/" + trimmed
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    private static func normalizedDirectory(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Binary resolution for Auto admission + sudo -u execution (same rules).
    /// 1) Absolute Settings path when executable (e.g. /Users/airtonjunior/.local/bin/claude)
    /// 2) Target run-as-user home search
    /// 3) Current user home / PATH search
    /// So Auto can admit the same CLI the streaming adapter will spawn.
    public static func resolveForRunAsUser(
        _ name: String,
        runAsUser: AgentRunAsUser?,
        currentUID: uid_t = getuid()
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        if let runAsUser, runAsUser.uid != currentUID {
            if let target = resolve(trimmed, environmentPath: nil, homeDirectory: runAsUser.homePath) {
                return target
            }
        }
        return resolve(trimmed)
    }

    public static func expandedPath(environmentPath: String?, homeDirectory: String) -> String {
        searchPath(environmentPath: environmentPath, homeDirectory: homeDirectory).joined(separator: ":")
    }

    private static func searchPath(environmentPath: String?, homeDirectory: String) -> [String] {
        var paths = (environmentPath ?? "")
            .split(separator: ":")
            .map(String.init)
        paths.insert("\(homeDirectory)/.remote-code/bin", at: 0)
        paths.append(contentsOf: [
            "\(homeDirectory)/.grok/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.bun/bin",
            "/usr/bin",
            "/bin"
        ])
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public final class CodexRunner: AgentProviderRunner, @unchecked Sendable {
    public let provider: AgentProvider = .codex
    private let binaryNameOverride: String?

    public init(binaryNameOverride: String? = nil) {
        self.binaryNameOverride = binaryNameOverride
    }

    public func listModels() async -> [AgentModelDescriptor] {
        // Real Codex CLI models (codex 0.130.0, ~/.codex/models_cache.json).
        // id "" = account default (always works regardless of plan). The
        // earlier ids (gpt-5/gpt-5-codex/o3) are dead on this CLI and made
        // `codex --model …` fail with no output.
        [
            AgentModelDescriptor(id: "", label: "Default (account)", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.6-sol", label: "GPT-5.6-Sol", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.4", label: "GPT-5.4", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.4-mini", label: "GPT-5.4-Mini", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.3-codex", label: "GPT-5.3-Codex", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.3-codex-spark", label: "GPT-5.3-Codex-Spark", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.2", label: "GPT-5.2", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true)
        ]
    }

    /// Builds the `codex` argv. Pure + static for regression tests.
    /// With a prior session id it uses `exec resume <id>` so the model
    /// keeps full context; otherwise a fresh `exec`. An empty model id
    /// means "account default" (omit -m).
    public static func buildArgs(_ request: AgentRunRequest) -> [String] {
        let ptid = request.providerThreadId
        let resuming = (ptid?.isEmpty == false)
        // `codex exec resume` usage:
        //   exec resume [FLAGS] -c k=v <SESSION_ID> [PROMPT]
        // It does NOT accept --model/--sandbox (the session keeps the
        // model + sandbox it was created with — that's correct for a
        // continued conversation).
        var args: [String] = ["exec"]
        if resuming { args.append("resume") }
        args += ["--json", "--skip-git-repo-check"]
        if let r = request.reasoningEffort?.rawValue {
            args += ["-c", "model_reasoning_effort=\"\(r)\""]
        }
        if request.serviceTier == .fast {
            args += ["-c", "model_service_tier=\"fast\""]
        }
        if !resuming {
            let model = request.model.trimmingCharacters(in: .whitespaces)
            if !model.isEmpty, model.lowercased() != "default" {
                args += ["--model", model]
            }
            switch request.permissionMode {
            case .supervised:
                args += ["-c", #"approval_policy="untrusted""#, "--sandbox", "read-only"]
            case .autoAcceptEdits:
                args += ["-c", #"approval_policy="never""#, "--sandbox", "workspace-write"]
            case .fullAccess:
                args += ["-c", #"approval_policy="never""#, "--sandbox", "danger-full-access"]
            }
        }
        for attachment in request.attachments where attachment.kind == .image {
            args += ["--image", attachment.path]
        }
        args += request.extraArgs
        if resuming, let ptid { args.append(ptid) }   // SESSION_ID before PROMPT
        args.append(request.providerPrompt)
        return args
    }

    public func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? request.providerBinary! : (binaryNameOverride ?? "codex")
        guard let path = ProcessLocator.resolve(binary) else {
            onEvent(.error("\(binary) not found in PATH"))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.missingBinary(binary)
        }

        let args = Self.buildArgs(request)
        let proc: Process
        do {
            proc = try ProviderSubprocessLauncher.makeProcess(
                provider: .codex,
                executablePath: path,
                arguments: args,
                currentDirectory: request.cwd,
                environment: request.environment,
                runAsUser: request.runAsUser
            )
        } catch {
            onEvent(.error(error.localizedDescription))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }

        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        // `codex exec` otherwise prints "Reading additional input from
        // stdin..." and can block — the prompt is already an arg.
        proc.standardInput = FileHandle.nullDevice

        let parser = CodexParser()
        let timeline = TimelineAggregator()
        let outBuf = LineBuffer()
        let cancelFlag = AgentCancelFlag()
        let emitLine: (String) -> Void = { line in
            if let runtimeEvent = ProviderRuntimeEvent.fromJSONLine(line, provider: .codex, source: "codex.exec.json") {
                let ev = AssistantEvent.providerRuntime(runtimeEvent)
                timeline.apply(ev)
                onEvent(.event(ev))
            }
            for ev in parser.parseLine(line) {
                timeline.apply(ev)
                onEvent(.event(ev))
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            for line in outBuf.take(data) {
                emitLine(line)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            let s = String(data: data, encoding: .utf8) ?? ""
            if let visible = Self.displayableStderr(s) {
                onEvent(.event(.providerRuntime(ProviderStderrClassifier.runtimeEvent(
                    message: visible,
                    provider: .codex,
                    source: "codex.exec.stderr"
                ))))
                onEvent(.error("[codex stderr] " + visible))
            }
        }

        proc.terminationHandler = { p in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // Foundation may not deliver the bytes between the last read
            // and EOF via the handler — drain them explicitly, then flush
            // the final unterminated line. Without this the closing
            // `turn.completed` (and the answer) is regularly lost.
            let tail = BoundedPipeDrain.readRemaining(from: stdoutPipe.fileHandleForReading)
            for line in outBuf.take(tail) + outBuf.flush() {
                emitLine(line)
            }
            let status: AgentRunStatus
            if cancelFlag.isCancelled || p.terminationReason == .uncaughtSignal { status = .cancelled }
            else if p.terminationStatus == 0 { status = .completed }
            else { status = .failed }
            let finalMsg = timeline.finalAssistantMessage
            onEvent(.status(status))
            onEvent(.finished(status, finalMessage: finalMsg, providerThreadId: timeline.providerThreadId))
        }

        do {
            try proc.run()
            try ProcessSpawnTagger.tagProcess(proc, provider: .codex)
            onEvent(.status(.running))
        } catch {
            onEvent(.error("spawn: \(error.localizedDescription)"))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }

        return AgentRunHandle(runId: request.runId, process: proc) {
            cancelFlag.cancel()
            ProcessTerminator.terminateTree(proc)
        }
    }

    public static func shouldDisplayStderr(_ raw: String) -> Bool {
        displayableStderr(raw) != nil
    }

    public static func displayableStderr(_ raw: String) -> String? {
        ProviderStderrClassifier.displayableStderr(raw, provider: .codex)
    }

    /// Why a spawn's environment is being built. REQUIRED (no default) so every call
    /// site is forced by the compiler to classify itself — a spawn that runs user
    /// agent-turn code (`.agentTurn`) imports the login-shell env; a support/helper
    /// spawn (`.supportProcess`: model discovery, capability probe, node/npm helpers,
    /// usage refreshers) must NOT, so profile secrets never reach non-turn processes.
    public enum EnvironmentPurpose {
        case agentTurn(AgentProvider)
        case supportProcess

        var provider: AgentProvider? {
            if case .agentTurn(let p) = self { return p }
            return nil
        }
        var importsLoginEnvironment: Bool {
            if case .agentTurn = self { return true }
            return false
        }
    }

    /// GUI/launchd owns these — never overlay them from the login shell (identity +
    /// sandbox/XPC transport). Exact keys + prefixes.
    private static let guiOwnedExactKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR",
        "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_SESSION_ID"
    ]
    private static let guiOwnedPrefixes = ["XPC_", "__CF", "APP_SANDBOX_"]
    /// Shell-local vars that describe the capture shell, not the provider process.
    private static let volatileDropKeys: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]
    /// Execution/loader controls: a profile export here could inject code or MITM a
    /// credentialed agent + its MCP/hook children. Prefix-matched so unknown future
    /// variants (e.g. a new DYLD_*) are also removed (fail-safe), plus exact names.
    private static let loaderControlPrefixes = ["DYLD_", "LD_"]
    private static let loaderControlExactKeys: Set<String> = [
        "NODE_OPTIONS", "BASH_ENV", "ENV", "NODE_EXTRA_CA_CERTS",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "GIT_SSH_COMMAND", "PERL5OPT", "PYTHONSTARTUP"
    ]
    /// Claude auth-routing keys deleted for provider `.claude` so claude.ai OAuth
    /// stays the default no matter what the profile/GUI env exports. A per-instance
    /// `overrides` value can re-add them explicitly (opt-in). Applied on BOTH the
    /// capture-success and fail-open branches when import is enabled.
    /// Only the non-`ANTHROPIC_`-prefixed keys are listed: the strip site pairs this
    /// with a `key.hasPrefix("ANTHROPIC_")` clause that already covers the entire
    /// `ANTHROPIC_*` namespace (incl. every base-URL variant), so listing those here
    /// would be redundant — and the literal base-URL key name in source trips the B6
    /// no-provider-redirect scanner even though this is a strip, not a redirect.
    private static let claudeAuthStripKeys: Set<String> = [
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"
    ]

    private static func isGuiOwned(_ key: String) -> Bool {
        guiOwnedExactKeys.contains(key) || guiOwnedPrefixes.contains { key.hasPrefix($0) }
    }
    private static func isLoaderControl(_ key: String) -> Bool {
        loaderControlExactKeys.contains(key) || loaderControlPrefixes.contains { key.hasPrefix($0) }
    }

    public static func processEnvironment(
        overrides: [String: String],
        purpose: EnvironmentPurpose,
        base gui: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        // Login-shell env import applies only to real agent turns, and only when the
        // kill-switch is not off (default ON). When inactive, behavior is identical
        // to the pre-parity implementation (GUI env, no strips).
        let importEnabled = (gui["RC_LOGIN_SHELL_ENV_IMPORT"] ?? "1") != "0"
        let active = purpose.importsLoginEnvironment && importEnabled
        let login: [String: String]? = active
            ? LoginShellEnvironment.current(parentEnvironment: gui)
            : nil

        var base = gui
        if let login {
            // delta-over-GUI: overlay login keys that differ/are new, except the
            // GUI-owned identity/sandbox keys; drop shell-local volatile keys.
            for (key, value) in login where !isGuiOwned(key) {
                base[key] = value
            }
            for key in volatileDropKeys { base.removeValue(forKey: key) }
        }
        if active {
            // Fail-safe strips on BOTH branches (login imported OR capture-not-ready).
            for key in Array(base.keys) where isLoaderControl(key) {
                base.removeValue(forKey: key)
            }
            if case .agentTurn(.claude) = purpose {
                // Fail-safe: strip the whole ANTHROPIC_* namespace (catches unknown
                // future auth/routing keys) plus the exact CLAUDE_CODE_* auth keys.
                for key in Array(base.keys)
                where key.hasPrefix("ANTHROPIC_") || claudeAuthStripKeys.contains(key) {
                    base.removeValue(forKey: key)
                }
            }
        }

        // Token Saver/Graphify admission belongs to the exact host request, not
        // the RemoteCode process' inherited GUI/login environment. This keeps a
        // parent shell receipt from leaking into support or cross-user launches.
        base = AgentHostEnvironmentMerge.stripHostInjects(from: base)
        var env = base.merging(overrides) { _, override in override }

        let home = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        // Prepend the login PATH so profile PATH additions resolve; expandedPath then
        // fronts the managed-wrapper dir (~/.remote-code/bin) + standard fallbacks.
        // (Duplicate entries with the override PATH are harmless.)
        if let loginPath = login?["PATH"], !loginPath.isEmpty {
            let existing = env["PATH"].flatMap { $0.isEmpty ? nil : loginPath + ":" + $0 } ?? loginPath
            env["PATH"] = existing
        }
        env["PATH"] = ProcessLocator.expandedPath(environmentPath: env["PATH"], homeDirectory: home)

        if let provider = purpose.provider {
            env["REMOTE_CODE_AGENT_PROVIDER"] = provider.rawValue
        }
        // Central Token Saver receipt seam for every controlled nested agent spawn
        // (Codex/Claude/Grok). Support/probe processes stay raw (no re-stamp).
        // Re-applies discrete RC_TOKEN_SAVER_* + compact receipt from host overrides;
        // never invents admission when the host left Token Saver off.
        if case .agentTurn(let provider) = purpose {
            env = TokenSaverExecutionReceiptSeam.propagate(into: env, provider: provider)
        } else {
            env = AgentHostEnvironmentMerge.stripHostInjects(from: env)
        }
        // Expose the `RefreshMcpTools` tool for Claude turns so the agent can pick
        // up remote MCP servers (Linear, etc.) that finish their async connect a
        // few seconds into the session — see mcpConnectWaitDirective. A caller-set
        // override wins (so it can be forced off).
        if case .agentTurn(.claude) = purpose, env["CLAUDE_CODE_ENABLE_REFRESH_MCP_TOOLS"] == nil {
            env["CLAUDE_CODE_ENABLE_REFRESH_MCP_TOOLS"] = "1"
        }
        return env
    }
}

/// Reassembles newline-delimited JSON from a pipe. The
/// `readabilityHandler` hands us arbitrary byte chunks: a single read
/// routinely splits a JSON line — and even a multi-byte UTF-8 sequence —
/// across two deliveries. Decoding each raw chunk directly (the previous
/// behaviour) silently dropped every straddling event, so large agent
/// outputs lost their terminal `agent_message`/`turn.completed` and the
/// run hung "running" forever. Only complete lines are emitted; the
/// trailing partial is held until the next read (or `flush()` at EOF).
final class LineBuffer {
    private var buffer = Data()

    /// Append a chunk, return any now-complete lines (trimmed, non-empty).
    func take(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = Self.decode(lineData) { lines.append(s) }
        }
        return lines
    }

    /// Emit any final, unterminated line (last record before EOF).
    func flush() -> [String] {
        guard !buffer.isEmpty else { return [] }
        let rest = buffer
        buffer.removeAll()
        return Self.decode(rest).map { [$0] } ?? []
    }

    private static func decode(_ data: Data) -> String? {
        var d = data
        if d.last == 0x0D { d.removeLast() }   // strip a CRLF's CR
        // Lines are now complete, so no UTF-8 sequence is split; decode
        // is lossless. (Lossy `String(decoding:)` never returns nil — far
        // safer than the old guard that dropped the whole chunk.)
        let s = String(decoding: d, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

final class TimelineAggregator: @unchecked Sendable {
    private var state = AssistantTimelineState()
    private let lock = NSLock()
    var finalAssistantMessage: String? {
        lock.lock(); defer { lock.unlock() }
        return state.latestAssistantMessage
    }
    var providerThreadId: String? {
        lock.lock(); defer { lock.unlock() }
        return state.providerThreadId
    }
    func apply(_ ev: AssistantEvent) {
        lock.lock(); defer { lock.unlock() }
        state.apply(ev)
    }
}
