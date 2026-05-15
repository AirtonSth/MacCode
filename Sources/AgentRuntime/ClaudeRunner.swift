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

    public func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let binary = binaryNameOverride ?? "claude"
        guard let path = ProcessLocator.resolve(binary) else {
            onEvent(.error("\(binary) not found in PATH"))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.missingBinary(binary)
        }

        var args: [String] = ["--output-format", "stream-json", "--print"]
        args.append(contentsOf: ["--model", request.model])
        if let ptid = request.providerThreadId {
            args.append(contentsOf: ["--resume", ptid])
        }
        // permission/sandbox mapping
        switch request.permissionMode {
        case .supervised: args.append(contentsOf: ["--permission-mode", "default"])
        case .autoAcceptEdits: args.append(contentsOf: ["--permission-mode", "acceptEdits"])
        case .fullAccess: args.append(contentsOf: ["--permission-mode", "bypassPermissions"])
        }
        args.append(contentsOf: request.extraArgs)
        args.append(request.prompt)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let parser = ClaudeParser()
        let timeline = TimelineAggregator()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            guard let str = String(data: data, encoding: .utf8) else { return }
            for line in str.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                for ev in parser.parseLine(String(line)) {
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
            for ev in parser.finalize() {
                timeline.apply(ev)
                onEvent(.event(ev))
            }
            let status: AgentRunStatus
            if p.terminationReason == .uncaughtSignal { status = .cancelled }
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
            if proc.isRunning { proc.terminate() }
        }
    }
}
