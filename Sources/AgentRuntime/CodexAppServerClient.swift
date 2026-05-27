import Foundation
import CoreModel

public enum CodexAppServerError: Error, CustomStringConvertible {
    case missingBinary(String)
    case spawnFailed(String)
    case invalidJSON(String)
    case rpcError(code: Int?, message: String)
    case processExited
    case responseTypeMismatch

    public var description: String {
        switch self {
        case .missingBinary(let binary): return "Codex app-server binary not found: \(binary)"
        case .spawnFailed(let message): return "Failed to spawn Codex app-server: \(message)"
        case .invalidJSON(let line): return "Codex app-server emitted invalid JSON: \(line)"
        case .rpcError(_, let message): return "Codex app-server RPC error: \(message)"
        case .processExited: return "Codex app-server process exited"
        case .responseTypeMismatch: return "Codex app-server response had an unexpected shape"
        }
    }
}

public struct CodexAppServerInitializeResult: Equatable, Sendable {
    public let userAgent: String
    public let codexHome: String?
    public let platformFamily: String?
    public let platformOs: String?
}

public struct CodexAppServerThreadOpenResult {
    public let providerThreadId: String
    public let response: CodexAppServerClient.JSONObject
}

public enum CodexAppServerModelDiscovery {
    public static func listModels(binary: String, cwd: String, environment: [String: String] = [:]) async -> [AgentModelDescriptor] {
        do {
            let client = try CodexAppServerClient(binary: binary, arguments: ["app-server"], cwd: cwd, environment: environment)
            _ = try await client.initialize()
            defer { client.stop() }
            return try await client.listModels()
        } catch {
            return []
        }
    }
}

public final class CodexAppServerClient: @unchecked Sendable {
    public typealias JSONObject = [String: Any]
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: Any?) -> Void
    public typealias ServerRequestHandler = @Sendable (_ method: String, _ params: Any?) async throws -> Any?

    private struct Pending {
        let resume: @Sendable (Result<Any?, Error>) -> Void
    }

    private enum ServerRequestID {
        case int(Int)
        case string(String)

        init?(_ value: Any?) {
            if let int = value as? Int {
                self = .int(int)
            } else if let string = value as? String, !string.isEmpty {
                self = .string(string)
            } else {
                return nil
            }
        }

        var jsonValue: Any {
            switch self {
            case .int(let value): return value
            case .string(let value): return value
            }
        }
    }

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let parseQueue = DispatchQueue(label: "remotecode.codex-app-server.parse")
    private let writeQueue = DispatchQueue(label: "remotecode.codex-app-server.write")
    private let lock = NSLock()
    private let lineBuffer = LineBuffer()
    private var nextId: Int = 1
    private var pending: [Int: Pending] = [:]
    private var notificationHandler: NotificationHandler?
    private var serverRequestHandler: ServerRequestHandler?
    private var stderrBuffer = Data()
    public var terminationHandler: (@Sendable (Error) -> Void)?

    public init(
        binary: String = "codex",
        arguments: [String] = ["app-server"],
        cwd: String,
        environment: [String: String] = [:],
        notificationHandler: NotificationHandler? = nil,
        serverRequestHandler: ServerRequestHandler? = nil
    ) throws {
        let resolvedBinary = binary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "codex" : binary
        guard let path = ProcessLocator.resolve(resolvedBinary) else {
            throw CodexAppServerError.missingBinary(resolvedBinary)
        }

        self.process = Process()
        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()
        self.notificationHandler = notificationHandler
        self.serverRequestHandler = serverRequestHandler

        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = CodexRunner.processEnvironment(overrides: environment)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.parseQueue.async {
                for line in self.lineBuffer.take(data) {
                    self.handleLine(line)
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.parseQueue.async {
                self.stderrBuffer.append(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.failPending(CodexAppServerError.processExited)
            self?.terminationHandler?(CodexAppServerError.processExited)
        }

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.spawnFailed(error.localizedDescription)
        }
    }

    deinit {
        stop()
    }

    public func initialize(
        clientName: String = "remotecode",
        clientTitle: String = "RemoteCode",
        clientVersion: String = "0.0.0"
    ) async throws -> CodexAppServerInitializeResult {
        let result: JSONObject = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": clientName,
                    "title": clientTitle,
                    "version": clientVersion
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "optOutNotificationMethods": NSNull()
                ]
            ]
        )
        try notify(method: "initialized")

        guard let userAgent = result["userAgent"] as? String else {
            throw CodexAppServerError.responseTypeMismatch
        }
        return CodexAppServerInitializeResult(
            userAgent: userAgent,
            codexHome: result["codexHome"] as? String,
            platformFamily: result["platformFamily"] as? String,
            platformOs: result["platformOs"] as? String
        )
    }

    public func requestJSONObject(method: String, params: Any? = nil) async throws -> JSONObject {
        try await request(method: method, params: params)
    }

    public func listModels() async throws -> [AgentModelDescriptor] {
        var cursor: String?
        var models: [AgentModelDescriptor] = []
        repeat {
            var params: JSONObject = [:]
            if let cursor, !cursor.isEmpty { params["cursor"] = cursor }
            let response = try await requestJSONObject(method: "model/list", params: params)
            models.append(contentsOf: Self.modelDescriptors(fromModelListResponse: response))
            cursor = response["nextCursor"] as? String
        } while cursor?.isEmpty == false
        return models
    }

    public func openThread(for request: AgentRunRequest) async throws -> CodexAppServerThreadOpenResult {
        let params = Self.threadStartParams(for: request)
        let response: JSONObject
        if let providerThreadId = request.providerThreadId, !providerThreadId.isEmpty {
            do {
                var resumeParams = params
                resumeParams["threadId"] = providerThreadId
                response = try await requestJSONObject(method: "thread/resume", params: resumeParams)
            } catch {
                guard Self.isRecoverableThreadResumeError(error) else { throw error }
                response = try await requestJSONObject(method: "thread/start", params: params)
            }
        } else {
            response = try await requestJSONObject(method: "thread/start", params: params)
        }
        return CodexAppServerThreadOpenResult(
            providerThreadId: try Self.threadId(from: response),
            response: response
        )
    }

    public func startTurn(providerThreadId: String, for request: AgentRunRequest) async throws -> JSONObject {
        try await requestJSONObject(
            method: "turn/start",
            params: Self.turnStartParams(providerThreadId: providerThreadId, for: request)
        )
    }

    public func interruptTurn(providerThreadId: String, turnId: String) async throws {
        _ = try await requestJSONObject(
            method: "turn/interrupt",
            params: [
                "threadId": providerThreadId,
                "turnId": turnId
            ]
        )
    }

    public func readThread(providerThreadId: String, includeTurns: Bool = true) async throws -> JSONObject {
        try await requestJSONObject(
            method: "thread/read",
            params: [
                "threadId": providerThreadId,
                "includeTurns": includeTurns
            ]
        )
    }

    public func rollbackThread(providerThreadId: String, numTurns: Int) async throws -> JSONObject {
        try await requestJSONObject(
            method: "thread/rollback",
            params: [
                "threadId": providerThreadId,
                "numTurns": numTurns
            ]
        )
    }

    public func updateThreadSettings(providerThreadId: String, permissionMode: AgentPermissionMode) async throws {
        _ = try await requestJSONObject(
            method: "thread/settings/update",
            params: [
                "threadId": providerThreadId,
                "approvalPolicy": Self.approvalPolicy(for: permissionMode),
                "sandboxPolicy": Self.sandboxPolicy(for: permissionMode)
            ]
        )
    }

    public func notify(method: String, params: Any? = nil) throws {
        var payload: JSONObject = ["method": method]
        if let params { payload["params"] = params }
        try write(payload)
    }

    public func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            ProcessTerminator.terminateTree(process)
        }
        failPending(CodexAppServerError.processExited)
    }

    private func request<T>(method: String, params: Any?) async throws -> T {
        let id = reserveId()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = Pending { result in
                switch result {
                case .success(let value):
                    if let typed = value as? T {
                        continuation.resume(returning: typed)
                    } else {
                        continuation.resume(throwing: CodexAppServerError.responseTypeMismatch)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            lock.unlock()

            var payload: JSONObject = ["id": id, "method": method]
            if let params { payload["params"] = params }
            do {
                try write(payload)
            } catch {
                completePending(id: id, result: .failure(error))
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
            failPending(CodexAppServerError.invalidJSON(line))
            return
        }

        if let id = object["id"] as? Int, object["method"] as? String == nil {
            if let error = object["error"] as? JSONObject {
                let code = error["code"] as? Int
                let message = error["message"] as? String ?? "Unknown Codex app-server error"
                completePending(id: id, result: .failure(CodexAppServerError.rpcError(code: code, message: message)))
            } else {
                completePending(id: id, result: .success(object["result"]))
            }
            return
        }

        guard let method = object["method"] as? String else { return }
        let params = object["params"]
        if let id = ServerRequestID(object["id"]) {
            Task { [weak self] in
                await self?.handleServerRequest(id: id, method: method, params: params)
            }
        } else {
            notificationHandler?(method, params)
        }
    }

    private func handleServerRequest(id: ServerRequestID, method: String, params: Any?) async {
        do {
            let result = try await serverRequestHandler?(method, params)
            try write(["id": id.jsonValue, "result": result ?? NSNull()])
        } catch {
            try? write([
                "id": id.jsonValue,
                "error": [
                    "code": -32603,
                    "message": String(describing: error)
                ]
            ])
        }
    }

    private func completePending(id: Int, result: Result<Any?, Error>) {
        lock.lock()
        let pendingRequest = pending.removeValue(forKey: id)
        lock.unlock()
        pendingRequest?.resume(result)
    }

    private func failPending(_ error: Error) {
        lock.lock()
        let requests = pending
        pending.removeAll()
        lock.unlock()
        for request in requests.values {
            request.resume(.failure(error))
        }
    }

    private func write(_ object: JSONObject) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = data
        line.append(0x0A)
        writeQueue.sync {
            stdinPipe.fileHandleForWriting.write(line)
        }
    }

    public static func threadStartParams(for request: AgentRunRequest) -> JSONObject {
        var params: JSONObject = [
            "cwd": request.cwd,
            "approvalPolicy": approvalPolicy(for: request.permissionMode),
            "sandbox": sandboxMode(for: request.permissionMode)
        ]
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty, model.lowercased() != "default" {
            params["model"] = model
        }
        if request.serviceTier == .fast {
            params["serviceTier"] = "fast"
        }
        return params
    }

    public static func turnStartParams(providerThreadId: String, for request: AgentRunRequest) -> JSONObject {
        var input: [JSONObject] = []
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            input.append(["type": "text", "text": prompt])
        }
        for attachment in request.attachments where attachment.kind == .image {
            input.append([
                "type": "image",
                "url": URL(fileURLWithPath: attachment.path).absoluteString
            ])
        }
        for attachment in request.attachments where attachment.kind == .file {
            input.append([
                "type": "mention",
                "name": attachment.displayName,
                "path": attachment.path
            ])
        }

        let model = normalizedModel(request.model)
        var params: JSONObject = [
            "threadId": providerThreadId,
            "input": input,
            "approvalPolicy": approvalPolicy(for: request.permissionMode),
            "sandboxPolicy": sandboxPolicy(for: request.permissionMode),
            "collaborationMode": collaborationMode(for: request, normalizedModel: model)
        ]
        if let model { params["model"] = model }
        if request.serviceTier == .fast { params["serviceTier"] = "fast" }
        params["effort"] = appServerReasoningEffort(for: request.reasoningEffort).rawValue
        return params
    }

    public static func isRecoverableThreadResumeError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        guard message.contains("thread") else { return false }
        return [
            "not found",
            "missing",
            "unknown",
            "no such",
            "does not exist"
        ].contains { message.contains($0) }
    }

    private static func threadId(from response: JSONObject) throws -> String {
        if let thread = response["thread"] as? JSONObject,
           let id = thread["id"] as? String,
           !id.isEmpty {
            return id
        }
        if let id = response["id"] as? String, !id.isEmpty {
            return id
        }
        throw CodexAppServerError.responseTypeMismatch
    }

    public static func modelDescriptors(fromModelListResponse response: JSONObject) -> [AgentModelDescriptor] {
        let rawModels = response["data"] as? [[String: Any]]
            ?? response["models"] as? [[String: Any]]
            ?? []
        return rawModels.compactMap { raw -> AgentModelDescriptor? in
            guard let id = string(raw, "model") ?? string(raw, "id") ?? string(raw, "slug"),
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let label = string(raw, "displayName") ?? string(raw, "name") ?? displayName(for: id)
            let efforts = reasoningEfforts(from: raw["supportedReasoningEfforts"])
            let defaultEffort = string(raw, "defaultReasoningEffort").flatMap(AgentReasoningEffort.init(rawValue:))
            let supportedEfforts = efforts.isEmpty ? defaultEffort.map { [$0] } ?? [] : efforts
            let speedTiers = raw["additionalSpeedTiers"] as? [String]
                ?? raw["additional_speed_tiers"] as? [String]
                ?? []
            let contextWindow = int(raw, "modelContextWindow")
                ?? int(raw, "contextWindow")
                ?? int(raw, "maxTokens")
            return AgentModelDescriptor(
                id: id,
                label: label,
                provider: .codex,
                supportsReasoning: !supportedEfforts.isEmpty,
                supportedReasoningEfforts: supportedEfforts,
                supportsServiceTier: speedTiers.contains("fast"),
                supportsCustomModel: true,
                contextWindowTokens: contextWindow
            )
        }
    }

    private static func reasoningEfforts(from value: Any?) -> [AgentReasoningEffort] {
        if let strings = value as? [String] {
            return strings.compactMap(AgentReasoningEffort.init(rawValue:))
        }
        if let objects = value as? [[String: Any]] {
            return objects.compactMap {
                (string($0, "reasoningEffort") ?? string($0, "id") ?? string($0, "value"))
                    .flatMap(AgentReasoningEffort.init(rawValue:))
            }
        }
        return []
    }

    private static func string(_ object: JSONObject, _ key: String) -> String? {
        object[key] as? String
    }

    private static func int(_ object: JSONObject, _ key: String) -> Int? {
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? Double { return Int(value) }
        if let value = object[key] as? String { return Int(value) }
        return nil
    }

    private static func displayName(for model: String) -> String {
        model
            .split(separator: "-")
            .map { part in
                part.lowercased() == "gpt" ? "GPT" : part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: "-")
    }

    private static func approvalPolicy(for mode: AgentPermissionMode) -> String {
        switch mode {
        case .supervised: return "untrusted"
        case .autoAcceptEdits: return "on-request"
        case .fullAccess: return "never"
        }
    }

    private static func normalizedModel(_ raw: String) -> String? {
        let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.lowercased() != "default" else { return nil }
        return model
    }

    private static func sandboxMode(for mode: AgentPermissionMode) -> String {
        switch mode {
        case .supervised: return "read-only"
        case .autoAcceptEdits: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }

    private static func sandboxPolicy(for mode: AgentPermissionMode) -> JSONObject {
        switch mode {
        case .supervised: return ["type": "readOnly"]
        case .autoAcceptEdits: return ["type": "workspaceWrite"]
        case .fullAccess: return ["type": "dangerFullAccess"]
        }
    }

    private static func collaborationMode(for request: AgentRunRequest, normalizedModel model: String?) -> JSONObject {
        [
            "mode": request.interactionMode.rawValue,
            "settings": [
                "model": model ?? "gpt-5.5",
                "reasoning_effort": appServerReasoningEffort(for: request.reasoningEffort).rawValue,
                "developer_instructions": developerInstructions(for: request.interactionMode)
            ]
        ]
    }

    private static func appServerReasoningEffort(for effort: AgentReasoningEffort?) -> AgentReasoningEffort {
        effort == .minimal ? .low : (effort ?? .medium)
    }

    private static func developerInstructions(for mode: AgentInteractionMode) -> String {
        switch mode {
        case .default:
            return "Implement clear user requests, keep changes scoped, preserve unrelated local work, verify before reporting completion, and ask before ambiguous or risky edits."
        case .plan:
            return "Analyze the request and produce a concrete plan only. Do not edit files, run destructive commands, or implement changes until the user explicitly approves the plan."
        }
    }
}
