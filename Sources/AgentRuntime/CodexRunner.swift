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
        // search PATH
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        for component in envPath.split(separator: ":") {
            let full = String(component) + "/" + name
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }
}

public final class CodexRunner: AgentProviderRunner, @unchecked Sendable {
    public let provider: AgentProvider = .codex
    private let binaryNameOverride: String?

    public init(binaryNameOverride: String? = nil) {
        self.binaryNameOverride = binaryNameOverride
    }

    public func listModels() async -> [AgentModelDescriptor] {
        [
            AgentModelDescriptor(id: "gpt-5", label: "GPT-5", provider: .codex, supportsReasoning: true),
            AgentModelDescriptor(id: "gpt-5-mini", label: "GPT-5 Mini", provider: .codex, supportsReasoning: true),
            AgentModelDescriptor(id: "o4-mini", label: "o4-mini", provider: .codex, supportsReasoning: true)
        ]
    }

    public func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let binary = binaryNameOverride ?? "codex"
        guard let path = ProcessLocator.resolve(binary) else {
            onEvent(.error("\(binary) not found in PATH"))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.missingBinary(binary)
        }

        var args: [String] = ["exec", "--json"]
        args.append(contentsOf: ["--model", request.model])
        if let r = request.reasoningEffort?.rawValue {
            args.append(contentsOf: ["--reasoning", r])
        }
        switch request.permissionMode {
        case .supervised: args.append(contentsOf: ["--permission", "supervised"])
        case .autoAcceptEdits: args.append(contentsOf: ["--permission", "auto-edit"])
        case .fullAccess: args.append(contentsOf: ["--permission", "full-access"])
        }
        if let ptid = request.providerThreadId {
            args.append(contentsOf: ["--resume", ptid])
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

        let parser = CodexParser()
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
            if !s.isEmpty {
                onEvent(.error("[codex stderr] " + s))
            }
        }

        proc.terminationHandler = { p in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let status: AgentRunStatus
            if p.terminationReason == .uncaughtSignal { status = .cancelled }
            else if p.terminationStatus == 0 { status = .completed }
            else { status = .failed }
            let finalMsg = timeline.finalAssistantMessage
            onEvent(.status(status))
            onEvent(.finished(status, finalMessage: finalMsg, providerThreadId: timeline.providerThreadId))
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

final class TimelineAggregator: @unchecked Sendable {
    private var state = AssistantTimelineState()
    private let lock = NSLock()
    var finalAssistantMessage: String? {
        lock.lock(); defer { lock.unlock() }
        return state.turns.last?.finalAssistantMessage
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
