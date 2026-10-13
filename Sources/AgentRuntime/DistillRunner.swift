import Foundation
import CoreModel

/// Headless runner for the official Distill harness (`distill`).
/// Uses `-p` + `--output-format streaming-json` and `--resume` for multi-turn.
public final class DistillRunner: AgentProviderRunner, @unchecked Sendable {
    public let provider: AgentProvider = .distill
    private let binaryNameOverride: String?

    public init(binaryNameOverride: String? = nil) {
        self.binaryNameOverride = binaryNameOverride
    }

    public func listModels() async -> [AgentModelDescriptor] {
        Self.listModels(installedVersion: nil)
    }

    public static let grok46ReasoningEfforts = DistillReasoningPolicy.grok46Efforts
    public static let grok45ReasoningEfforts = DistillReasoningPolicy.grok45Efforts

    /// Static fallback catalog of explicitly named models and their efforts.
    public static func listModels(installedVersion: String?) -> [AgentModelDescriptor] {
        [
            AgentModelDescriptor(
                id: "grok-4.6",
                label: "Grok 4.6",
                provider: .distill,
                supportsReasoning: true,
                supportedReasoningEfforts: grok46ReasoningEfforts,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "grok-4.5",
                label: "Grok 4.5",
                provider: .distill,
                supportsReasoning: true,
                supportedReasoningEfforts: grok45ReasoningEfforts,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "glm-5.3",
                label: "GLM 5.3",
                provider: .distill,
                supportsReasoning: true,
                supportedReasoningEfforts: DistillReasoningPolicy.glm53Efforts,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "glm-5.3-flash",
                label: "GLM 5.3 Flash",
                provider: .distill,
                supportsReasoning: true,
                supportedReasoningEfforts: DistillReasoningPolicy.glm53Efforts,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "qwen38-omlx",
                label: "Qwen3.8-27B MTPLX 128k",
                provider: .distill,
                supportsReasoning: false,
                supportsCustomModel: true
            ),
            AgentModelDescriptor(
                id: "muse-spark-1.3-contributor",
                label: "Muse Spark 1.3 Contributor",
                provider: .distill,
                supportsReasoning: true,
                supportedReasoningEfforts: DistillReasoningPolicy.museSparkEfforts,
                supportsCustomModel: true
            ),
            // The account default tracks the current reasoning model.
        ]
    }

    /// Builds `distill` argv for a one-shot headless turn. Pure + static for tests.
    /// `--output-format streaming-json` is the harness's NDJSON mode: one ACP
    /// session update per line, which is what `DistillParser` consumes.
    public static func buildArgs(_ request: AgentRunRequest, newSessionId: String? = nil) -> [String] {
        var args: [String] = ["-p", request.providerPrompt, "--output-format", "streaming-json"]
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

    /// Manual models retain their static effort normalization. Auto is
    /// validated by Distill after it selects the concrete route.
    static func effortArgs(_ effort: AgentReasoningEffort, model: String = "") -> [String] {
        // Auto's concrete route is selected by Distill; let that runtime validate the requested effort.
        if model == "auto" { return ["--reasoning-effort", effort.rawValue] }
        guard let effective = normalizedReasoningEffort(effort, model: model) else { return [] }
        return ["--reasoning-effort", effective.rawValue]
    }

    static func supportedReasoningEfforts(for model: String) -> [AgentReasoningEffort] {
        DistillReasoningPolicy.supportedEfforts(for: model)
    }

    static func normalizedReasoningEffort(
        _ effort: AgentReasoningEffort,
        model: String
    ) -> AgentReasoningEffort? {
        let supported = supportedReasoningEfforts(for: model)
        guard !supported.isEmpty else { return nil }
        return DistillReasoningPolicy.normalizedEffort(effort, model: model)
    }

    static func modelSupportsReasoningEffort(_ model: String) -> Bool {
        model == "auto" || !supportedReasoningEfforts(for: model).isEmpty
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
        let plan = DistillProvisioner.installPlan()
        return "\(binary) not found. Install it with: \(plan.commandLine)  " +
        "Searched: ~/.local/share/distill/bin, ~/.local/bin, /opt/homebrew/bin. " +
        "Open Settings to set a custom path."
    }

    public func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let message = "Select an explicit Distill Main model before running."
            onEvent(.error(message))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.spawnFailed(message)
        }
        let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.providerBinary!
            : (binaryNameOverride ?? DistillProvisioner.binaryName)
        guard let path = ProcessLocator.resolveDistillAgentForRunAsUser(binary, runAsUser: request.runAsUser) else {
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
                provider: .distill,
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

        let parser = DistillParser(initialSessionId: preassignedSessionId)
        let timeline = TimelineAggregator()
        let outBuf = LineBuffer()
        let stdoutReadLock = NSLock()
        let cancelFlag = AgentCancelFlag()
        let emitLine: (String) -> Void = { line in
            // Token lines (thought/text) become Thought/answer items via DistillParser.
            // Do not also emit providerRuntime for them — that floods Work log with
            // "distill runtime: thought" rows above the user message on every token.
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
                    provider: .distill,
                    source: "distill.streaming-json.stderr"
                ))))
                onEvent(.error("[distill stderr] " + visible))
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
                    provider: .distill,
                    source: "distill.streaming-json.stderr"
                ))))
                onEvent(.error("[distill stderr] " + visible))
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
                    ? "distill exited with signal \(p.terminationStatus)"
                    : "distill exited with status \(p.terminationStatus)"
                onEvent(.error(cause))
            }
            onEvent(.status(status))
            onEvent(.finished(status, finalMessage: timeline.finalAssistantMessage, providerThreadId: sessionId))
        }

        do {
            try proc.run()
            try ProcessSpawnTagger.tagProcess(proc, provider: .distill)
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
        ProviderStderrClassifier.displayableStderr(raw, provider: .distill)
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
        parser: DistillParser,
        receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> (runtimeEvent: ProviderRuntimeEvent?, parsedEvents: [AssistantEvent]) {
        let object = jsonObject(from: line)
        return (
            object.flatMap {
                providerRuntimeEventIfNeeded(
                    object: $0, source: "distill.streaming-json", receivedAtMs: receivedAtMs
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
            object, provider: .distill, source: source, receivedAtMs: receivedAtMs
        )
    }

    /// distill `streaming-json` emits one NDJSON object per reasoning/answer token.
    static func isTokenStreamMethod(_ method: String) -> Bool {
        switch method {
        case "thought", "text":
            return true
        default:
            return false
        }
    }
}
