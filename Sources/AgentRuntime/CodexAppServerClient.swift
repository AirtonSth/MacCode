import Foundation
import CoreModel

public enum CodexAppServerError: Error, CustomStringConvertible {
    case missingBinary(String)
    case spawnFailed(String)
    case invalidJSON(String)
    case rpcError(code: Int?, message: String)
    case processExited(stderrTail: String)
    case responseTypeMismatch
    case requestTimedOut(method: String, timeout: TimeInterval)
    case modelListPaginationCycle
    /// Resume (and optional start-fresh fallback) exhausted its bounded budget.
    case threadResumeUnavailable(attempts: Int, elapsedBound: TimeInterval)

    public var description: String {
        switch self {
        case .missingBinary(let binary): return "Codex app-server binary not found: \(binary)"
        case .spawnFailed(let message): return "Failed to spawn Codex app-server: \(message)"
        case .invalidJSON(let line): return "Codex app-server emitted invalid JSON: \(line)"
        case .rpcError(_, let message): return "Codex app-server RPC error: \(message)"
        case .processExited(let stderrTail):
            return stderrTail.isEmpty
                ? "Codex app-server process exited"
                : "Codex app-server process exited: \(stderrTail)"
        case .responseTypeMismatch: return "Codex app-server response had an unexpected shape"
        case .requestTimedOut(let method, let timeout):
            // Actionable: name the RPC, the elapsed bound, and what the user can do.
            // Intermediate timeouts may still be retried by the adapter; this string
            // is also what is stored when recovery cannot continue.
            return "Codex app-server RPC \(method) timed out after \(Self.formatTimeout(timeout)). The app-server did not answer in time (large threads can be slow, or Codex may be stuck). Retry the run; if it keeps failing, verify Codex is healthy or start a new thread."
        case .modelListPaginationCycle:
            return "Codex app-server model/list returned a repeated pagination cursor"
        case .threadResumeUnavailable(let attempts, let elapsedBound):
            return "Codex thread/resume did not succeed after \(attempts) attempt(s) within \(Self.formatTimeout(elapsedBound)). The app-server stayed unresponsive. Stop and retry, check that the `codex` binary is installed and responsive, or start a new Codex thread."
        }
    }

    private static func formatTimeout(_ timeout: TimeInterval) -> String {
        if timeout == timeout.rounded() && timeout >= 1 {
            return "\(Int(timeout))s"
        }
        return String(format: "%.1fs", timeout)
    }
}

/// Bounded retry policy for a slow/transient `thread/resume` on a desynchronized
/// peer. Each attempt uses a fresh app-server client because a timed-out JSON-RPC
/// stream must not be reused. Never retries forever.
public struct CodexThreadResumeRetryPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    /// Backoff before attempts 2...N (index 0 = delay before 2nd attempt).
    public let backoffNanoseconds: [UInt64]
    /// Per-attempt RPC deadline used only to compute the actionable elapsed bound
    /// in the final error (the live client still owns its own `requestTimeout`).
    public let perAttemptTimeoutHint: TimeInterval

    public static let production = CodexThreadResumeRetryPolicy(
        maxAttempts: 3,
        backoffNanoseconds: [500_000_000, 1_000_000_000],
        perAttemptTimeoutHint: 30
    )

    public init(
        maxAttempts: Int,
        backoffNanoseconds: [UInt64] = [],
        perAttemptTimeoutHint: TimeInterval = 30
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.backoffNanoseconds = backoffNanoseconds
        self.perAttemptTimeoutHint = max(0.001, perAttemptTimeoutHint)
    }

    public func backoffNanoseconds(beforeAttempt attempt: Int) -> UInt64 {
        // `attempt` is 1-based; backoff applies before attempt 2+.
        let index = attempt - 2
        guard index >= 0 else { return 0 }
        if index < backoffNanoseconds.count {
            return backoffNanoseconds[index]
        }
        return backoffNanoseconds.last ?? 0
    }

    public var elapsedBoundHint: TimeInterval {
        let backoffs = backoffNanoseconds.reduce(TimeInterval(0)) { partial, ns in
            partial + TimeInterval(ns) / 1_000_000_000
        }
        return (perAttemptTimeoutHint * TimeInterval(maxAttempts)) + backoffs
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
    /// True when `thread/resume` failed recoverably and the adapter fell back
    /// to `thread/start`. Callers should notify the user that prior context
    /// was not restored.
    public let resumeFellBackToStart: Bool

    public init(providerThreadId: String, response: CodexAppServerClient.JSONObject, resumeFellBackToStart: Bool = false) {
        self.providerThreadId = providerThreadId
        self.response = response
        self.resumeFellBackToStart = resumeFellBackToStart
    }
}

public struct CodexAppServerThreadSummary: Sendable, Equatable {
    public let id: String
    public let forkedFromId: String?
    public let threadSource: String?
    public let createdAt: Int64

    public init(id: String, forkedFromId: String?, threadSource: String?, createdAt: Int64) {
        self.id = id
        self.forkedFromId = forkedFromId
        self.threadSource = threadSource
        self.createdAt = createdAt
    }
}

public struct CodexAppServerThreadPage: Sendable, Equatable {
    public let threads: [CodexAppServerThreadSummary]
    public let nextCursor: String?

    public init(threads: [CodexAppServerThreadSummary], nextCursor: String?) {
        self.threads = threads
        self.nextCursor = nextCursor
    }
}

/// Reads the model catalog owned by the selected Codex harness account.
///
/// The app-server `model/list` response is authoritative for IDs it returns.
/// This cache only fills IDs the same account has marked visible and API
/// supported, which covers installed CLIs that lag the current harness catalog
/// without turning hidden, unavailable, or another account's models into
/// selectable options.
public enum CodexHarnessModelCatalog {
    public static func models(environment: [String: String]) -> [AgentModelDescriptor] {
        guard let url = cacheURL(environment: environment),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return []
        }
        return models(from: data)
    }

    public static func models(from data: Data) -> [AgentModelDescriptor] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = object["models"] as? [[String: Any]] else {
            return []
        }
        return rawModels.compactMap { raw -> AgentModelDescriptor? in
            guard let rawID = string(raw, "slug") ?? string(raw, "id") ?? string(raw, "model"),
                  let visibility = string(raw, "visibility"),
                  visibility.caseInsensitiveCompare("list") == .orderedSame,
                  (bool(raw, "supported_in_api") ?? bool(raw, "supportedInAPI")) == true else {
                return nil
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let efforts = reasoningEfforts(
                raw["supported_reasoning_levels"]
                    ?? raw["supportedReasoningLevels"]
            )
            let speedTiers = (raw["additional_speed_tiers"] as? [String])
                ?? (raw["additionalSpeedTiers"] as? [String])
                ?? []
            let serviceTiers = (raw["service_tiers"] as? [[String: Any]])
                ?? (raw["serviceTiers"] as? [[String: Any]])
                ?? []
            let label = (string(raw, "display_name") ?? string(raw, "displayName"))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentModelDescriptor(
                id: id,
                label: label?.isEmpty == false ? label! : displayName(for: id),
                provider: .codex,
                supportsReasoning: !efforts.isEmpty,
                supportedReasoningEfforts: efforts,
                supportsServiceTier: speedTiers.contains { $0.caseInsensitiveCompare("fast") == .orderedSame }
                    || !serviceTiers.isEmpty,
                supportsCustomModel: true,
                contextWindowTokens: integer(
                    raw["context_window"]
                        ?? raw["contextWindow"]
                        ?? raw["context_window_tokens"]
                        ?? raw["contextWindowTokens"]
                )
            )
        }
    }

    /// Deduplicates each source while giving live app-server metadata priority.
    public static func merge(
        live: [AgentModelDescriptor],
        harness: [AgentModelDescriptor]
    ) -> [AgentModelDescriptor] {
        var merged: [AgentModelDescriptor] = []
        var ids = Set<String>()
        for model in live + harness {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, ids.insert(id).inserted else { continue }
            merged.append(model)
        }
        return merged
    }

    /// Resolves only the selected account's Codex home. No sibling/default
    /// account directories are searched when an account-scoped home is given.
    public static func cacheURL(environment: [String: String]) -> URL? {
        let configuredHome = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let home = environment["HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = configuredHome.flatMap { $0.isEmpty ? nil : $0 }
            ?? home.flatMap { $0.isEmpty ? nil : "\($0)/.codex" }
            ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.codex"
        guard root.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("models_cache.json", isDirectory: false)
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    private static func bool(_ object: [String: Any], _ key: String) -> Bool? {
        object[key] as? Bool
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func reasoningEfforts(_ value: Any?) -> [AgentReasoningEffort] {
        let values: [String] = {
            if let objects = value as? [[String: Any]] {
                return objects.compactMap {
                    $0["effort"] as? String
                        ?? $0["reasoningEffort"] as? String
                        ?? $0["value"] as? String
                }
            }
            return value as? [String] ?? []
        }()
        var efforts: [AgentReasoningEffort] = []
        for value in values {
            // Preserve every representable Codex catalog effort, including
            // `ultra` (codex-cli 0.154+). Do not invent a different effort with
            // a misleading meaning for this picker.
            guard let effort = AgentReasoningEffort(rawValue: value),
                  !efforts.contains(effort) else { continue }
            efforts.append(effort)
        }
        return efforts
    }

    private static func displayName(for id: String) -> String {
        id.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

public enum CodexAppServerModelDiscovery {
    static func environmentForDiscovery(
        environment: [String: String],
        runAsUser: AgentRunAsUser?,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var discoveryEnvironment = CodexRunner.processEnvironment(
            overrides: environment,
            purpose: .supportProcess,
            base: baseEnvironment
        )
        let explicitCodexHome = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let passedHome = environment["HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parentHome = baseEnvironment["HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let foreignRunAsUser = runAsUser.map { $0.uid != getuid() } ?? false
        let accountHome: String? = {
            if foreignRunAsUser { return runAsUser?.homePath }
            return passedHome
        }()
        let homeChangedForAccount = foreignRunAsUser
            || (passedHome != nil && passedHome != parentHome)
        if foreignRunAsUser, let runAsUser {
            discoveryEnvironment["HOME"] = runAsUser.homePath
        }
        if homeChangedForAccount,
           !explicitCodexHome,
           let accountHome,
           !accountHome.isEmpty {
            discoveryEnvironment["CODEX_HOME"] = "\(accountHome)/.codex"
        }
        return discoveryEnvironment
    }

    public static func listModels(
        binary: String,
        cwd: String,
        environment: [String: String] = [:],
        runAsUser: AgentRunAsUser? = nil
    ) async -> [AgentModelDescriptor] {
        await listModelsResult(
            binary: binary,
            cwd: cwd,
            environment: environment,
            runAsUser: runAsUser
        ).models
    }

    public static func listModelsResult(
        binary: String,
        cwd: String,
        environment: [String: String] = [:],
        runAsUser: AgentRunAsUser? = nil
    ) async -> ModelListResult {
        let discoveryEnvironment = environmentForDiscovery(
            environment: environment,
            runAsUser: runAsUser
        )
        let harnessModels = CodexHarnessModelCatalog.models(environment: discoveryEnvironment)
        do {
            let client = try CodexAppServerClient(
                binary: binary,
                arguments: ["app-server"],
                cwd: cwd,
                environment: discoveryEnvironment,
                runAsUser: runAsUser,
                forkProtocolSupportOverride: .unsupported
            )
            defer { client.stop() }
            _ = try await client.initialize()
            let liveModels = try await client.listModels()
            let merged = CodexHarnessModelCatalog.merge(live: liveModels, harness: harnessModels)
            if !merged.isEmpty {
                return ModelListResult(models: merged, isFallback: false)
            }
        } catch {
            // A same-account harness cache remains selectable when the live
            // app-server cannot advertise the catalog, but it is not live data.
            if !harnessModels.isEmpty {
                return ModelListResult(models: harnessModels, isFallback: true)
            }
        }
        return ModelListResult(models: [], isFallback: true)
    }
}

public final class CodexAppServerClient: @unchecked Sendable {
    public typealias JSONObject = [String: Any]
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: Any?) -> Void
    /// `requestId` is the JSON-RPC request id as a stable string (`"42"` for int 42).
    /// Pending approvals must key on this value so `serverRequest/resolved` can settle them.
    public typealias ServerRequestHandler = @Sendable (_ requestId: String, _ method: String, _ params: Any?) async throws -> Any?

    private struct Pending {
        let resume: @Sendable (Result<Any?, Error>) -> Void
    }

    private enum ServerRequestID {
        case int(Int)
        case string(String)

        init?(_ value: Any?) {
            if let int = value as? Int {
                self = .int(int)
            } else if let int64 = value as? Int64 {
                self = .int(Int(int64))
            } else if let number = value as? NSNumber {
                let objCType = String(cString: number.objCType)
                if objCType == "c" || objCType == "B" { return nil }
                self = .int(number.intValue)
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

        /// Stable string form used as the Agent App pending-request key.
        var wireString: String {
            switch self {
            case .int(let value): return String(value)
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
    private let requestTimeout: TimeInterval
    private let tokenSaverCensusAllowed: Bool
    private let foreignUserUID: uid_t?
    public let forkProtocolSupport: CodexForkProtocolSupport
    // Only the stderr tail is ever surfaced (termination diagnostics), so cap
    // the buffer instead of growing it for the app-server's whole lifetime.
    private static let stderrTailByteLimit = 8_192
    public var terminationHandler: (@Sendable (Error) -> Void)?

    public init(
        binary: String = "codex",
        arguments: [String] = ["app-server"],
        cwd: String,
        environment: [String: String] = [:],
        runAsUser: AgentRunAsUser? = nil,
        askpassPath: String? = nil,
        notificationHandler: NotificationHandler? = nil,
        serverRequestHandler: ServerRequestHandler? = nil,
        requestTimeout: TimeInterval = 30,
        tokenSaverCensusAllowed: Bool = false,
        forkProtocolSupportOverride: CodexForkProtocolSupport? = nil
    ) throws {
        let resolvedBinary = binary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "codex" : binary
        guard let path = ProcessLocator.resolve(resolvedBinary) else {
            throw CodexAppServerError.missingBinary(resolvedBinary)
        }

        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()
        self.notificationHandler = notificationHandler
        self.serverRequestHandler = serverRequestHandler
        self.requestTimeout = max(0.001, requestTimeout)
        self.tokenSaverCensusAllowed = tokenSaverCensusAllowed
        self.foreignUserUID = runAsUser.flatMap { $0.uid == getuid() ? nil : $0.uid }
        if let forkProtocolSupportOverride {
            self.forkProtocolSupport = forkProtocolSupportOverride
        } else if arguments.first == "app-server" {
            self.forkProtocolSupport = CodexForkProtocolSupport.probe(
                binary: path,
                environment: environment
            )
        } else {
            // Test peers and nonstandard command surfaces do not prove the
            // production schema contract merely by implementing thread/fork.
            self.forkProtocolSupport = .unsupported
        }

        do {
            self.process = try ProviderSubprocessLauncher.makeProcess(
                provider: .codex,
                executablePath: path,
                arguments: arguments,
                currentDirectory: cwd,
                environment: environment,
                runAsUser: runAsUser,
                askpassPath: askpassPath
            )
        } catch {
            throw CodexAppServerError.spawnFailed(error.localizedDescription)
        }
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
                if self.stderrBuffer.count > Self.stderrTailByteLimit {
                    self.stderrBuffer.removeFirst(self.stderrBuffer.count - Self.stderrTailByteLimit)
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let error = CodexAppServerError.processExited(stderrTail: self.drainedStderrTail())
            self.failPending(error)
            self.terminationHandler?(error)
        }

        do {
            try process.run()
            try ProcessSpawnTagger.tagProcess(
                process,
                provider: .codex,
                foreignUserLaunch: foreignUserUID != nil
            )
        } catch {
            throw CodexAppServerError.spawnFailed(error.localizedDescription)
        }
    }

    deinit {
        stop()
    }

    /// Codex 0.146 InitializeCapabilities: always send both required booleans.
    /// `requestAttestation` stays false — RemoteCode does not implement attestation/generate.
    public static func initializeCapabilities() -> JSONObject {
        [
            "experimentalApi": true,
            "requestAttestation": false,
            "optOutNotificationMethods": NSNull()
        ]
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
                "capabilities": Self.initializeCapabilities()
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
        var seenCursors = Set<String>()
        var models: [AgentModelDescriptor] = []
        while true {
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw CodexAppServerError.modelListPaginationCycle
            }
            var params: JSONObject = [:]
            if let cursor, !cursor.isEmpty { params["cursor"] = cursor }
            let response = try await requestJSONObject(method: "model/list", params: params)
            models.append(contentsOf: Self.modelDescriptors(fromModelListResponse: response))
            cursor = response["nextCursor"] as? String ?? response["next_cursor"] as? String
            guard cursor?.isEmpty == false else { break }
        }
        return models
    }

    public func openThread(for request: AgentRunRequest) async throws -> CodexAppServerThreadOpenResult {
        let params = Self.threadStartParams(for: request)
        let response: JSONObject
        var resumeFellBack = false
        if let providerThreadId = request.providerThreadId, !providerThreadId.isEmpty {
            do {
                var resumeParams: JSONObject = ["threadId": providerThreadId]
                let instructions = Self.developerInstructions(
                    for: request.interactionMode,
                    environment: request.environment
                )
                if !instructions.isEmpty {
                    resumeParams["developerInstructions"] = instructions
                }
                response = try await requestJSONObject(method: "thread/resume", params: resumeParams)
            } catch {
                guard Self.isRecoverableThreadResumeError(error) else { throw error }
                resumeFellBack = true
                response = try await requestJSONObject(method: "thread/start", params: params)
            }
        } else {
            response = try await requestJSONObject(method: "thread/start", params: params)
        }
        return CodexAppServerThreadOpenResult(
            providerThreadId: try Self.threadId(from: response),
            response: response,
            resumeFellBackToStart: resumeFellBack
        )
    }

    public func startTurn(providerThreadId: String, for request: AgentRunRequest) async throws -> JSONObject {
        try await self.request(
            method: "turn/start",
            params: Self.turnStartParams(providerThreadId: providerThreadId, for: request),
            acceptancePermit: request.acceptancePermit
        )
    }

    public func steerTurn(providerThreadId: String, expectedTurnId: String, for request: AgentRunRequest) async throws -> JSONObject {
        try await self.request(
            method: "turn/steer",
            params: Self.turnSteerParams(
                providerThreadId: providerThreadId,
                expectedTurnId: expectedTurnId,
                for: request
            ),
            acceptancePermit: request.acceptancePermit
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
        var response = try await requestJSONObject(
            method: "thread/read",
            params: [
                "threadId": providerThreadId,
                "includeTurns": false
            ]
        )
        guard includeTurns else { return response }
        guard var thread = response["thread"] as? JSONObject else {
            throw CodexAppServerError.responseTypeMismatch
        }
        // Paginated Codex threads reject thread/read(includeTurns: true).
        // Keep the adapter's chronological turn shape using the supported pages.
        var turns: [JSONObject] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            try Task.checkCancellation()
            var params: JSONObject = [
                "threadId": providerThreadId, "limit": 50,
                "sortDirection": "asc", "itemsView": "full"
            ]
            if let cursor { params["cursor"] = cursor }
            let page = try await requestJSONObject(method: "thread/turns/list", params: params)
            guard let data = page["data"] as? [JSONObject] else {
                throw CodexAppServerError.responseTypeMismatch
            }
            turns.append(contentsOf: data)
            cursor = page["nextCursor"] as? String
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw CodexAppServerError.rpcError(code: nil, message: "thread/turns/list returned a repeated pagination cursor")
            }
        } while cursor != nil
        thread["turns"] = turns
        response["thread"] = thread
        return response
    }

    public func forkThread(providerThreadId: String, lastTurnId: String? = nil) async throws -> String {
        var params: JSONObject = ["threadId": providerThreadId]
        if let lastTurnId, !lastTurnId.isEmpty {
            params["lastTurnId"] = lastTurnId
        }
        let response = try await requestJSONObject(method: "thread/fork", params: params)
        return try Self.threadId(from: response)
    }

    public func forkThread(
        providerThreadId: String,
        lastTurnId: String? = nil,
        threadSource: String
    ) async throws -> CodexAppServerThreadSummary {
        var params: JSONObject = [
            "threadId": providerThreadId,
            "threadSource": threadSource
        ]
        if let lastTurnId, !lastTurnId.isEmpty {
            params["lastTurnId"] = lastTurnId
        }
        let response = try await requestJSONObject(method: "thread/fork", params: params)
        guard let thread = response["thread"] as? JSONObject else {
            throw CodexAppServerError.responseTypeMismatch
        }
        return try Self.threadSummary(from: thread)
    }

    public func listThreads(cursor: String? = nil, archived: Bool = false) async throws -> CodexAppServerThreadPage {
        var params: JSONObject = [
            "limit": 100,
            "sortKey": "created_at",
            "sortDirection": "asc",
            "archived": archived
        ]
        if let cursor, !cursor.isEmpty {
            params["cursor"] = cursor
        }
        let response = try await requestJSONObject(method: "thread/list", params: params)
        guard let data = response["data"] as? [JSONObject] else {
            throw CodexAppServerError.responseTypeMismatch
        }
        return CodexAppServerThreadPage(
            threads: try data.map(Self.threadSummary(from:)),
            nextCursor: response["nextCursor"] as? String
        )
    }

    public func deleteThread(providerThreadId: String) async throws {
        _ = try await requestJSONObject(
            method: "thread/delete",
            params: ["threadId": providerThreadId]
        )
    }

    public func rollbackThread(providerThreadId: String, beforeTurnId: String) async throws -> JSONObject {
        try await requestJSONObject(
            method: "thread/revert",
            params: [
                "threadId": providerThreadId,
                "beforeTurnId": beforeTurnId
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
            ProcessTerminator.terminateTree(
                process,
                foreignUserUID: foreignUserUID
            )
        }
        failPending(CodexAppServerError.processExited(stderrTail: ""))
    }

    public func stopImmediatelyForAppTermination() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            ProcessTerminator.terminateTreeImmediately(
                process,
                foreignUserUID: foreignUserUID
            )
        }
        failPending(CodexAppServerError.processExited(stderrTail: ""))
    }

    private static func threadSummary(from object: JSONObject) throws -> CodexAppServerThreadSummary {
        guard let id = object["id"] as? String,
              !id.isEmpty,
              let createdAt = integer(object["createdAt"]) else {
            throw CodexAppServerError.responseTypeMismatch
        }
        if let forkedFromId = object["forkedFromId"], !(forkedFromId is NSNull), !(forkedFromId is String) {
            throw CodexAppServerError.responseTypeMismatch
        }
        if let threadSource = object["threadSource"], !(threadSource is NSNull), !(threadSource is String) {
            throw CodexAppServerError.responseTypeMismatch
        }
        return CodexAppServerThreadSummary(
            id: id,
            forkedFromId: object["forkedFromId"] as? String,
            threadSource: object["threadSource"] as? String,
            createdAt: createdAt
        )
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c" else {
            return nil
        }
        return number.int64Value
    }

    /// Surfaces WHY the app-server died: drains any stderr bytes the async
    /// readability handler has not consumed yet, then snapshots the buffered
    /// tail so the termination error carries the crash/exit reason instead of
    /// a bare "process exited". Only called after the process terminated, so
    /// the drain cannot block on a live writer.
    private func drainedStderrTail() -> String {
        let handle = stderrPipe.fileHandleForReading
        handle.readabilityHandler = nil
        let remaining = BoundedPipeDrain.readRemaining(
            from: handle,
            maxBytes: BoundedPipeDrain.defaultStderrMaxBytes
        )
        return parseQueue.sync {
            if !remaining.isEmpty {
                stderrBuffer.append(remaining)
            }
            let tail = stderrBuffer.suffix(Self.stderrTailByteLimit)
            return String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func request<T>(
        method: String,
        params: Any?,
        acceptancePermit: AgentRunAcceptancePermit? = nil
    ) async throws -> T {
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
                if let acceptancePermit {
                    try acceptancePermit.withAcceptance { try write(payload) }
                } else {
                    try write(payload)
                }
            } catch {
                completePending(id: id, result: .failure(error))
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
                guard let self else { return }
                let error = CodexAppServerError.requestTimedOut(method: method, timeout: self.requestTimeout)
                // Fail only this request. A late response for this now-unreserved id
                // is harmless; a wall-clock deadline alone is not a reason to stop
                // a peer that may still serve later RPCs.
                _ = self.completePending(id: id, result: .failure(error))
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
            // A stray non-JSON stdout line (update notice, banner, log) must not
            // fail every pending RPC — the server is healthy and will still
            // answer them. Skip the noise; failPending is reserved for process
            // exit and explicit stop.
            NSLog("[codex app-server] ignoring non-JSON stdout line: %@", String(line.prefix(200)))
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
            let result = try await serverRequestHandler?(id.wireString, method, params)
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

    @discardableResult
    private func completePending(id: Int, result: Result<Any?, Error>) -> Bool {
        lock.lock()
        let pendingRequest = pending.removeValue(forKey: id)
        lock.unlock()
        pendingRequest?.resume(result)
        return pendingRequest != nil
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
        let toWrite: Data
        if tokenSaverCensusAllowed, object["method"] as? String == "turn/start" {
            let binding = TokenSaverCensusSeam.defaultBinding(
                trigger: "provider_outbound_user",
                provider: "codex",
                providerAdapterVersion: "app-server",
                toolShape: "turn_start_json_line"
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
            try GuardedStdinWrite.write(toWrite,
                                        to: stdinPipe.fileHandleForWriting,
                                        process: process,
                                        notFound: { CodexAppServerError.processExited(stderrTail: "") })
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
        // Codex 0.156+ accepts developerInstructions on thread/start.
        // Per-turn instructions also belong on collaborationMode for reused threads.
        let instructions = developerInstructions(
            for: request.interactionMode,
            environment: request.environment
        )
        if !instructions.isEmpty {
            params["developerInstructions"] = instructions
        }
        return params
    }

    public static func turnStartParams(providerThreadId: String, for request: AgentRunRequest) -> JSONObject {
        var input: [JSONObject] = []
        if let seed = request.preparedContextSeed?.encoded.trimmingCharacters(in: .whitespacesAndNewlines),
           !seed.isEmpty {
            input.append(["type": "text", "text": seed, "text_elements": [Any]()])
        }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            // Codex 0.146 UserInput text requires text_elements (empty when unused).
            input.append(["type": "text", "text": prompt, "text_elements": [Any]()])
        }
        for attachment in request.attachments where attachment.kind == .image {
            input.append([
                "type": "localImage",
                "path": attachment.path
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
        // Provider-neutral "Token Saver is admitted for this run" signal (same gate the
        // Claude PostToolUse hook and the Grok/Codex distill prompt hint use) — applies
        // uniformly whether this is a primary run, a same-provider subagent, or a
        // cross-provider nested run, per AGENTS.md.
        let tokenSaverActive = request.environment["RC_TOKEN_SAVER_DISTILL_HINT"] == "1"
        // Live 0.157 TurnStartParams still lists approvalPolicy; Distill/plan
        // text belongs on thread/start developerInstructions, not collaborationMode.
        var params: JSONObject = [
            "threadId": providerThreadId,
            "input": input,
            "approvalPolicy": approvalPolicy(for: request.permissionMode),
            "sandboxPolicy": sandboxPolicy(for: request.permissionMode, tokenSaverActive: tokenSaverActive)
        ]
        if let model { params["model"] = model }
        if request.serviceTier == .fast { params["serviceTier"] = "fast" }
        params["effort"] = appServerReasoningEffort(for: request.reasoningEffort).rawValue
        return params
    }

    public static func turnSteerParams(
        providerThreadId: String,
        expectedTurnId: String,
        for request: AgentRunRequest
    ) -> JSONObject {
        let start = turnStartParams(providerThreadId: providerThreadId, for: request)
        return [
            "threadId": providerThreadId,
            "expectedTurnId": expectedTurnId,
            "input": start["input"] ?? []
        ]
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

    /// A timed-out `thread/resume` leaves that thread-open attempt uncertain.
    /// The adapter recovers it with a new client and a bounded retry, then falls
    /// back to `thread/start` only after those retries are exhausted. This
    /// higher-level recovery does not stop the still-live request peer.
    public static func requiresFreshClientAfterThreadResumeFailure(_ error: Error) -> Bool {
        guard let appServerError = error as? CodexAppServerError,
              case .requestTimedOut(let method, _) = appServerError else {
            return false
        }
        return method == "thread/resume"
    }

    /// Process death / spawn failure is not a "slow resume" signal — fail fast
    /// with the existing typed error rather than spending the multi-attempt
    /// resume budget waiting on a dead peer.
    public static func isDeadAppServerFailure(_ error: Error) -> Bool {
        guard let appServerError = error as? CodexAppServerError else { return false }
        switch appServerError {
        case .processExited, .spawnFailed, .missingBinary:
            return true
        default:
            return false
        }
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

    /// Complete Codex 0.146 SandboxPolicy objects for turn/start and
    /// thread/settings/update. Token Saver only flips `networkAccess` so the
    /// local ledger POST is not blocked; filesystem restrictions of the mode
    /// are unchanged. Full Access stays `{type: dangerFullAccess}` only.
    /// Applies uniformly to every Codex run (primary, subagent, or nested) —
    /// see AGENTS.md Token Saver rules. When Token Saver is off,
    /// `networkAccess` is explicitly `false` (fail-open: no network lift).
    private static func sandboxPolicy(for mode: AgentPermissionMode, tokenSaverActive: Bool = false) -> JSONObject {
        switch mode {
        case .supervised:
            return [
                "type": "readOnly",
                "networkAccess": tokenSaverActive
            ]
        case .autoAcceptEdits:
            return [
                "type": "workspaceWrite",
                "writableRoots": [String](),
                "networkAccess": tokenSaverActive,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false
            ]
        case .fullAccess:
            return ["type": "dangerFullAccess"]
        }
    }

    private static func appServerReasoningEffort(for effort: AgentReasoningEffort?) -> AgentReasoningEffort {
        effort == .minimal ? .low : (effort ?? .medium)
    }

    /// Codex per-turn `developer_instructions`: base mode + Distill (Token Saver) +
    /// Graphify query-first rules when the host set `RC_GRAPHIFY_ENABLED=1` +
    /// background-await self-declare marker (so shell-detached orchestration
    /// stalls reach the host's [[RC_AWAITING]] recovery path).
    private static func developerInstructions(
        for mode: AgentInteractionMode,
        environment: [String: String]
    ) -> String {
        let base = AgentProviderInstructionText.developerInstructions(for: mode)
        // tokenSaverProviderPrompt also chains graphifyProviderPrompt.
        let withTokenSaver = AgentSkillInstaller.tokenSaverProviderPrompt(base, environment: environment)
        // Additive only: systemPromptDirective (NOT alwaysOnClaudeDirectives —
        // those carry Claude-CLI-only MCP rules).
        let alwaysOn = BotPeerDelegation.appendingTurnContext(
            to: BackgroundAwaitContinuation.systemPromptDirective
                + "\n\n" + BotPeerDelegation.providerDirective,
            environment: environment
        )
        if withTokenSaver.isEmpty { return alwaysOn }
        return withTokenSaver + "\n\n" + alwaysOn
    }
}
