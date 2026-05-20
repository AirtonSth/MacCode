import Foundation
import CoreModel

public final class ClaudeRunner: AgentProviderRunner, @unchecked Sendable {
    public let provider: AgentProvider = .claude
    private let binaryNameOverride: String?

    public init(binaryNameOverride: String? = nil) {
        self.binaryNameOverride = binaryNameOverride
    }

    public func listModels() async -> [AgentModelDescriptor] {
        [
            AgentModelDescriptor(id: "claude-opus-4-7", label: "Claude Opus 4.7", provider: .claude, supportsReasoning: true),
            AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude, supportsReasoning: true),
            AgentModelDescriptor(id: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5", provider: .claude, supportsReasoning: false)
        ]
    }

    /// Builds the `claude` CLI argv. Pure + static so the exact flag
    /// combination is regression-tested without spawning a process.
    /// `--print --output-format stream-json` MUST be accompanied by
    /// `--verbose` or the CLI rejects the run.
    public static func buildArgs(_ request: AgentRunRequest) -> [String] {
        var args: [String] = ["--print", "--output-format", "stream-json", "--verbose"]
        args.append(contentsOf: ["--model", request.model])
        // claude accepts --effort low|medium|high|xhigh|max.
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
        switch request.permissionMode {
        case .supervised: args.append(contentsOf: ["--permission-mode", "default"])
        case .autoAcceptEdits: args.append(contentsOf: ["--permission-mode", "acceptEdits"])
        case .fullAccess: args.append(contentsOf: ["--permission-mode", "bypassPermissions"])
        }
        args.append(contentsOf: request.extraArgs)
        args.append(request.prompt)
        return args
    }

    public func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let binary = binaryNameOverride ?? "claude"
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
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        // Never block waiting on stdin — the prompt is an arg. Without this
        // a provider can sit "running" forever reading a TTY that isn't there.
        proc.standardInput = FileHandle.nullDevice

        let parser = ClaudeParser()
        let timeline = TimelineAggregator()
        let outBuf = LineBuffer()
        let cancelLock = NSLock()
        var didCancel = false

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            for line in outBuf.take(data) {
                for ev in parser.parseLine(line) {
                    timeline.apply(ev)
                    onEvent(.event(ev))
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            let s = String(data: data, encoding: .utf8) ?? ""
            if !s.isEmpty { onEvent(.error("[claude stderr] " + s)) }
        }

        proc.terminationHandler = { p in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // Drain bytes that arrived between the last read and EOF, plus
            // the final unterminated line, before finalizing the parser.
            let tail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            for line in outBuf.take(tail) + outBuf.flush() {
                for ev in parser.parseLine(line) {
                    timeline.apply(ev)
                    onEvent(.event(ev))
                }
            }
            for ev in parser.finalize() {
                timeline.apply(ev)
                onEvent(.event(ev))
            }
            let status: AgentRunStatus
            cancelLock.lock()
            let cancelled = didCancel
            cancelLock.unlock()
            if cancelled || p.terminationReason == .uncaughtSignal { status = .cancelled }
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
            cancelLock.lock()
            didCancel = true
            cancelLock.unlock()
            ProcessTerminator.terminateTree(proc)
        }
    }
}
