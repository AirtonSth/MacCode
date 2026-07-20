import Foundation
import CoreModel

public final class ClaudeRunner: AgentProviderRunner, @unchecked Sendable {
    public let provider: AgentProvider = .claude
    private let binaryNameOverride: String?

    public init(binaryNameOverride: String? = nil) {
        self.binaryNameOverride = binaryNameOverride
    }

    public func listModels() async -> [AgentModelDescriptor] {
        let result = await AnthropicModelDiscovery.listModelsResult()
        return result.isFallback ? Self.listModels(installedVersion: nil) : result.models
    }

    /// Like `listModels` but returns a `ModelListResult` so callers can
    /// inspect whether the static fallback was used.
    /// `environment` and `session` are injected for testing; production
    /// callers use the defaults.
    public func listModelsResult(
        environment: [String: String] = [:],
        session: URLSession = .shared
    ) async -> ModelListResult {
        let result = await AnthropicModelDiscovery.listModelsResult(environment: environment, session: session)
        if result.isFallback {
            return ModelListResult(models: Self.listModels(installedVersion: nil), isFallback: true)
        }
        return result
    }

    public static func listModels(installedVersion: String?) -> [AgentModelDescriptor] {
        AnthropicModelDiscovery.latestAliasModels()
    }

    /// `ultracode` is not a `--effort` flag value — the CLI rejects it
    /// ("Unknown --effort value"). It is the `ultracode` settings key meaning
    /// "xhigh effort + standing dynamic-workflow orchestration", so it maps to
    /// `--effort xhigh` plus the settings payload below. Every other level maps
    /// one-to-one; `nil`/`medium` default to medium so the flag is never omitted.
    static func effortArgs(_ effort: AgentReasoningEffort?) -> [String] {
        switch effort {
        case .some(.minimal), .some(.low): return ["--effort", "low"]
        case .some(.high): return ["--effort", "high"]
        case .some(.xhigh): return ["--effort", "xhigh"]
        case .some(.max): return ["--effort", "max"]
        case .some(.ultracode): return ["--effort", "xhigh"]
        case .some(.medium), .none: return ["--effort", "medium"]
        }
    }

    /// Ultracode requires `enableWorkflows: true` for the Workflow tool to be
    /// exposed; `ultracode: true` alone bumps effort to xhigh but leaves the
    /// orchestration tool absent. Both keys are forced on for the spawned
    /// session via `--settings` (which merges over the user's settings files).
    /// Non-ultracode efforts pass no `--settings` so normal runs stay untouched.
    static let ultracodeSettingsJSON = #"{"ultracode":true,"enableWorkflows":true}"#

    static func ultracodeSettingsArgs(_ effort: AgentReasoningEffort?) -> [String] {
        effort == .ultracode ? ["--settings", ultracodeSettingsJSON] : []
    }

    /// Builds the `claude` CLI argv. Pure + static so the exact flag
    /// combination is regression-tested without spawning a process.
    /// `--print --output-format stream-json` MUST be accompanied by
    /// `--verbose` or the CLI rejects the run.
    public static func buildArgs(_ request: AgentRunRequest) -> [String] {
        var args: [String] = ["--print", "--output-format", "stream-json", "--verbose"]
        args.append(contentsOf: ["--model", request.model])
        let prompt = request.providerPrompt
        args.append(contentsOf: effortArgs(request.reasoningEffort))
        args.append(contentsOf: ultracodeSettingsArgs(request.reasoningEffort))
        // Resume the prior session so the model keeps full context.
        if let ptid = request.providerThreadId, !ptid.isEmpty {
            args.append(contentsOf: ["--resume", ptid])
        }
        if request.interactionMode == .plan {
            args.append(contentsOf: ["--permission-mode", "plan"])
        } else {
            switch request.permissionMode {
            case .supervised: args.append(contentsOf: ["--permission-mode", "default"])
            case .autoAcceptEdits: args.append(contentsOf: ["--permission-mode", "acceptEdits"])
            case .fullAccess: args.append(contentsOf: ["--permission-mode", "bypassPermissions"])
            }
        }
        args.append(contentsOf: request.extraArgs)
        args.append(prompt)
        return args
    }

    public static func buildStreamingArgs(_ request: AgentRunRequest) -> [String] {
        var args: [String] = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--replay-user-messages"
        ]
        args.append(contentsOf: ["--model", request.model])
        args.append(contentsOf: effortArgs(request.reasoningEffort))
        args.append(contentsOf: ultracodeSettingsArgs(request.reasoningEffort))
        if let ptid = request.providerThreadId, !ptid.isEmpty {
            args.append(contentsOf: ["--resume", ptid])
        } else {
            args.append(contentsOf: ["--session-id", request.threadId.value.uuidString])
        }
        if request.interactionMode == .plan {
            args.append(contentsOf: ["--permission-mode", "plan"])
        } else {
            switch request.permissionMode {
            case .supervised: args.append(contentsOf: ["--permission-mode", "default"])
            case .autoAcceptEdits: args.append(contentsOf: ["--permission-mode", "acceptEdits"])
            case .fullAccess: args.append(contentsOf: ["--permission-mode", "bypassPermissions"])
            }
        }
        // UX-MAC_AGENT-BG-AWAIT: always make the agent self-declare a background-await
        // stall with `awaitingMarker` so the host recovers it regardless of phrasing
        // (independent of Token Saver). Token Saver parity rides in the same flag: when
        // the host signals Token Saver is on (and the managed `distill` CLI therefore
        // exists), append the canonical distill instructions too. `--append-system-prompt`
        // adds to the CLI's default prompt, so it stays additive.
        let appendedSystemPrompt = AgentSkillInstaller.tokenSaverProviderPrompt(
            BackgroundAwaitContinuation.systemPromptDirective,
            environment: request.environment
        )
        args.append(contentsOf: ["--append-system-prompt", appendedSystemPrompt])
        args.append(contentsOf: request.extraArgs)
        return args
    }

    /// Human-readable error shown when the provider binary is absent from PATH.
    /// Includes the most common install paths so users can diagnose the issue
    /// without opening a terminal.
    nonisolated static func missingBinaryMessage(_ binary: String) -> String {
        "\(binary) not found in PATH. Install it with: npm install -g @anthropic-ai/claude-code  " +
        "or: brew install claude-code  " +
        "Searched: ~/.remote-code/bin, /opt/homebrew/bin, ~/.local/bin, ~/.npm-global/bin. " +
        "Open Settings to set a custom path."
    }

    public func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? request.providerBinary! : (binaryNameOverride ?? "claude")
        guard let path = ProcessLocator.resolve(binary) else {
            onEvent(.error(Self.missingBinaryMessage(binary)))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.missingBinary(binary)
        }

        let args = Self.buildArgs(request)
        let environment = CodexRunner.processEnvironment(overrides: request.environment, provider: .claude)
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
        // Never block waiting on stdin — the prompt is an arg. Without this
        // a provider can sit "running" forever reading a TTY that isn't there.
        proc.standardInput = FileHandle.nullDevice

        let parser = ClaudeParser()
        let timeline = TimelineAggregator()
        let outBuf = LineBuffer()
        // Serializes the stdout readabilityHandler against the termination
        // drain: nil-ing a readabilityHandler does not wait for a callback
        // already running, and LineBuffer is not thread-safe. Taken BEFORE
        // the fd read so byte order is preserved across the two readers.
        let stdoutReadLock = NSLock()
        let cancelFlag = AgentCancelFlag()
        let emitLine: (String) -> Void = { line in
            if let runtimeEvent = ProviderRuntimeEvent.fromJSONLine(line, provider: .claude, source: "claude.stream-json") {
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
                    provider: .claude,
                    source: "claude.stream-json.stderr"
                ))))
                onEvent(.error("[claude stderr] " + visible))
            }
        }

        proc.terminationHandler = { p in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // Drain bytes that arrived between the last read and EOF, plus
            // the final unterminated line, before finalizing the parser.
            // Under the lock: an in-flight readabilityHandler callback may
            // still be reading/parsing concurrently.
            stdoutReadLock.lock()
            let tail = BoundedPipeDrain.readRemaining(from: stdoutPipe.fileHandleForReading)
            for line in outBuf.take(tail) + outBuf.flush() {
                emitLine(line)
            }
            stdoutReadLock.unlock()
            // Mirror the stdout drain for stderr: a CLI that exits instantly
            // (auth error, crash banner) writes the only explanation to
            // stderr, and the async handler can lose the race with the
            // teardown above, leaving the bytes undelivered in the pipe.
            let stderrTail = BoundedPipeDrain.readRemaining(from: stderrPipe.fileHandleForReading)
            if !stderrTail.isEmpty,
               let visible = Self.displayableStderr(String(data: stderrTail, encoding: .utf8) ?? "") {
                onEvent(.event(.providerRuntime(ProviderStderrClassifier.runtimeEvent(
                    message: visible,
                    provider: .claude,
                    source: "claude.stream-json.stderr"
                ))))
                onEvent(.error("[claude stderr] " + visible))
            }
            for ev in parser.finalize() {
                timeline.apply(ev)
                onEvent(.event(ev))
            }
            let status = Self.terminalStatus(
                cancelRequested: cancelFlag.isCancelled,
                terminationReason: p.terminationReason,
                terminationStatus: p.terminationStatus
            )
            onEvent(.status(status))
            onEvent(.finished(status, finalMessage: timeline.finalAssistantMessage, providerThreadId: timeline.providerThreadId))
        }

        do {
            try proc.run()
            try ProcessSpawnTagger.tagProcess(proc, provider: .claude)
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

    nonisolated static func terminalStatus(
        cancelRequested: Bool,
        terminationReason: Process.TerminationReason,
        terminationStatus: Int32
    ) -> AgentRunStatus {
        if cancelRequested { return .cancelled }
        return terminationReason == .exit && terminationStatus == 0 ? .completed : .failed
    }

    public static func displayableStderr(_ raw: String) -> String? {
        ProviderStderrClassifier.displayableStderr(raw, provider: .claude)
    }
}
