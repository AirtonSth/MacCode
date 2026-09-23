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
        // 402 Payment Required: Grok Build balance exhausted is not retryable
        // or auth-required — surface it verbatim so the host can circuit-break
        // and the mirror can show the real cause. Must precede auth/rate checks
        // so "402 Payment" isn't mis-tagged as auth.
        if normalized.contains("402") && normalized.contains("payment") {
            return .nonRecoverable
        }
        if normalized.contains("balance exhausted") || normalized.contains("usage balance") {
            return .nonRecoverable
        }
        if normalized.contains("payment required") {
            return .nonRecoverable
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
    /// Live current effort: `configOptions.reasoning_effort.currentValue` when
    /// present, else model `_meta.reasoningEffort` (may differ from option default).
    let currentReasoningEffortRaw: String?
    let availableModes: [GrokACPSessionMode]
    let currentModeId: String?
    /// Typed ACP `configOptions` from session/new|load (model + reasoning_effort).
    let configOptions: [[String: Any]]

    /// True when session/new|load advertised a selectable `reasoning_effort` option.
    var advertisesReasoningEffortConfig: Bool {
        !advertisedReasoningEffortIds.isEmpty
    }

    var planModeId: String? {
        availableModes.first {
            $0.id.caseInsensitiveCompare("plan") == .orderedSame
                || $0.name.caseInsensitiveCompare("plan") == .orderedSame
        }?.id
    }

    /// Effort ids advertised on the `reasoning_effort` config option, when present.
    /// Live grok 1.0.34 builds that list from the *session* current model. When
    /// the process default is not the host model (deepseek `max`/`none` vs
    /// grok-4.6 `low|medium|high|xhigh`), intersect with the current model's
    /// `_meta.reasoningEfforts` so stale ads cannot bind.
    var advertisedReasoningEffortIds: [String] {
        guard let option = configOptions.first(where: {
            (($0["id"] as? String) ?? ($0["configId"] as? String)) == "reasoning_effort"
        }) else { return [] }
        let values = option["options"] as? [[String: Any]]
            ?? option["values"] as? [[String: Any]]
            ?? []
        let fromConfig = values.compactMap { raw -> String? in
            let id = (raw["value"] as? String) ?? (raw["id"] as? String)
            let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let trimmedModel = currentModelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelIds = (models.first { $0.id == trimmedModel } ?? models.first)?
            .supportedReasoningEfforts.map(\.rawValue) ?? []
        guard !modelIds.isEmpty else { return fromConfig }
        let allowed = Set(modelIds)
        let intersected = fromConfig.filter { allowed.contains($0) }
        return intersected.isEmpty ? modelIds : intersected
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
    private let mcpEnvironment: [String: String]
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
              request.providerThreadId == nil,
              request.permissionMode == .autoAcceptEdits,
              let effort = request.reasoningEffort,
              Self.admitsSamGrokWorker(model: model, effort: effort) else {
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
        self.mcpEnvironment = environment
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
        let withSelfConfig = BotSelfConfigMCPAdmit.admitGrokACP(
            existing: existing,
            command: resolved,
            environment: environment
        )
        let withBrowser = BotBrowserMCPAdmit.admitGrokACP(
            existing: withSelfConfig,
            command: resolved,
            environment: environment
        )
        let withWeb = BotWebMCPAdmit.admitGrokACP(
            existing: withBrowser,
            command: resolved,
            environment: environment
        )
        // The librarian MCP is Token Saver surface: admitted only while the
        // run carries the Token Saver hint, matching Claude (--mcp-config /
        // SDK mcp_servers) and Codex (-c mcp_servers.<name>.* per process).
        let withDistill = DistillMCPAdmit.isEnabled(environment: environment)
            ? DistillMCPAdmit.admitGrokACP(
                existing: withWeb,
                command: resolved,
                environment: environment
            )
            : withWeb
        let withComputer = BotComputerMCPAdmit.admitGrokACP(
            existing: withDistill,
            command: resolved,
            environment: environment
        )
        guard environment[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey] == "1" else {
            return withComputer
        }
        return ComputerUseMCPAdmit.admitGrokACP(existing: withComputer, command: resolved)
    }

    /// ACP `session/new` cwd must be an existing absolute path. Empty or
    /// relative values (workspace-less bot threads falling through to
    /// `FileManager.default.currentDirectoryPath`) are `-32602 Invalid params`
    /// (`Path is not absolute`).
    public static func resolvedSessionCwd(
        _ cwd: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/"), fileExists(trimmed) {
            return trimmed
        }
        return home
    }

    /// Prefix-aware sam-grok-worker admission: grok-4.5 and grok-4.6 only,
    /// with effort taken from `GrokReasoningPolicy.supportedEfforts(for:)`.
    public static func admitsSamGrokWorker(model: String, effort: AgentReasoningEffort) -> Bool {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.hasPrefix("grok-4.5") || id.hasPrefix("grok-4.6") else { return false }
        return GrokReasoningPolicy.supportedEfforts(for: model).contains(effort)
    }

    /// ACP `session/new` / `session/load` params. `yoloMode` is spawn-time
    /// always-approve (grok-build `_meta.yoloMode`); `noReplay` is the existing
    /// load-path skip. Both share one `_meta` object so neither replaces the other.
    /// Stamp `yoloMode` for both polarities: omitting the key inherits
    /// grok-build `default_yolo_mode`. `autoMode` is always false — RemoteCode
    /// autoAcceptEdits maps to `set_mode acceptEdits`, not Grok auto, and an
    /// omitted key inherits `default_auto_mode`.
    /// grok-build 1.0.5+ reads `_meta.modelId` and `_meta.reasoningEffort` at
    /// spawn (`session_setup` / `parse_reasoning_effort_meta`) so the session
    /// is not created on the process default model (live 1.0.34: deepseek).
    static func sessionOpenParams(
        cwd: String,
        mcpServers: [Any],
        sessionId: String? = nil,
        yoloMode: Bool = false,
        noReplay: Bool = false,
        modelId: String? = nil,
        reasoningEffort: AgentReasoningEffort? = nil
    ) -> JSONObject {
        var params: JSONObject = [
            "cwd": cwd,
            "mcpServers": mcpServers,
        ]
        if let sessionId {
            params["sessionId"] = sessionId
        }
        var meta: JSONObject = [
            "yoloMode": yoloMode,
            "autoMode": false,
        ]
        if noReplay {
            meta["noReplay"] = true
        }
        let trimmedModel = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedModel.isEmpty {
            meta["modelId"] = trimmedModel
        }
        if let reasoningEffort,
           let wire = wireReasoningEffort(reasoningEffort, modelId: trimmedModel) {
            meta["reasoningEffort"] = wire
        }
        if !meta.isEmpty {
            params["_meta"] = meta
        }
        return params
    }

    func newSession(
        cwd: String,
        yoloMode: Bool = false,
        modelId: String? = nil,
        reasoningEffort: AgentReasoningEffort? = nil
    ) async throws -> GrokACPSessionOpenResult {
        let result = try await requestJSONObject(
            method: "session/new",
            params: Self.sessionOpenParams(
                cwd: Self.resolvedSessionCwd(cwd),
                mcpServers: Self.sessionMCPServers(environment: mcpEnvironment),
                yoloMode: yoloMode,
                modelId: modelId,
                reasoningEffort: reasoningEffort
            ),
            timeout: 20
        )
        return try Self.openResult(result, fallbackSessionId: nil)
    }

    /// When `noReplay` is true, params include `_meta.noReplay` (grok-build
    /// mvp_agent `parse_no_replay`) so the agent skips gateway history replay.
    /// Default false preserves full replay for recover/readThread paths.
    /// `_meta.yoloMode` is stamped for both polarities so cold load does not
    /// inherit grok-build `default_yolo_mode`.
    func loadSession(
        sessionId: String,
        cwd: String,
        noReplay: Bool = false,
        yoloMode: Bool = false,
        modelId: String? = nil,
        reasoningEffort: AgentReasoningEffort? = nil
    ) async throws -> GrokACPSessionOpenResult {
        let params = Self.sessionOpenParams(
            cwd: Self.resolvedSessionCwd(cwd),
            mcpServers: Self.sessionMCPServers(environment: mcpEnvironment),
            sessionId: sessionId,
            yoloMode: yoloMode,
            noReplay: noReplay,
            modelId: modelId,
            reasoningEffort: reasoningEffort
        )
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
        modelId: String = "",
        advertisedEfforts: [AgentReasoningEffort] = []
    ) -> String? {
        if advertisedEfforts.contains(effort) {
            return effort.rawValue
        }
        return GrokRunner.normalizedReasoningEffort(effort, model: modelId)?.rawValue
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

    /// Flat-string `session/set_config_option` (live grok 1.0.25+). Nested
    /// `{value:{value}}` and `optionId` shapes still return `-32602`.
    func setConfigOption(
        sessionId: String,
        configId: String,
        value: String
    ) async throws {
        _ = try await requestJSONObject(
            method: "session/set_config_option",
            params: [
                "sessionId": sessionId,
                "configId": configId,
                "value": value,
            ],
            timeout: 15
        )
    }

    /// Pure routing for model/effort binds before a prompt.
    /// Prefer flat `session/set_config_option` for effort-only binds when the
    /// open result advertised `reasoning_effort` (live grok 1.0.25). Fall back
    /// to `session/set_model` + `_meta.reasoningEffort` for older agents /
    /// missing configOptions (1.0.13 rejected set_config_option).
    enum ModelEffortBind: Equatable {
        case none
        case setModel(modelId: String, reasoningEffort: AgentReasoningEffort?)
        case setConfigOption(configId: String, value: String, effort: AgentReasoningEffort)
    }

    static func modelEffortBind(
        requestModel: String,
        sessionModel: String,
        requestEffort: AgentReasoningEffort?,
        sessionEffort: AgentReasoningEffort?,
        prefersConfigOptionEffort: Bool = false,
        advertisedEfforts: [AgentReasoningEffort] = []
    ) -> ModelEffortBind {
        let model = requestModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetModel = model.isEmpty ? sessionModel : model
        // session/new|load ads are not refreshed after setModel; keep only
        // efforts the target model still supports so grok-4.6 xhigh cannot
        // skip the grok-4.5 clamp. Empty ads still fall through to
        // GrokRunner.normalizedReasoningEffort (muse-spark empty _meta).
        let supported = GrokReasoningPolicy.supportedEfforts(for: targetModel)
        let targetEffort = requestEffort.flatMap { requested -> AgentReasoningEffort? in
            if advertisedEfforts.contains(requested), supported.contains(requested) {
                return requested
            }
            return GrokRunner.normalizedReasoningEffort(requested, model: targetModel)
        }
        let needsModelBind = !model.isEmpty && model != sessionModel
        let needsEffortBind = targetEffort != sessionEffort
        if needsModelBind {
            return .setModel(modelId: targetModel, reasoningEffort: targetEffort)
        }
        if needsEffortBind, let targetEffort,
           let wire = wireReasoningEffort(
            targetEffort, modelId: targetModel, advertisedEfforts: advertisedEfforts
           ) {
            if prefersConfigOptionEffort {
                return .setConfigOption(
                    configId: "reasoning_effort",
                    value: wire,
                    effort: targetEffort
                )
            }
            return .setModel(modelId: targetModel, reasoningEffort: targetEffort)
        }
        return .none
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

    /// Serializes generation admission with the physical cancel write. If a
    /// newer prompt has already reached this write queue, `admittedBy` observes
    /// its newer generation and the stale cancel never reaches ACP. If cancel
    /// wins the queue, its line is written before that newer prompt line.
    @discardableResult
    func cancel(
        sessionId: String,
        admittedBy: @escaping @Sendable () -> Bool
    ) throws -> Bool {
        try write(
            ["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionId]],
            admittedBy: admittedBy
        )
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
        let alwaysOn = BotPeerDelegation.appendingTurnContext(
            to: BackgroundAwaitContinuation.systemPromptDirective
                + "\n\n" + BotPeerDelegation.providerDirective,
            environment: request.environment
        )
        let composed = providerPrompt.isEmpty
            ? alwaysOn
            : providerPrompt + "\n\n" + alwaysOn
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
                let payload: AgentAttachmentWireImage.Payload
                do {
                    payload = try AgentAttachmentWireImage.encode(
                        path: attachment.path,
                        mimeType: attachment.mimeType ?? "application/octet-stream"
                    )
                } catch let error as AgentAttachmentWireImage.EncodeError {
                    throw GrokACPError.unsupported(error.description)
                }
                blocks.append([
                    "type": "image",
                    "data": payload.data.base64EncodedString(),
                    "mimeType": payload.mediaType
                ])
            case .file:
                guard capabilities.embeddedContext else {
                    throw GrokACPError.unsupported("Grok ACP does not negotiate embedded file context")
                }
                let prefix: EmbeddedFilePrefix
                do {
                    prefix = try embeddedUTF8FilePrefix(
                        path: attachment.path,
                        displayName: attachment.displayName
                    )
                } catch let error as EmbeddedFilePrefixError {
                    throw GrokACPError.unsupported(error.description)
                }
                blocks.append([
                    "type": "resource",
                    "resource": [
                        "uri": URL(fileURLWithPath: attachment.path).absoluteString,
                        "mimeType": attachment.mimeType ?? "text/plain",
                        "text": prefix.wireText
                    ]
                ])
            }
        }
        return blocks
    }

    static let embeddedFilePrefixBytes = 512 * 1_024

    struct EmbeddedFilePrefix: Equatable {
        let text: String
        let originalByteCount: Int
        let truncated: Bool
        let path: String

        var wireText: String {
            guard truncated else { return text }
            return text
                + "\n\n[truncated: showing first \(GrokACPClient.embeddedFilePrefixBytes) of \(originalByteCount) bytes; full file remains at \(path)]"
        }
    }

    enum EmbeddedFilePrefixError: Error, CustomStringConvertible, Equatable {
        case notUTF8(String)

        var description: String {
            switch self {
            case .notUTF8(let displayName):
                return "Grok ACP embedded context requires UTF-8 text: \(displayName)"
            }
        }
    }

    static func embeddedUTF8FilePrefix(
        path: String,
        displayName: String,
        maxPrefixBytes: Int = embeddedFilePrefixBytes
    ) throws -> EmbeddedFilePrefix {
        let url = URL(fileURLWithPath: path)
        let originalByteCount: Int
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attributes[.size] as? NSNumber {
            originalByteCount = size.intValue
        } else {
            originalByteCount = 0
        }
        let maxPrefixBytes = max(1, maxPrefixBytes)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: maxPrefixBytes) ?? Data()
        guard let text = Self.utf8StringAllowingPartialTail(prefix) else {
            throw EmbeddedFilePrefixError.notUTF8(displayName)
        }
        return EmbeddedFilePrefix(
            text: text,
            originalByteCount: max(originalByteCount, prefix.count),
            truncated: originalByteCount > maxPrefixBytes,
            path: path
        )
    }

    private static func utf8StringAllowingPartialTail(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        var trimmed = data
        for _ in 0..<3 {
            guard !trimmed.isEmpty else { break }
            trimmed.removeLast()
            if let text = String(data: trimmed, encoding: .utf8) { return text }
        }
        return nil
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

    @discardableResult
    private func write(
        _ object: JSONObject,
        admittedBy: (@Sendable () -> Bool)? = nil
    ) throws -> Bool {
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
        return try writeQueue.sync {
            guard admittedBy?() ?? true else { return false }
            try GuardedStdinWrite.write(
                toWrite, to: stdinPipe.fileHandleForWriting, process: process,
                notFound: { GrokACPError.processExited(reason: .exit, status: -1, stderrTail: "") }
            )
            return true
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
        let configOptions = (result["configOptions"] as? [JSONObject]) ?? []
        let currentModelId = state?["currentModelId"] as? String
        return GrokACPSessionOpenResult(
            sessionId: sessionId,
            models: models,
            currentModelId: currentModelId,
            currentReasoningEffortRaw: currentReasoningEffortRaw(
                from: state,
                currentModelId: currentModelId,
                configOptions: configOptions
            ),
            availableModes: availableModes,
            currentModeId: modeState?["currentModeId"] as? String,
            configOptions: configOptions
        )
    }

    static func modelDescriptors(from state: JSONObject?) -> [AgentModelDescriptor] {
        let rawModels = state?["availableModels"] as? [JSONObject] ?? []
        return rawModels.compactMap { raw -> AgentModelDescriptor? in
            guard let rawID = raw["modelId"] as? String else { return nil }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let metadata = raw["_meta"] as? JSONObject ?? [:]
            let effortEntries = (metadata["reasoningEfforts"] as? [JSONObject])
                ?? (metadata["supportedReasoningEfforts"] as? [JSONObject])
                ?? (raw["reasoningEfforts"] as? [JSONObject])
                ?? (raw["supportedReasoningEfforts"] as? [JSONObject])
                ?? []
            let supported: [AgentReasoningEffort]
            if effortEntries.isEmpty {
                supported = reasoningEfforts(
                    from: metadata["reasoningEfforts"]
                        ?? metadata["supportedReasoningEfforts"]
                        ?? raw["reasoningEfforts"]
                        ?? raw["supportedReasoningEfforts"]
                )
            } else {
                supported = parseReasoningEffortCatalog(
                    entries: effortEntries,
                    currentRaw: metadata["reasoningEffort"] as? String
                ).ordered
            }
            let speedTiers = (metadata["additionalSpeedTiers"] as? [String])
                ?? (metadata["additional_speed_tiers"] as? [String])
                ?? (raw["additionalSpeedTiers"] as? [String])
                ?? (raw["additional_speed_tiers"] as? [String])
                ?? []
            let contextWindow = integer(
                metadata["modelContextWindow"]
                    ?? metadata["contextWindowTokens"]
                    ?? metadata["contextWindow"]
                    ?? raw["modelContextWindow"]
                    ?? raw["contextWindowTokens"]
                    ?? raw["contextWindow"]
                    ?? raw["maxTokens"]
            )
            return AgentModelDescriptor(
                id: id,
                label: (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (raw["name"] as? String ?? id)
                    : id,
                provider: .grok,
                supportsReasoning: metadata["supportsReasoningEffort"] as? Bool
                    ?? raw["supportsReasoningEffort"] as? Bool
                    ?? !supported.isEmpty,
                supportedReasoningEfforts: supported,
                supportsServiceTier: metadata["supportsServiceTier"] as? Bool
                    ?? raw["supportsServiceTier"] as? Bool
                    ?? speedTiers.contains("fast"),
                supportsCustomModel: metadata["supportsCustomModel"] as? Bool
                    ?? raw["supportsCustomModel"] as? Bool
                    ?? true,
                contextWindowTokens: contextWindow
            )
        }
    }

    /// Stable effort order with preferred default first so `.first` consumers
    /// (schedulers, drafts) match the agent-advertised default rather than
    /// the raw ACP array order (live grok-4.6 lists `xhigh` first).
    static func parseReasoningEffortCatalog(
        entries: [JSONObject],
        currentRaw: String?
    ) -> (ordered: [AgentReasoningEffort], preferred: AgentReasoningEffort?) {
        var seen: [AgentReasoningEffort] = []
        var flaggedDefault: AgentReasoningEffort?
        for entry in entries {
            // Prefer `id` over `value` so glm aliases (id=medium,value=high)
            // keep distinct catalog identities.
            let raw = ((entry["id"] as? String)
                ?? (entry["reasoningEffort"] as? String)
                ?? (entry["value"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let effort = AgentReasoningEffort(rawValue: raw) else { continue }
            if !seen.contains(effort) { seen.append(effort) }
            if flaggedDefault == nil, (entry["default"] as? Bool) == true {
                flaggedDefault = effort
            }
        }
        let current = currentRaw.flatMap { AgentReasoningEffort(rawValue: $0) }
        let preferred = flaggedDefault
            ?? (current.flatMap { seen.contains($0) ? $0 : nil })
            ?? (seen.contains(.high) ? .high : seen.first)
        guard let preferred else { return ([], nil) }
        let rest = seen.filter { $0 != preferred }
        return ([preferred] + rest, preferred)
    }

    /// Live current effort from typed configOptions when it belongs to the
    /// current model's `_meta.reasoningEfforts`; otherwise that model's
    /// `_meta.reasoningEffort`. Session-global `currentValue` can be the
    /// process-default model's token (`max`/`none` on deepseek) while grok-4.6
    /// `_meta` is `high`.
    static func currentReasoningEffortRaw(
        from state: JSONObject?,
        currentModelId: String?,
        configOptions: [JSONObject] = []
    ) -> String? {
        let rawModels = state?["availableModels"] as? [JSONObject] ?? []
        let trimmed = currentModelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let match = rawModels.first { ($0["modelId"] as? String) == trimmed } ?? rawModels.first
        let metadata = match?["_meta"] as? JSONObject ?? [:]
        let modelRaw = (metadata["reasoningEffort"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelEffortIds: [String] = {
            let entries = (metadata["reasoningEfforts"] as? [JSONObject])
                ?? (metadata["supportedReasoningEfforts"] as? [JSONObject])
                ?? []
            if !entries.isEmpty {
                return entries.compactMap { entry in
                    let id = (entry["id"] as? String)
                        ?? (entry["value"] as? String)
                        ?? (entry["reasoningEffort"] as? String)
                    let trimmedId = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmedId.isEmpty ? nil : trimmedId
                }
            }
            if let strings = metadata["reasoningEfforts"] as? [String]
                ?? metadata["supportedReasoningEfforts"] as? [String] {
                return strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            return []
        }()
        if let option = configOptions.first(where: {
            (($0["id"] as? String) ?? ($0["configId"] as? String)) == "reasoning_effort"
        }) {
            let current = (option["currentValue"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !current.isEmpty,
               modelEffortIds.isEmpty || modelEffortIds.contains(current) {
                return current
            }
        }
        return modelRaw.isEmpty ? nil : modelRaw
    }

    /// Seed open-state effort from live current when advertised; else preferred default (`.first`).
    static func seededReasoningEffort(
        models: [AgentModelDescriptor],
        currentModelId: String?,
        currentEffortRaw: String? = nil
    ) -> AgentReasoningEffort? {
        let trimmed = currentModelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let match = models.first { $0.id == trimmed } ?? models.first
        let supported = match?.supportedReasoningEfforts ?? []
        if let raw = currentEffortRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let current = AgentReasoningEffort(rawValue: raw),
           supported.contains(current) {
            return current
        }
        return supported.first
    }

    private static func reasoningEfforts(from value: Any?) -> [AgentReasoningEffort] {
        if let strings = value as? [String] {
            return strings.compactMap(AgentReasoningEffort.init(rawValue:))
        }
        if let objects = value as? [JSONObject] {
            return objects.compactMap {
                ($0["id"] as? String
                    ?? $0["reasoningEffort"] as? String
                    ?? $0["value"] as? String)
                    .flatMap(AgentReasoningEffort.init(rawValue:))
            }
        }
        return []
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
