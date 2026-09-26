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

    public static let grok46ReasoningEfforts = GrokReasoningPolicy.grok46Efforts
    public static let grok45ReasoningEfforts = GrokReasoningPolicy.grok45Efforts

    /// Static catalog matching `grok models` / models_cache.json defaults.
    /// Empty model id means account default (omit `-m`).
    public static func listModels(installedVersion: String?) -> [AgentModelDescriptor] {
        [
            AgentModelDescriptor(
                id: "grok-4.7",
                label: "Grok 4.7",
                provider: .grok,
                supportsReasoning: true,
                supportedReasoningEfforts: grok46ReasoningEfforts,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "grok-4.6",
                label: "Grok 4.6",
                provider: .grok,
                supportsReasoning: true,
                supportedReasoningEfforts: grok46ReasoningEfforts,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "grok-4.5",
                label: "Grok 4.5",
                provider: .grok,
                supportsReasoning: true,
                supportedReasoningEfforts: grok45ReasoningEfforts,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "glm-5.3",
                label: "GLM 5.3",
                provider: .grok,
                supportsReasoning: true,
                supportedReasoningEfforts: GrokReasoningPolicy.glm53Efforts,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "glm-5.3-flash",
                label: "GLM 5.3 Flash",
                provider: .grok,
                supportsReasoning: true,
                supportedReasoningEfforts: GrokReasoningPolicy.glm53Efforts,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "qwen38-omlx",
                label: "Qwen3.8-27B MTPLX 128k",
                provider: .grok,
                supportsReasoning: false,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "muse-spark-1.3-contributor",
                label: "Muse Spark 1.3 Contributor",
                provider: .grok,
                supportsReasoning: true,
                supportedReasoningEfforts: GrokReasoningPolicy.museSparkEfforts,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "grok-4.7-build-fast",
                label: "Grok 4.7 Build Fast",
                provider: .grok,
                supportsReasoning: false,
                supportsCustomModel: true
            ),
            // Current account default tracks Grok 4.7 (live grok 1.0.41).
            AgentModelDescriptor(
                id: "",
                label: "Default (account)",
                provider: .grok,
                supportsReasoning: true,
                supportedReasoningEfforts: grok46ReasoningEfforts,
                supportsCustomModel: true
            )
        ]
    }

    /// Builds `grok` argv for a one-shot headless turn. Pure + static for tests.
    ///
    /// Token Saver compresses Grok tool output on two lanes: PATH wrappers /
    /// PreToolUse `| distill` rewrite for `run_terminal_command`, and the managed
    /// PostToolUse `updatedToolOutput` hook for built-in `read_file` / `list_dir` /
    /// `web_fetch` results (see `AgentSkillInstaller.installGrokPostToolUseHook`).
    /// Grok ≥ 1.0.34 delivers a settings-file hook's replacement after validating
    /// it against the ran tool's own output shape.
    public static func buildArgs(_ request: AgentRunRequest, newSessionId: String? = nil) -> [String] {
        let providerPrompt = AgentSkillInstaller.tokenSaverProviderPrompt(
            request.providerPrompt,
            environment: request.environment
        )
        var args: [String] = ["-p", providerPrompt, "--output-format", "streaming-json"]
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        // Only pass --reasoning-effort for models that support it. Composer-fast
        // rejects/ignores effort, so the model-aware mapper omits the flag.
        if let effort = request.reasoningEffort {
            args.append(contentsOf: effortArgs(effort, model: model))
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

    /// Return only provider-advertised levels. Stale/shared picker values are
    /// clamped to the selected model's deepest supported level; `max` is never
    /// emitted because neither current Grok model advertises it.
    static func effortArgs(_ effort: AgentReasoningEffort, model: String = "") -> [String] {
        guard let effective = normalizedReasoningEffort(effort, model: model) else { return [] }
        return ["--reasoning-effort", effective.rawValue]
    }

    static func supportedReasoningEfforts(for model: String) -> [AgentReasoningEffort] {
        GrokReasoningPolicy.supportedEfforts(for: model)
    }

    static func normalizedReasoningEffort(
        _ effort: AgentReasoningEffort,
        model: String
    ) -> AgentReasoningEffort? {
        let supported = supportedReasoningEfforts(for: model)
        guard !supported.isEmpty else { return nil }
        return GrokReasoningPolicy.normalizedEffort(effort, model: model)
    }

    static func modelSupportsReasoningEffort(_ model: String) -> Bool {
        !supportedReasoningEfforts(for: model).isEmpty
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
        let proc: Process
        do {
            proc = try ProviderSubprocessLauncher.makeProcess(
                provider: .grok,
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
            let interpreted = Self.interpretStreamJSONLine(line, parser: parser)
            if let runtimeEvent = interpreted.runtimeEvent {
                let ev = AssistantEvent.providerRuntime(runtimeEvent)
                timeline.apply(ev)
                onEvent(.event(ev))
            }
            for ev in interpreted.parsedEvents {
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
            let tail = BoundedPipeDrain.readRemaining(
                from: stdoutPipe.fileHandleForReading,
                maxBytes: BoundedPipeDrain.defaultStdoutMaxBytes
            )
            for line in outBuf.take(tail) + outBuf.flush() {
                emitLine(line)
            }
            stdoutReadLock.unlock()
            let stderrTail = BoundedPipeDrain.readRemaining(
                from: stderrPipe.fileHandleForReading,
                maxBytes: BoundedPipeDrain.defaultStderrMaxBytes
            )
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

#if DEBUG
    static var streamJSONDecodeCountForTesting = 0
#endif

    static func jsonObject(from line: String) -> [String: Any]? {
#if DEBUG
        streamJSONDecodeCountForTesting += 1
#endif
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Decode once, then runtime (non-token) + parser events.
    static func interpretStreamJSONLine(
        _ line: String,
        parser: GrokParser,
        receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> (runtimeEvent: ProviderRuntimeEvent?, parsedEvents: [AssistantEvent]) {
        let object = jsonObject(from: line)
        return (
            object.flatMap {
                providerRuntimeEventIfNeeded(
                    object: $0, source: "grok.streaming-json", receivedAtMs: receivedAtMs
                )
            },
            object.map { parser.parseObject($0, now: receivedAtMs) } ?? []
        )
    }

    /// Lifecycle / tool / error lines become `providerRuntime` for debug + Work log.
    /// Pure token stream types are excluded — they already map to timeline items.
    public static func providerRuntimeEventIfNeeded(
        line: String,
        source: String,
        receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> ProviderRuntimeEvent? {
        guard let object = jsonObject(from: line) else { return nil }
        return providerRuntimeEventIfNeeded(object: object, source: source, receivedAtMs: receivedAtMs)
    }

    public static func providerRuntimeEventIfNeeded(
        object: [String: Any],
        source: String,
        receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> ProviderRuntimeEvent? {
        // Skip before JSONSerialization.data(.sortedKeys). The previous
        // fromJSONObject-then-drop path still serialized every thought/text
        // token, then discarded the event. itemDelta already carries the bytes.
        ProviderRuntimeEvent.fromJSONObjectIfNeeded(
            object, provider: .grok, source: source, receivedAtMs: receivedAtMs
        )
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
