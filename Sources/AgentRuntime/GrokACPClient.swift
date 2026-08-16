import Foundation
import CoreModel
import Persistence

public enum GrokACPError: Error, CustomStringConvertible {
    case missingBinary(String)
    case spawnFailed(String)
    case invalidJSON(String)
    case rpcError(code: Int?, message: String)
    case processExited(reason: Process.TerminationReason, status: Int32, stderrTail: String)
    case responseTypeMismatch(String)
    case unsupported(String)
    case requestTimedOut(String)

    public var description: String {
        switch self {
        case .missingBinary(let binary): return "Grok ACP binary not found: \(binary)"
        case .spawnFailed(let message): return "Failed to spawn Grok ACP: \(message)"
        case .invalidJSON(let line): return "Grok ACP emitted invalid JSON: \(line)"
        case .rpcError(_, let message): return "Grok ACP RPC error: \(message)"
        case .processExited(let reason, let status, let stderr):
            let suffix = stderr.isEmpty ? "" : ": \(stderr)"
            return "Grok ACP process exited (\(reason == .exit ? "exit" : "signal") \(status))\(suffix)"
        case .responseTypeMismatch(let method): return "Grok ACP \(method) response had an unexpected shape"
        case .unsupported(let message): return message
        case .requestTimedOut(let method): return "Grok ACP \(method) timed out"
        }
    }
}

enum GrokACPFailureContext: Sendable {
    case start
    case resume
    case turn
}

enum GrokACPFailureCategory: String, Sendable {
    case authRequired
    case rateLimited
    case network
    case timeout
    case invalidResume
    case nonRecoverable
}

struct GrokACPFailure: Error, CustomStringConvertible, LocalizedError, Sendable {
    let category: GrokACPFailureCategory
    let message: String

    var description: String { message }
    var errorDescription: String? { message }
}

enum GrokACPFailureTaxonomy {
    static let authRequiredMarker = "[auth-required]"
    static let rateLimitedMarker = "[retryable:rate-limit]"
    static let networkMarker = "[retryable:network]"
    static let timeoutMarker = "[retryable:timeout]"
    static let invalidResumeMarker = "[start-fresh:invalid-resume]"

    static func normalize(_ error: Error, context: GrokACPFailureContext) -> GrokACPFailure {
        if let failure = error as? GrokACPFailure { return failure }
        return normalizedFailure(
            category: category(for: error, context: context),
            diagnostic: String(describing: error)
        )
    }

    static func normalize(diagnostic: String, context: GrokACPFailureContext) -> GrokACPFailure {
        normalizedFailure(
            category: category(forDiagnostic: diagnostic, context: context),
            diagnostic: diagnostic
        )
    }

    private static func normalizedFailure(
        category: GrokACPFailureCategory,
        diagnostic: String
    ) -> GrokACPFailure {
        let safeDiagnostic = sanitize(diagnostic)
        let prefix: String
        switch category {
        case .authRequired:
            prefix = "\(authRequiredMarker) Grok authentication failed"
        case .rateLimited:
            prefix = "\(rateLimitedMarker) Grok rate limit"
        case .network:
            prefix = "\(networkMarker) Grok network failure"
        case .timeout:
            prefix = "\(timeoutMarker) Grok request timed out"
        case .invalidResume:
            prefix = "\(invalidResumeMarker) Grok invalid resume"
        case .nonRecoverable:
            prefix = "Grok ACP failure"
        }
        return GrokACPFailure(category: category, message: "\(prefix): \(safeDiagnostic)")
    }

    private static func category(
        for error: Error,
        context: GrokACPFailureContext
    ) -> GrokACPFailureCategory {
        if let error = error as? GrokACPError {
            switch error {
            case .requestTimedOut:
                return .timeout
            case .rpcError(let code, let message):
                if code == 401 || code == 403 { return .authRequired }
                if code == 429 { return .rateLimited }
                return category(forDiagnostic: message, context: context)
            default:
                break
            }
        }
        return category(forDiagnostic: String(describing: error), context: context)
    }

    private static func category(
        forDiagnostic diagnostic: String,
        context: GrokACPFailureContext
    ) -> GrokACPFailureCategory {
        let normalized = diagnostic.lowercased()
        if normalized.contains(invalidResumeMarker) { return .invalidResume }
        if normalized.contains(authRequiredMarker) { return .authRequired }
        if normalized.contains(rateLimitedMarker) { return .rateLimited }
        if normalized.contains(timeoutMarker) { return .timeout }
        if normalized.contains(networkMarker) { return .network }
        let invalidResumeMarkers = [
            "invalid resume", "invalid_resume", "invalid-resume", "resume invalid",
            "resume is invalid", "resume cursor", "failed to resume",
            "could not be resumed", "session/load failed", "session not found"
        ]
        if invalidResumeMarkers.contains(where: normalized.contains) {
            return .invalidResume
        }
        if context == .resume,
           normalized.contains("invalid session") || normalized.contains("unknown session") {
            return .invalidResume
        }
        let authMarkers = [
            "unauthorized", "unauthenticated", "authentication required", "login required",
            "sign in required", "token expired", "credential expired", "invalid_api_key",
            "invalid api key", "forbidden"
        ]
        if authMarkers.contains(where: normalized.contains) { return .authRequired }
        let rateLimitMarkers = ["rate limit", "rate_limit", "too many requests", "http 429"]
        if rateLimitMarkers.contains(where: normalized.contains) { return .rateLimited }
        let timeoutMarkers = ["timed out", "timeout", "deadline exceeded"]
        if timeoutMarkers.contains(where: normalized.contains) { return .timeout }
        let networkMarkers = [
            "network error", "network failure", "connection refused", "connection reset",
            "connection closed", "host unreachable", "dns failure", "socket error",
            "transport error", "websocket closed", "offline"
        ]
        if networkMarkers.contains(where: normalized.contains) { return .network }
        return .nonRecoverable
    }

    // PERF: compile once — sanitize runs on every Grok failure normalize and
    // recompiled 5 NSRegularExpressions via replacingOccurrences each call.
    private static let whitespaceCollapseRegex = try! NSRegularExpression(
        pattern: #"\s+"#
    )
    private static let diagnosticRedactions: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(
            pattern: #"(authorization\s*[:=]\s*bearer\s+)[^\s,;]+"#,
            options: [.caseInsensitive]
        ), "$1<redacted>"),
        (try! NSRegularExpression(
            pattern: #"\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            options: [.caseInsensitive]
        ), "Bearer <redacted>"),
        (try! NSRegularExpression(
            pattern: #"\b(api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+"#,
            options: [.caseInsensitive]
        ), "$1=<redacted>"),
        (try! NSRegularExpression(
            pattern: #"(?:file://)?/(?:Users|home|private|var|tmp|Volumes|opt|usr|etc)/[^\s,;]+"#,
            options: [.caseInsensitive]
        ), "<path>"),
    ]

    private static func sanitize(_ raw: String) -> String {
        var text = replaceAll(whitespaceCollapseRegex, in: raw, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for (regex, template) in diagnosticRedactions {
            text = replaceAll(regex, in: text, with: template)
        }
        if text.isEmpty { text = "Provider reported an error." }
        return String(text.prefix(800))
    }

    private static func replaceAll(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}

public enum GrokACPRequestID: Hashable, Sendable {
    case int(Int)
    case string(String)

    init?(_ value: Any?) {
        if let value = value as? Int { self = .int(value) }
        else if let value = value as? String, !value.isEmpty { self = .string(value) }
        else { return nil }
    }

    public var jsonValue: Any {
        switch self {
        case .int(let value): return value
        case .string(let value): return value
        }
    }

    public var stringValue: String {
        switch self {
        case .int(let value): return String(value)
        case .string(let value): return value
        }
    }
}

/// Grok agent stdio advertises `promptCapabilities.image=false` but still
/// accepts `type=image` prompt blocks end-to-end (live canary: 0.2.x and 1.0.x).
/// Use one effective gate for both capability advertisement and prompt embedding
/// so iOS Camera/Photos stay aligned with the wire path.
public enum GrokACPImageCompatibility {
    public static let supportedImageMediaTypes = [
        "image/jpeg", "image/png", "image/gif", "image/webp"
    ]

    /// Prefer the negotiated flag; for known-compatible agent versions override
    /// a false advertisement. Unknown versions fail closed when not advertised.
    public static func effectiveImageEnabled(advertised: Bool, agentVersion: String?) -> Bool {
        if advertised { return true }
        let version = agentVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { return false }
        // Verified families: 0.2.x and 1.0.x accept image blocks despite image=false.
        return version.hasPrefix("0.2.") || version.hasPrefix("1.0.")
    }
}

public struct GrokACPInitializeResult: Sendable, Equatable {
    public let protocolVersion: Int
    public let loadSession: Bool
    public let embeddedContext: Bool
    public let image: Bool
    public let audio: Bool
    public let resumeSession: Bool
    public let agentVersion: String?
    public let models: [AgentModelDescriptor]
    public let currentModelId: String?

    public init(
        protocolVersion: Int,
        loadSession: Bool,
        embeddedContext: Bool,
        image: Bool = false,
        audio: Bool = false,
        resumeSession: Bool = false,
        agentVersion: String? = nil,
        models: [AgentModelDescriptor] = [],
        currentModelId: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.loadSession = loadSession
        self.embeddedContext = embeddedContext
        self.image = image
        self.audio = audio
        self.resumeSession = resumeSession
        self.agentVersion = agentVersion
        self.models = models
        self.currentModelId = currentModelId
    }

    static func parse(_ result: [String: Any]) throws -> GrokACPInitializeResult {
        guard let version = result["protocolVersion"] as? Int, version == 1 else {
            throw GrokACPError.unsupported("Grok ACP protocol version 1 is required")
        }
        let capabilities = result["agentCapabilities"] as? [String: Any] ?? [:]
        let prompt = capabilities["promptCapabilities"] as? [String: Any] ?? [:]
        let sessions = capabilities["sessionCapabilities"] as? [String: Any] ?? [:]
        let metadata = result["_meta"] as? [String: Any] ?? [:]
        let modelState = metadata["modelState"] as? [String: Any]
        return GrokACPInitializeResult(
            protocolVersion: version,
            loadSession: capabilities["loadSession"] as? Bool ?? false,
            embeddedContext: prompt["embeddedContext"] as? Bool ?? false,
            image: prompt["image"] as? Bool ?? false,
            audio: prompt["audio"] as? Bool ?? false,
            resumeSession: sessions["resume"] != nil,
            agentVersion: metadata["agentVersion"] as? String,
            models: GrokACPClient.modelDescriptors(from: modelState),
            currentModelId: modelState?["currentModelId"] as? String
        )
    }
}

public struct GrokACPAvailableCommand: Sendable, Equatable {
    public let name: String
    public let description: String?
}

public struct GrokACPPermissionOption: Sendable, Equatable {
    public let optionId: String
    public let name: String
    public let kind: String
}

public struct GrokACPPermissionRequest: Sendable {
    public let requestId: GrokACPRequestID
    public let sessionId: String
    public let toolCallId: String
    public let title: String
    public let detail: String?
    public let options: [GrokACPPermissionOption]

    static func parse(id: GrokACPRequestID, params: Any?) throws -> GrokACPPermissionRequest {
        guard let params = params as? [String: Any],
              let sessionId = params["sessionId"] as? String,
              let tool = params["toolCall"] as? [String: Any],
              let toolCallId = tool["toolCallId"] as? String else {
            throw GrokACPError.responseTypeMismatch("session/request_permission")
        }
        let options = (params["options"] as? [[String: Any]] ?? []).compactMap { raw -> GrokACPPermissionOption? in
            guard let optionId = raw["optionId"] as? String,
                  let name = raw["name"] as? String,
                  let kind = raw["kind"] as? String else { return nil }
            return GrokACPPermissionOption(optionId: optionId, name: name, kind: kind)
        }
        guard !options.isEmpty else { throw GrokACPError.responseTypeMismatch("session/request_permission options") }
        return GrokACPPermissionRequest(
            requestId: id,
            sessionId: sessionId,
            toolCallId: toolCallId,
            title: tool["title"] as? String ?? "Grok tool request",
            detail: Self.jsonString(tool["rawInput"]),
            options: options
        )
    }

    public func optionId(for response: AgentProviderRequestResponse) -> String? {
        let kind: String
        switch response {
        case .approve: kind = "allow_once"
        case .approveForSession: kind = "allow_always"
        case .decline: kind = "reject_once"
        case .cancel: return nil
        }
        return options.first { $0.kind == kind }?.optionId
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return value as? String }
        return String(data: data, encoding: .utf8)
    }
}

struct GrokACPSessionMode: Equatable {
    let id: String
    let name: String
    let description: String?
}

struct GrokACPSessionOpenResult {
    let sessionId: String
    let models: [AgentModelDescriptor]
    let currentModelId: String?
    let availableModes: [GrokACPSessionMode]
    let currentModeId: String?

    var planModeId: String? {
        availableModes.first {
            $0.id.caseInsensitiveCompare("plan") == .orderedSame
                || $0.name.caseInsensitiveCompare("plan") == .orderedSame
        }?.id
    }
}

public enum GrokACPTerminalClassifier {
    /// ACP session/prompt `stopReason` wire tokens (grok-build / xai-grok-pager).
    /// Completed-class: end_turn, max_tokens, max_turn_requests, refusal.
    public static func status(stopReason: String) -> AgentRunStatus {
        switch stopReason {
        case "end_turn", "max_tokens", "max_turn_requests", "refusal":
            return .completed
        case "cancelled":
            return .cancelled
        default:
            return .failed
        }
    }

    /// True for stop reasons that successfully complete the turn (not failed/cancelled).
    public static func isCompletedStopReason(_ stopReason: String) -> Bool {
        status(stopReason: stopReason) == .completed
    }

    public static func status(
        promptResolved: Bool,
        cancelRequested: Bool,
        forcedKillByUs: Bool,
        terminationReason: Process.TerminationReason,
        exitStatus: Int32
    ) -> AgentRunStatus {
        if promptResolved { return .completed }
        if cancelRequested && forcedKillByUs { return .cancelled }
        if terminationReason == .uncaughtSignal || exitStatus != 0 { return .failed }
        return .failed
    }
}

public final class GrokACPClient: @unchecked Sendable {
    public typealias JSONObject = [String: Any]
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: Any?) -> Void
    public typealias ServerRequestHandler = @Sendable (_ id: GrokACPRequestID, _ method: String, _ params: Any?) async throws -> Any?

    private struct Pending { let resume: @Sendable (Result<Any?, Error>) -> Void }

    private let process: Process
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let parseQueue = DispatchQueue(label: "remotecode.grok-acp.parse")
    private let parseQueueKey = DispatchSpecificKey<UInt8>()
    private let writeQueue = DispatchQueue(label: "remotecode.grok-acp.write")
    private let lock = NSLock()
    private let lineBuffer = LineBuffer()
    private var nextId = 1
    private var pending: [Int: Pending] = [:]
    private var stderrBuffer = Data()
    private var stopped = false
    private let tokenSaverCensusAllowed: Bool
    private let foreignUserUID: uid_t?
    private static let stderrLimit = 8_192

    public var notificationHandler: NotificationHandler?
    public var serverRequestHandler: ServerRequestHandler?
    public var terminationHandler: (@Sendable (_ reason: Process.TerminationReason, _ status: Int32, _ error: Error) -> Void)?
    public var runningProcess: Process { process }

    /// Exact argv for every Grok ACP stdio launch.
    /// `--no-leader` keeps the worker isolated from shared-leader auth that
    /// requires a `client_id` RemoteCode does not supply (Grok 0.2.112+).
    /// Unsupported shared-leader mode must fail through the existing error path.
    public static let launchArguments = ["agent", "--no-leader", "stdio"]

    /// Exact process argv for the closed sam-grok-worker runtime profile.
    /// Every raw guard is enforced by the Grok process itself before ACP starts.
    static func launchArguments(for request: AgentRunRequest) throws -> [String] {
        guard request.environment[AgentAppRuntimeProfile.environmentKey]
                == AgentAppRuntimeProfile.samGrokWorkerV1.rawValue else {
            // Regular ACP path: model/effort are AgentArgs under the `agent`
            // subcommand (grok-build cli.rs + run_agent_command). Flags before
            // `agent` bind top-level PagerArgs and are discarded on dispatch —
            // live: `grok --reasoning-effort low agent …` stays default high;
            // `grok agent --reasoning-effort low …` seeds low (GROK-ACP-008).
            // Shape: agent [--model M] [--reasoning-effort E] --no-leader stdio.
            var args: [String] = ["agent"]
            let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty {
                args.append(contentsOf: ["--model", model])
            }
            if let effort = request.reasoningEffort,
               GrokRunner.modelSupportsReasoningEffort(model) {
                args.append(contentsOf: GrokRunner.effortArgs(effort, model: model))
            }
            args.append(contentsOf: ["--no-leader", "stdio"])
            return args
        }
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.provider == .grok,
              model == "grok-4.5",
              request.providerThreadId == nil,
              request.permissionMode == .autoAcceptEdits,
              let effort = request.reasoningEffort,
              GrokRunner.grok45ReasoningEfforts.contains(effort) else {
            throw GrokACPError.unsupported(
                "invalid sam-grok-worker Agent App runtime profile"
            )
        }
        // Top-level-only flags stay before `agent` (PagerArgs / main.rs
        // no_auto_update handoff). AgentArgs-owned model/effort/yolo must
        // follow `agent` or they never seed the stdio session.
        return [
            "--no-memory",
            "--no-subagents",
            "--disallowed-tools", "Agent",
            "--no-auto-update",
            "--sandbox", "workspace",
            "agent",
            "--model", model,
            "--reasoning-effort", effort.rawValue,
            "--always-approve",
            "--no-leader",
            "stdio"
        ]
    }

    public init(
        binary: String = "grok",
        cwd: String,
        environment: [String: String] = [:],
        launchArguments: [String] = GrokACPClient.launchArguments,
        runAsUser: AgentRunAsUser? = nil,
        askpassPath: String? = nil,
        tagProcess: Bool = true,
        notificationHandler: NotificationHandler? = nil,
        serverRequestHandler: ServerRequestHandler? = nil,
        tokenSaverCensusAllowed: Bool = false
    ) throws {
        let resolved = binary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "grok" : binary
        guard let path = ProcessLocator.resolve(resolved) else { throw GrokACPError.missingBinary(resolved) }
        self.notificationHandler = notificationHandler
        self.serverRequestHandler = serverRequestHandler
        self.tokenSaverCensusAllowed = tokenSaverCensusAllowed
        self.foreignUserUID = runAsUser.flatMap { $0.uid == getuid() ? nil : $0.uid }
        parseQueue.setSpecific(key: parseQueueKey, value: 1)
        do {
            self.process = try ProviderSubprocessLauncher.makeProcess(
                provider: .grok,
                executablePath: path,
                arguments: launchArguments,
                currentDirectory: cwd,
                environment: environment,
                runAsUser: runAsUser,
                askpassPath: askpassPath
            )
        } catch {
            throw GrokACPError.spawnFailed(error.localizedDescription)
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            parseQueue.async {
                for line in self.lineBuffer.take(data) { self.handleLine(line) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            parseQueue.async {
                self.stderrBuffer.append(data)
                if self.stderrBuffer.count > Self.stderrLimit {
                    self.stderrBuffer.removeFirst(self.stderrBuffer.count - Self.stderrLimit)
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let error = GrokACPError.processExited(
                reason: process.terminationReason,
                status: process.terminationStatus,
                stderrTail: self.stderrTail()
            )
            self.failPending(error)
            self.terminationHandler?(process.terminationReason, process.terminationStatus, error)
        }
        do {
            try process.run()
            if tagProcess {
                try ProcessSpawnTagger.tagProcess(
                    process,
                    provider: .grok,
                    foreignUserLaunch: foreignUserUID != nil
                )
            }
        }
        catch { throw GrokACPError.spawnFailed(error.localizedDescription) }
    }

    deinit { stop() }

    public static func initializeParams(clientVersion: String) -> JSONObject {
        [
            "protocolVersion": 1,
            "clientCapabilities": JSONObject(),
            "clientInfo": ["name": "RemoteCode", "title": "RemoteCode", "version": clientVersion]
        ]
    }

    public func initialize(clientVersion: String = "0.0.0") async throws -> GrokACPInitializeResult {
        let result = try await requestJSONObject(method: "initialize", params: Self.initializeParams(clientVersion: clientVersion), timeout: 15)
        return try GrokACPInitializeResult.parse(result)
    }

    public static func sessionMCPServers(
        existing: [Any] = [],
        command: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Any] {
        let resolved = command
            ?? AgentSkillInstaller.resolveServiceBinary()?.path
            ?? ComputerUseMCPAdmit.fallbackCommand
        let withComputerUse = ComputerUseMCPAdmit.admitGrokACP(existing: existing, command: resolved)
        let withSelfConfig = BotSelfConfigMCPAdmit.admitGrokACP(
            existing: withComputerUse,
            command: resolved,
            environment: environment
        )
        return BotBrowserMCPAdmit.admitGrokACP(
            existing: withSelfConfig,
            command: resolved,
            environment: environment
        )
    }

    func newSession(cwd: String) async throws -> GrokACPSessionOpenResult {
        let result = try await requestJSONObject(
            method: "session/new",
            params: ["cwd": cwd, "mcpServers": Self.sessionMCPServers()],
            timeout: 20
        )
        return try Self.openResult(result, fallbackSessionId: nil)
    }

    /// When `noReplay` is true, params include `_meta.noReplay` (grok-build
    /// mvp_agent `parse_no_replay`) so the agent skips gateway history replay.
    /// Default false preserves full replay for recover/readThread paths.
    func loadSession(
        sessionId: String,
        cwd: String,
        noReplay: Bool = false
    ) async throws -> GrokACPSessionOpenResult {
        var params: JSONObject = [
            "sessionId": sessionId,
            "cwd": cwd,
            "mcpServers": Self.sessionMCPServers(),
        ]
        if noReplay {
            params["_meta"] = ["noReplay": true]
        }
        let result = try await requestJSONObject(
            method: "session/load",
            params: params,
            timeout: 60
        )
        return try Self.openResult(result, fallbackSessionId: sessionId)
    }

    /// Model-aware ACP value. Nil means the selected model does not advertise
    /// reasoning configuration, so no acknowledgement can honestly be claimed.
    static func wireReasoningEffort(
        _ effort: AgentReasoningEffort,
        modelId: String = ""
    ) -> String? {
        GrokRunner.normalizedReasoningEffort(effort, model: modelId)?.rawValue
    }

    /// `reasoningEffort` is the ACP `_meta.reasoningEffort` wire value (grok-build
    /// `REASONING_EFFORT_META_KEY`). Omit when the host has nothing to bind.
    /// Values are mapped via `wireReasoningEffort` before the wire call.
    func setModel(
        sessionId: String,
        modelId: String,
        reasoningEffort: AgentReasoningEffort? = nil
    ) async throws {
        var params: JSONObject = ["sessionId": sessionId, "modelId": modelId]
        if let reasoningEffort,
           let wireEffort = Self.wireReasoningEffort(reasoningEffort, modelId: modelId) {
            params["_meta"] = ["reasoningEffort": wireEffort]
        }
        _ = try await requestJSONObject(method: "session/set_model", params: params, timeout: 15)
    }

    func setMode(sessionId: String, modeId: String) async throws {
        _ = try await requestJSONObject(method: "session/set_mode", params: ["sessionId": sessionId, "modeId": modeId], timeout: 15)
    }

    func prompt(
        sessionId: String,
        request: AgentRunRequest,
        capabilities: GrokACPInitializeResult,
        writePermit: AgentRunAcceptancePermit,
        beforeWrite: @escaping @Sendable () -> Void,
        onAccepted: @escaping @Sendable () throws -> Void
    ) async throws -> JSONObject {
        try await requestJSONObject(
            method: "session/prompt",
            params: ["sessionId": sessionId, "prompt": try Self.promptBlocks(for: request, capabilities: capabilities)],
            timeout: nil,
            acceptancePermit: request.acceptancePermit,
            writePermit: writePermit,
            beforeWrite: beforeWrite,
            onAccepted: onAccepted
        )
    }

    public func cancel(sessionId: String) throws {
        try notify(method: "session/cancel", params: ["sessionId": sessionId])
    }

    public func notify(method: String, params: Any? = nil) throws {
        var payload: JSONObject = ["jsonrpc": "2.0", "method": method]
        if let params { payload["params"] = params }
        try write(payload)
    }

    public func stop() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        guard shouldStop else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            ProcessTerminator.terminateTree(
                process,
                foreignUserUID: foreignUserUID
            )
        }
    }

    public func stopImmediatelyForAppTermination() {
        lock.lock()
        let shouldStop = !stopped
        stopped = true
        lock.unlock()
        guard shouldStop else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            ProcessTerminator.terminateTreeImmediately(
                process,
                foreignUserUID: foreignUserUID
            )
        }
    }

    public static func promptBlocks(for request: AgentRunRequest, capabilities: GrokACPInitializeResult) throws -> [JSONObject] {
        var blocks: [JSONObject] = []
        let providerPrompt = AgentSkillInstaller.tokenSaverProviderPrompt(
            request.providerPrompt,
            environment: request.environment
        )
        // Additive: background-await self-declare marker so shell-detached
        // orchestration stalls reach the host's [[RC_AWAITING]] recovery path.
        // systemPromptDirective only — NOT alwaysOnClaudeDirectives (MCP rules
        // are Claude-CLI-specific).
        let composed: String
        if providerPrompt.isEmpty {
            composed = BackgroundAwaitContinuation.systemPromptDirective
        } else {
            composed = providerPrompt + "\n\n" + BackgroundAwaitContinuation.systemPromptDirective
        }
        if !composed.isEmpty { blocks.append(["type": "text", "text": composed]) }
        for attachment in request.attachments {
            switch attachment.kind {
            case .image:
                guard GrokACPImageCompatibility.effectiveImageEnabled(
                    advertised: capabilities.image,
                    agentVersion: capabilities.agentVersion
                ) else {
                    throw GrokACPError.unsupported(
                        "Grok ACP \(capabilities.agentVersion ?? "v1") does not support image prompts"
                    )
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: attachment.path))
                blocks.append([
                    "type": "image",
                    "data": data.base64EncodedString(),
                    "mimeType": attachment.mimeType ?? "application/octet-stream"
                ])
            case .file:
                guard capabilities.embeddedContext else {
                    throw GrokACPError.unsupported("Grok ACP does not negotiate embedded file context")
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: attachment.path))
                guard let text = String(data: data, encoding: .utf8) else {
                    throw GrokACPError.unsupported("Grok ACP embedded context requires UTF-8 text: \(attachment.displayName)")
                }
                blocks.append([
                    "type": "resource",
                    "resource": [
                        "uri": URL(fileURLWithPath: attachment.path).absoluteString,
                        "mimeType": attachment.mimeType ?? "text/plain",
                        "text": text
                    ]
                ])
            }
        }
        return blocks
    }

    private func requestJSONObject(
        method: String,
        params: Any?,
        timeout: TimeInterval?,
        acceptancePermit: AgentRunAcceptancePermit? = nil,
        writePermit: AgentRunAcceptancePermit? = nil,
        beforeWrite: (@Sendable () -> Void)? = nil,
        onAccepted: (@Sendable () throws -> Void)? = nil
    ) async throws -> JSONObject {
        let value: Any? = try await request(
            method: method,
            params: params,
            timeout: timeout,
            acceptancePermit: acceptancePermit,
            writePermit: writePermit,
            beforeWrite: beforeWrite,
            onAccepted: onAccepted
        )
        guard let object = value as? JSONObject else { throw GrokACPError.responseTypeMismatch(method) }
        return object
    }

    private func request(
        method: String,
        params: Any?,
        timeout: TimeInterval?,
        acceptancePermit: AgentRunAcceptancePermit? = nil,
        writePermit: AgentRunAcceptancePermit? = nil,
        beforeWrite: (@Sendable () -> Void)? = nil,
        onAccepted: (@Sendable () throws -> Void)? = nil
    ) async throws -> Any? {
        let id = reserveId()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = Pending { continuation.resume(with: $0) }
            lock.unlock()
            var payload: JSONObject = ["jsonrpc": "2.0", "id": id, "method": method]
            if let params { payload["params"] = params }
            do {
                if let onAccepted {
                    let writeAndAccept = {
                        beforeWrite?()
                        let queueGuardedWrite = {
                            if let acceptancePermit {
                                try acceptancePermit.withAcceptance(failureOutcome: .notAccepted) {
                                    try self.write(payload)
                                }
                            } else {
                                try self.write(payload)
                            }
                        }
                        if let writePermit {
                            try writePermit.withAcceptance(failureOutcome: .notAccepted, queueGuardedWrite)
                        } else {
                            try queueGuardedWrite()
                        }
                        try onAccepted()
                    }
                    if DispatchQueue.getSpecific(key: parseQueueKey) != nil {
                        try writeAndAccept()
                    } else {
                        try parseQueue.sync(execute: writeAndAccept)
                    }
                } else {
                    try write(payload)
                }
            }
            catch { completePending(id: id, result: .failure(error)) }
            if let timeout {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    if self.completePending(id: id, result: .failure(GrokACPError.requestTimedOut(method))) { self.stop() }
                }
            }
        }
    }

    private func reserveId() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        return id
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject else {
            let error = GrokACPError.invalidJSON(String(line.prefix(500)))
            failPending(error)
            terminationHandler?(.exit, -1, error)
            stop()
            return
        }
        if let id = object["id"] as? Int, object["method"] as? String == nil {
            if let error = object["error"] as? JSONObject {
                completePending(id: id, result: .failure(GrokACPError.rpcError(
                    code: error["code"] as? Int,
                    message: error["message"] as? String ?? "Unknown Grok ACP error"
                )))
            } else {
                completePending(id: id, result: .success(object["result"]))
            }
            return
        }
        guard let method = object["method"] as? String else { return }
        if let id = GrokACPRequestID(object["id"]) {
            Task { [weak self] in await self?.handleServerRequest(id: id, method: method, params: object["params"]) }
        } else {
            notificationHandler?(method, object["params"])
        }
    }

    private func handleServerRequest(id: GrokACPRequestID, method: String, params: Any?) async {
        do {
            guard let handler = serverRequestHandler else { throw GrokACPError.unsupported("Unhandled Grok ACP request: \(method)") }
            let result = try await handler(id, method, params)
            try write(["jsonrpc": "2.0", "id": id.jsonValue, "result": result ?? NSNull()])
        } catch {
            try? write(["jsonrpc": "2.0", "id": id.jsonValue, "error": ["code": -32603, "message": String(describing: error)]])
        }
    }

    @discardableResult
    private func completePending(id: Int, result: Result<Any?, Error>) -> Bool {
        lock.lock()
        let request = pending.removeValue(forKey: id)
        lock.unlock()
        request?.resume(result)
        return request != nil
    }

    private func failPending(_ error: Error) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        for request in all.values { request.resume(.failure(error)) }
    }

    private func write(_ object: JSONObject) throws {
        // Foundation defaults escape `/` as `\/` (e.g. `session\/prompt`). grok-build
        // documents that form as a historical ACP envelope hazard; emit canonical paths.
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.withoutEscapingSlashes]
        )
        var line = data
        line.append(0x0A)
        let toWrite: Data
        if tokenSaverCensusAllowed, object["method"] as? String == "session/prompt" {
            let binding = TokenSaverCensusSeam.defaultBinding(
                trigger: "provider_outbound_user",
                provider: "grok",
                providerAdapterVersion: "acp-jsonrpc",
                toolShape: "session_prompt_jsonrpc_line"
            )
            toWrite = TokenSaverCensusSeam.observeProviderVisiblePayload(
                line,
                binding: binding,
                control: .noChange,
                streamKind: .completedTranscript,
                toolKind: .builtin,
                isSameUser: true
            )
        } else {
            toWrite = line
        }
        try writeQueue.sync {
            try GuardedStdinWrite.write(
                toWrite, to: stdinPipe.fileHandleForWriting, process: process,
                notFound: { GrokACPError.processExited(reason: .exit, status: -1, stderrTail: "") }
            )
        }
    }

    private func stderrTail() -> String {
        parseQueue.sync {
            String(decoding: stderrBuffer.suffix(Self.stderrLimit), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func openResult(_ result: JSONObject, fallbackSessionId: String?) throws -> GrokACPSessionOpenResult {
        guard let sessionId = result["sessionId"] as? String ?? fallbackSessionId, !sessionId.isEmpty else {
            throw GrokACPError.responseTypeMismatch("session open")
        }
        let state = result["models"] as? JSONObject
        let models = modelDescriptors(from: state)
        let modeState = result["modes"] as? JSONObject
        let availableModes = (modeState?["availableModes"] as? [JSONObject] ?? []).compactMap { raw -> GrokACPSessionMode? in
            guard let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            return GrokACPSessionMode(id: id, name: name, description: raw["description"] as? String)
        }
        return GrokACPSessionOpenResult(
            sessionId: sessionId,
            models: models,
            currentModelId: state?["currentModelId"] as? String,
            availableModes: availableModes,
            currentModeId: modeState?["currentModeId"] as? String
        )
    }

    static func modelDescriptors(from state: JSONObject?) -> [AgentModelDescriptor] {
        let rawModels = state?["availableModels"] as? [JSONObject] ?? []
        return rawModels.compactMap { raw -> AgentModelDescriptor? in
            guard let id = raw["modelId"] as? String, !id.isEmpty else { return nil }
            let metadata = raw["_meta"] as? JSONObject ?? [:]
            let efforts = metadata["reasoningEfforts"] as? [JSONObject] ?? []
            let supported = efforts.compactMap { ($0["value"] as? String).flatMap(AgentReasoningEffort.init(rawValue:)) }
            return AgentModelDescriptor(
                id: id,
                label: raw["name"] as? String ?? id,
                provider: .grok,
                supportsReasoning: metadata["supportsReasoningEffort"] as? Bool ?? !supported.isEmpty,
                supportedReasoningEfforts: supported,
                supportsCustomModel: false
            )
        }
    }
}
