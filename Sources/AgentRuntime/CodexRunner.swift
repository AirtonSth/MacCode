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
        for component in searchPath(environmentPath: environmentPath, homeDirectory: homeDirectory) {
            let full = component + "/" + trimmed
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    private static func searchPath(environmentPath: String?, homeDirectory: String) -> [String] {
        var paths = (environmentPath ?? "")
            .split(separator: ":")
            .map(String.init)
        paths.append(contentsOf: [
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

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
        proc.environment = Self.processEnvironment(overrides: request.environment)
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
            let tail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
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

    public static func processEnvironment(overrides: [String: String], base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.merging(overrides) { _, override in override }
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
