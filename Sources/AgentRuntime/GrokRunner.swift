import Foundation
import CoreModel

/// Headless runner for the official Grok Build CLI (`grok` from x.ai/cli).
/// Uses `-p` + `--output-format streaming-json` and `--resume` for multi-turn.
public final class GrokRunner: AgentProviderRunner, @unchecked Sendable {
    public let provider: AgentProvider = .grok
    private let binaryNameOverride: String?

    public init(binaryNameOverride: String? = nil) {
        self.binaryNameOverride = binaryNameOverride
    }

    public func listModels() async -> [AgentModelDescriptor] {
        Self.listModels(installedVersion: nil)
    }

    /// Effort levels advertised for reasoning Grok models (Grok 4.5 menu /
    /// models_cache.json): low, medium, high. Default on the model is `high`.
    /// CLI also accepts `none|minimal|xhigh|max` via flag, but those are not in
    /// the Grok 4.5 picker — keep the UI aligned with the model menu.
    public static let reasoningModelEfforts: [AgentReasoningEffort] = [.low, .medium, .high]

    /// Static catalog matching `grok models` / models_cache.json defaults.
    /// Empty model id means account default (omit `-m`).
    public static func listModels(installedVersion: String?) -> [AgentModelDescriptor] {
        [
            AgentModelDescriptor(
                id: "grok-4.5",
                label: "Grok 4.5",
                provider: .grok,
                supportsReasoning: true,
                supportedReasoningEfforts: reasoningModelEfforts,
                supportsCustomModel: true
            ),
            // models_cache: supports_reasoning_effort == false
            AgentModelDescriptor(
                id: "grok-composer-2.5-fast",
                label: "Grok Composer 2.5 Fast",
                provider: .grok,
                supportsReasoning: false,
                supportsCustomModel: true
            ),
            // Account default tracks Grok 4.5 (default model).
            AgentModelDescriptor(
                id: "",
                label: "Default (account)",
                provider: .grok,
                supportsReasoning: true,
                supportedReasoningEfforts: reasoningModelEfforts,
                supportsCustomModel: true
            )
        ]
    }

    /// Builds `grok` argv for a one-shot headless turn. Pure + static for tests.
    public static func buildArgs(_ request: AgentRunRequest, newSessionId: String? = nil) -> [String] {
        var args: [String] = ["-p", request.providerPrompt, "--output-format", "streaming-json"]
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        // Only pass --reasoning-effort for models that support it (Grok 4.5 /
        // account default). Composer-fast rejects/ignores effort; omit the flag.
        if let effort = request.reasoningEffort, modelSupportsReasoningEffort(model) {
            args.append(contentsOf: effortArgs(effort))
        }
        if let ptid = request.providerThreadId, !ptid.isEmpty {
            args.append(contentsOf: ["--resume", ptid])
        } else if let newSessionId, !newSessionId.isEmpty {
            args.append(contentsOf: ["--session-id", newSessionId])
        }
        if request.interactionMode == .plan {
            args.append(contentsOf: ["--permission-mode", "plan"])
        } else {
            switch request.permissionMode {
            case .supervised:
                args.append(contentsOf: ["--permission-mode", "default"])
            case .autoAcceptEdits:
                args.append(contentsOf: ["--permission-mode", "acceptEdits"])
            case .fullAccess:
                args.append(contentsOf: ["--permission-mode", "bypassPermissions"])
            }
        }
        args.append(contentsOf: request.extraArgs)
        return args
    }

    /// Wire values accepted by Grok Build CLI (`--reasoning-effort` / `--effort`):
    /// `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` (alias of xhigh).
    /// `ultracode` is Claude-only and is rejected by the CLI — map to `high`.
    static func effortArgs(_ effort: AgentReasoningEffort) -> [String] {
        switch effort {
        case .minimal:
            return ["--reasoning-effort", "minimal"]
        case .low:
            return ["--reasoning-effort", "low"]
        case .medium:
            return ["--reasoning-effort", "medium"]
        case .high:
            return ["--reasoning-effort", "high"]
        case .xhigh:
            return ["--reasoning-effort", "xhigh"]
        case .max:
            return ["--reasoning-effort", "max"]
        case .ultracode:
            // Not a Grok CLI level; keep runs green if a stale thread carries it.
            return ["--reasoning-effort", "high"]
        }
    }

    /// True when the selected model id supports reasoning effort (Grok 4.5 family /
    /// account default). Explicit non-reasoning models (composer-fast) return false.
    static func modelSupportsReasoningEffort(_ model: String) -> Bool {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return true } // account default == Grok 4.5
        if id == "grok-composer-2.5-fast" { return false }
        if id.hasPrefix("grok-composer") { return false }
        return true
    }

    static func terminalStatus(
        cancelledByUser: Bool,
        terminationReason: Process.TerminationReason,
        exitStatus: Int32
    ) -> AgentRunStatus {
        if cancelledByUser { return .cancelled }
        if terminationReason == .uncaughtSignal || exitStatus != 0 { return .failed }
        return .completed
    }

    nonisolated static func missingBinaryMessage(_ binary: String) -> String {
        "\(binary) not found in PATH. Install it with: curl -fsSL https://x.ai/cli/install.sh | bash  " +
        "Searched: ~/.grok/bin, ~/.remote-code/bin, /opt/homebrew/bin, ~/.local/bin. " +
        "Open Settings to set a custom path."
    }

    public func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.providerBinary!
            : (binaryNameOverride ?? "grok")
        guard let path = ProcessLocator.resolve(binary) else {
            onEvent(.error(Self.missingBinaryMessage(binary)))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.missingBinary(binary)
        }

        let preassignedSessionId = request.providerThreadId?.isEmpty == false
            ? request.providerThreadId
            : UUID().uuidString.lowercased()
        let args = Self.buildArgs(request, newSessionId: request.providerThreadId == nil ? preassignedSessionId : nil)
        let environment = CodexRunner.processEnvironment(overrides: request.environment, provider: .grok)
        let launchPlan: RunAsUserProcessBootstrap.LaunchPlan
        do {
            launchPlan = try RunAsUserProcessBootstrap.plan(
                executablePath: path,
                arguments: args,
                environment: environment,
                currentDirectory: request.cwd,
                runAsUser: request.runAsUser
            )
        } catch {
            onEvent(.error(error.localizedDescription))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }

        let proc = Process()
        RunAsUserProcessBootstrap.apply(launchPlan, to: proc)
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice

        let parser = GrokParser(initialSessionId: preassignedSessionId)
        let timeline = TimelineAggregator()
        let outBuf = LineBuffer()
        let stdoutReadLock = NSLock()
        let cancelFlag = AgentCancelFlag()
        let emitLine: (String) -> Void = { line in
            // Token lines (thought/text) become Thought/answer items via GrokParser.
            // Do not also emit providerRuntime for them — that floods Work log with
            // "grok runtime: thought" rows above the user message on every token.
            if let runtimeEvent = Self.providerRuntimeEventIfNeeded(line: line, source: "grok.streaming-json") {
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
            stdoutReadLock.lock()
            defer { stdoutReadLock.unlock() }
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
                    provider: .grok,
                    source: "grok.streaming-json.stderr"
                ))))
                onEvent(.error("[grok stderr] " + visible))
            }
        }

        proc.terminationHandler = { p in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutReadLock.lock()
            let tail = BoundedPipeDrain.readRemaining(from: stdoutPipe.fileHandleForReading)
            for line in outBuf.take(tail) + outBuf.flush() {
                emitLine(line)
            }
            stdoutReadLock.unlock()
            let stderrTail = BoundedPipeDrain.readRemaining(from: stderrPipe.fileHandleForReading)
            if !stderrTail.isEmpty,
               let visible = Self.displayableStderr(String(data: stderrTail, encoding: .utf8) ?? "") {
                onEvent(.event(.providerRuntime(ProviderStderrClassifier.runtimeEvent(
                    message: visible,
                    provider: .grok,
                    source: "grok.streaming-json.stderr"
                ))))
                onEvent(.error("[grok stderr] " + visible))
            }
            for ev in parser.finalize() {
                timeline.apply(ev)
                onEvent(.event(ev))
            }
            let status = Self.terminalStatus(
                cancelledByUser: cancelFlag.isCancelled,
                terminationReason: p.terminationReason,
                exitStatus: p.terminationStatus
            )
            let sessionId = timeline.providerThreadId ?? parser.capturedSessionId
            if status == .failed {
                let cause = p.terminationReason == .uncaughtSignal
                    ? "Grok CLI crashed with signal \(p.terminationStatus)"
                    : "Grok CLI exited with status \(p.terminationStatus)"
                onEvent(.error(cause))
            }
            onEvent(.status(status))
            onEvent(.finished(status, finalMessage: timeline.finalAssistantMessage, providerThreadId: sessionId))
        }

        do {
            try proc.run()
            try ProcessSpawnTagger.tagProcess(proc, provider: .grok)
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
        ProviderStderrClassifier.displayableStderr(raw, provider: .grok)
    }

    /// Lifecycle / tool / error lines become `providerRuntime` for debug + Work log.
    /// Pure token stream types are excluded — they already map to timeline items.
    public static func providerRuntimeEventIfNeeded(
        line: String,
        source: String,
        receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> ProviderRuntimeEvent? {
        guard let event = ProviderRuntimeEvent.fromJSONLine(
            line, provider: .grok, source: source, receivedAtMs: receivedAtMs
        ) else { return nil }
        if Self.isTokenStreamMethod(event.method) { return nil }
        return event
    }

    /// Grok `streaming-json` emits one NDJSON object per reasoning/answer token.
    static func isTokenStreamMethod(_ method: String) -> Bool {
        switch method {
        case "thought", "text":
            return true
        default:
            return false
        }
    }
}
