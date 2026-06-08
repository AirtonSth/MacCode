import Foundation
import CoreModel

public final class ClaudeRunner: AgentProviderRunner, @unchecked Sendable {
    public let provider: AgentProvider = .claude
    private let binaryNameOverride: String?

    public init(binaryNameOverride: String? = nil) {
        self.binaryNameOverride = binaryNameOverride
    }

    public func listModels() async -> [AgentModelDescriptor] {
        let dynamicModels = await AnthropicModelDiscovery.listModels()
        return dynamicModels.isEmpty ? Self.listModels(installedVersion: nil) : dynamicModels
    }

    public static func listModels(installedVersion: String?) -> [AgentModelDescriptor] {
        AnthropicModelDiscovery.latestAliasModels()
    }

    /// Builds the `claude` CLI argv. Pure + static so the exact flag
    /// combination is regression-tested without spawning a process.
    /// `--print --output-format stream-json` MUST be accompanied by
    /// `--verbose` or the CLI rejects the run.
    public static func buildArgs(_ request: AgentRunRequest) -> [String] {
        var args: [String] = ["--print", "--output-format", "stream-json", "--verbose"]
        args.append(contentsOf: ["--model", request.model])
        let prompt = request.providerPrompt
        switch request.reasoningEffort {
        case .some(.minimal), .some(.low): args.append(contentsOf: ["--effort", "low"])
        case .some(.high): args.append(contentsOf: ["--effort", "high"])
        case .some(.xhigh): args.append(contentsOf: ["--effort", "xhigh"])
        case .some(.medium), .none: args.append(contentsOf: ["--effort", "medium"])
        }
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
        switch request.reasoningEffort {
        case .some(.minimal), .some(.low): args.append(contentsOf: ["--effort", "low"])
        case .some(.high): args.append(contentsOf: ["--effort", "high"])
        case .some(.xhigh): args.append(contentsOf: ["--effort", "xhigh"])
        case .some(.medium), .none: args.append(contentsOf: ["--effort", "medium"])
        }
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
        args.append(contentsOf: ["--tools", ""])
        args.append(contentsOf: request.extraArgs)
        return args
    }

    public func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? request.providerBinary! : (binaryNameOverride ?? "claude")
        guard let path = ProcessLocator.resolve(binary) else {
            onEvent(.error("\(binary) not found in PATH"))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.missingBinary(binary)
        }

        let args = Self.buildArgs(request)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
        proc.environment = CodexRunner.processEnvironment(overrides: request.environment, provider: .claude)
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        // Never block waiting on stdin — the prompt is an arg. Without this
        // a provider can sit "running" forever reading a TTY that isn't there.
        proc.standardInput = FileHandle.nullDevice

        let parser = ClaudeParser()
        let timeline = TimelineAggregator()
        let outBuf = LineBuffer()
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
            let tail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            for line in outBuf.take(tail) + outBuf.flush() {
                emitLine(line)
            }
            for ev in parser.finalize() {
                timeline.apply(ev)
                onEvent(.event(ev))
            }
            let status: AgentRunStatus
            if cancelFlag.isCancelled || p.terminationReason == .uncaughtSignal { status = .cancelled }
            else if p.terminationStatus == 0 { status = .completed }
            else { status = .failed }
            onEvent(.status(status))
            onEvent(.finished(status, finalMessage: timeline.finalAssistantMessage, providerThreadId: timeline.providerThreadId))
        }

        do {
            try proc.run()
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
        ProviderStderrClassifier.displayableStderr(raw, provider: .claude)
    }
}
