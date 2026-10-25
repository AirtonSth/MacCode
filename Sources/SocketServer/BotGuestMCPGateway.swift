import CryptoKit
import Foundation
import Security
import CoreModel
import Persistence

/// The host MCP servers a bot agent running inside its Linux guest reaches over
/// `http://host.docker.internal:<port>/mcp/<server>` (see `DistillGuestConfig`).
///
/// The guest can reach every Mac loopback listener, so this one admits only a
/// per-run bearer and only an allowlist: self-config without the `rc_*` host
/// tools, the computer tools that need the Mac (manual action, chat screenshot,
/// Mac execution request; the agent has its own shell and desktop tools in the
/// guest, and `rebuild` would recreate the container it runs in), and web.
///
/// Requests run the same line-based handlers the Mac stdio bot MCPs run, with
/// the environment that stdio child would inherit, on dedicated threads: those
/// handlers block on sockets, files and the network. The listener binds
/// 127.0.0.1 on the first `issue`.
public final class BotGuestMCPGateway: @unchecked Sendable {
    public struct ContextBinding: Equatable, Sendable {
        public var pin: BotConversationContextPin
        public var threadID: AgentThreadID

        public init(pin: BotConversationContextPin, threadID: AgentThreadID) {
            self.pin = pin
            self.threadID = threadID
        }
    }

    public struct Binding: Sendable, Equatable {
        public var runID: String
        public var context: ContextBinding?
        /// What the handlers read: bot, thread and run identity, delegation
        /// capability, app socket and App Support. Never sent to the guest.
        public var hostEnvironment: [String: String]

        public init(runID: String, hostEnvironment: [String: String], context: ContextBinding? = nil) {
            self.runID = runID
            self.context = context
            self.hostEnvironment = hostEnvironment
        }

        /// Keys a Mac stdio bot MCP child would inherit from the run.
        public static let hostEnvironmentKeys: [String] = [
            BotSelfConfigCatalog.callerEnvironmentKey,
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY",
            BotPeerDelegation.threadEnvironmentKey,
            BotPeerDelegation.runEnvironmentKey,
            BotPeerDelegation.socketEnvironmentKey,
            BotPeerDelegation.capabilityEnvironmentKey,
            BotPeerDelegation.turnContextEnvironmentKey,
        ]

        public static func hostEnvironment(fromRunEnvironment environment: [String: String]) -> [String: String] {
            environment.filter { hostEnvironmentKeys.contains($0.key) && !$0.value.isEmpty }
        }
    }

    public struct Issued: Sendable, Equatable {
        public var token: String
        public var port: UInt16
    }

    public struct Route: Sendable {
        public var name: String
        public var allowedTools: Set<String>
        /// The stdio servers' `initialize` instructions name tools a filtered
        /// route does not offer; such routes drop them.
        public var keepsServerInstructions: Bool
        public var handle: @Sendable (_ environment: [String: String], _ line: String) -> String?

        public init(
            name: String,
            allowedTools: Set<String>,
            keepsServerInstructions: Bool,
            handle: @escaping @Sendable (_ environment: [String: String], _ line: String) -> String?
        ) {
            self.name = name
            self.allowedTools = allowedTools
            self.keepsServerInstructions = keepsServerInstructions
            self.handle = handle
        }
    }

    public static let defaultRoutes: [Route] = [
        Route(name: ConnectionMCPCatalog.serverName,
              allowedTools: Set([ConnectionMCPCatalog.list, ConnectionMCPCatalog.tools, ConnectionMCPCatalog.call]),
              keepsServerInstructions: true) { environment, line in
            ManagedConnectionsMCP(environment: environment).handle(line)
        },
        Route(
            name: BotSelfConfigCatalog.serverName,
            // A saved secret becomes an environment variable of this bot's Mac
            // runs too (BASH_ENV, NODE_OPTIONS, DYLD_*...), so writing one from
            // the guest would reach the Mac without a Mac-execution approval.
            allowedTools: Set(BotSelfConfigCatalog.toolNames).subtracting([
                BotSelfConfigCatalog.saveSecret,
                BotSelfConfigCatalog.deleteSecret,
            ]),
            keepsServerInstructions: false
        ) { environment, line in
            ManagedBotSelfConfigMCP(environment: environment).handle(line)
        },
        Route(
            name: BotComputerCatalog.serverName,
            allowedTools: [
                BotComputerCatalog.requestUserAction,
                BotComputerCatalog.postScreenshot,
                BotComputerCatalog.requestMacExecution,
            ],
            keepsServerInstructions: false
        ) { environment, line in
            ManagedBotComputerMCP(environment: environment).handleSynchronously(line)
        },
        Route(
            name: BotWebCatalog.serverName,
            allowedTools: Set(BotWebCatalog.toolNames),
            keepsServerInstructions: true
        ) { environment, line in
            ManagedBotWebMCP(environment: environment).handleSynchronously(line)
        },
    ]

    /// Parallel tool calls of one run; more get a JSON-RPC error, not a queue.
    public static let defaultMaxConcurrentCallsPerRun = 8
    static let handlerThreadPrefix = "rc2.guest-gateway."

    private final class LiveBinding: @unchecked Sendable {
        let binding: Binding
        let digest: [UInt8]
        // Guarded by the gateway lock.
        var revoked = false
        var inFlight = 0
        var waiters: [ObjectIdentifier: DispatchSemaphore] = [:]

        init(binding: Binding, digest: [UInt8]) {
            self.binding = binding
            self.digest = digest
        }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String??
        func set(_ reply: String?) { lock.lock(); value = .some(reply); lock.unlock() }
        func get() -> String?? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let routes: [String: Route]
    private let maxConcurrentCallsPerRun: Int
    private let context: ContextBinding?
    private let contextStore: BotStore?
    private let secretStore: any BotSecretStore
    private let lock = NSLock()
    private var bindings: [LiveBinding] = []
    private var listener: LoopbackHTTPListener!

    public init(
        routes: [Route] = BotGuestMCPGateway.defaultRoutes,
        maxConcurrentCallsPerRun: Int = BotGuestMCPGateway.defaultMaxConcurrentCallsPerRun,
        context: ContextBinding? = nil,
        contextStore: BotStore? = nil,
        secretStore: any BotSecretStore = BotKeychainSecretStore()
    ) {
        self.context = context
        self.contextStore = contextStore
        self.secretStore = secretStore
        self.routes = context == nil
            ? Dictionary(uniqueKeysWithValues: routes.map { ($0.name, $0) })
            : [:]
        self.maxConcurrentCallsPerRun = maxConcurrentCallsPerRun
        self.listener = LoopbackHTTPListener(name: "rc2.guest-gateway") { [weak self] request, isClientGone in
            self?.respond(to: request, isClientGone: isClientGone) ?? LoopbackHTTPResponse(status: 503)
        }
    }

    /// Starts the listener if needed and returns a new 256-bit bearer for one
    /// run. Only its SHA-256 is kept.
    public func issue(_ binding: Binding) throws -> Issued {
        guard binding.context == context,
              (context == nil || (contextStore != nil && UUID(uuidString: binding.runID) != nil)),
              bindingIsAuthorized(binding) else { throw BotStoreError.notFound }
        let port = try listener.start()
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw POSIXError(.EIO)
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let live = LiveBinding(binding: binding, digest: Self.digest(token))
        lock.lock()
        bindings.append(live)
        lock.unlock()
        return Issued(token: token, port: port)
    }

    /// Ends every bearer of `runID`. Calls still running for it are answered
    /// at once with an error and their late results are dropped.
    public func revoke(runID: String) {
        lock.lock()
        let ended = bindings.filter { $0.binding.runID == runID }
        bindings.removeAll { $0.binding.runID == runID }
        let waiters = ended.flatMap { live -> [DispatchSemaphore] in
            live.revoked = true
            return Array(live.waiters.values)
        }
        lock.unlock()
        waiters.forEach { $0.signal() }
    }

    /// App termination: revoke everything and close the listener.
    public func stop() {
        lock.lock()
        let runIDs = Set(bindings.map(\.binding.runID))
        lock.unlock()
        runIDs.forEach { revoke(runID: $0) }
        listener.stop()
    }

    public var port: UInt16? { listener.port }

#if DEBUG
    var boundAddressForTesting: String? { listener.boundAddressForTesting }
#endif

    // MARK: - Request handling

    func respond(
        to request: LoopbackHTTPRequest,
        isClientGone: @escaping @Sendable () -> Bool
    ) -> LoopbackHTTPResponse? {
        // Browsers send Origin (and preflight with OPTIONS); the guest agent's
        // MCP client never does, so neither reaches a handler.
        if request.headers["origin"] != nil { return LoopbackHTTPResponse(status: 403) }
        // POST only: no SSE stream (GET), no session to delete (DELETE).
        guard request.method == "POST" else {
            return LoopbackHTTPResponse(status: 405, headers: ["Allow": "POST"])
        }
        guard let live = authenticate(request.headers["authorization"]),
              bindingIsAuthorized(live.binding) else {
            return LoopbackHTTPResponse(status: 401)
        }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let requestedRouteName = path.hasPrefix("/mcp/") ? String(path.dropFirst("/mcp/".count)) : ""
        guard path.hasPrefix("/mcp/"), let route = route(named: requestedRouteName, binding: live.binding) else {
            return LoopbackHTTPResponse(status: 404)
        }
        let contentType = request.headers["content-type"]?.lowercased() ?? ""
        guard contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else {
            return LoopbackHTTPResponse(status: 415)
        }
        guard let line = String(data: request.body, encoding: .utf8),
              let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return LoopbackHTTPResponse(status: 400)
        }
        // Notifications and client responses need no handler and no reply.
        guard let method = message["method"] as? String, let id = message["id"], !(id is NSNull) else {
            return LoopbackHTTPResponse(status: 202)
        }
        if method == "tools/call" {
            let name = (message["params"] as? [String: Any])?["name"] as? String ?? ""
            guard route.allowedTools.contains(name) else {
                return Self.errorResponse(
                    id: id,
                    code: -32602,
                    message: "\(name) is not available to bot runs inside the Linux VM."
                )
            }
        }
        guard acquireSlot(live) else {
            return Self.errorResponse(
                id: id,
                code: -32000,
                message: "Too many MacCode tool calls at once for this run (at most \(maxConcurrentCallsPerRun)). Retry after one finishes."
            )
        }

        let outcome = Outcome()
        let wake = DispatchSemaphore(value: 0)
        let waiterKey = ObjectIdentifier(wake)
        lock.lock()
        let alreadyRevoked = live.revoked
        if !alreadyRevoked { live.waiters[waiterKey] = wake }
        lock.unlock()
        if alreadyRevoked {
            releaseSlot(live)
            return Self.runEndedResponse(id: id)
        }

        let environment = live.binding.hostEnvironment
        let handle = route.handle
        let thread = Thread { [weak self] in
            outcome.set(handle(environment, line))
            self?.releaseSlot(live)
            wake.signal()
        }
        thread.name = Self.handlerThreadPrefix + route.name
        thread.qualityOfService = .userInitiated
        thread.start()

        var finished: String??
        while true {
            _ = wake.wait(timeout: .now() + 1)
            if let value = outcome.get() { finished = value; break }
            if isRevoked(live) { break }
            if isClientGone() { break }
        }
        lock.lock()
        live.waiters[waiterKey] = nil
        let revoked = live.revoked
        lock.unlock()

        guard !revoked, bindingIsAuthorized(live.binding) else {
            return Self.runEndedResponse(id: id)
        }
        guard let finished else {
            return revoked ? Self.runEndedResponse(id: id) : nil
        }
        guard let reply = finished, let data = Self.guestFacing(reply).data(using: .utf8) else {
            return Self.errorResponse(id: id, code: -32603, message: "MacCode returned no reply.")
        }
        return .json(filtered(data, method: method, route: route))
    }

    private func bindingIsAuthorized(_ binding: Binding) -> Bool {
        guard binding.context == context else { return false }
        guard let context else { return true }
        guard let store = contextStore,
              UUID(uuidString: binding.runID) != nil,
              (try? store.authorizes(hostID: context.pin.hostID, botID: context.pin.botID, context: context.pin.context, action: .read, policyRevision: context.pin.policyRevision)) == true,
              (try? store.authorizes(hostID: context.pin.hostID, botID: context.pin.botID, context: context.pin.context, action: .send, policyRevision: context.pin.policyRevision)) == true,
              (try? store.authorizes(hostID: context.pin.hostID, botID: context.pin.botID, context: context.pin.context, action: .configure, policyRevision: context.pin.policyRevision)) == true,
              (try? store.conversationContextPin(conversationID: context.pin.conversationID)) == context.pin,
              let conversation = try? store.conversation(id: context.pin.conversationID),
              conversation.botID == context.pin.botID,
              conversation.linkedAgentThreadID == context.threadID,
              (try? store.conversationContextPin(linkedTo: context.threadID)) == context.pin,
              (try? store.authorizesContextDelegation(hostID: context.pin.hostID, runID: AgentRunID(UUID(uuidString: binding.runID)!), threadID: context.threadID)) == true else { return false }
        return true
    }

    private func route(named name: String, binding: Binding) -> Route? {
        guard context != nil else { return routes[name] }
        if name == ConnectionMCPCatalog.serverName, bindingIsAuthorized(binding) {
            return Route(name: name, allowedTools: [ConnectionMCPCatalog.list, ConnectionMCPCatalog.tools, ConnectionMCPCatalog.call], keepsServerInstructions: true) { environment, line in
                ManagedConnectionsMCP(environment: environment).handle(line)
            }
        }
        guard name == BotSelfConfigCatalog.serverName,
              let context, let store = contextStore,
              bindingIsAuthorized(binding) else { return nil }
        let identity: BotContextRuntimeIdentity
        do { identity = try BotContextRuntimeIdentity(hostID: context.pin.hostID, botID: context.pin.botID, context: context.pin.context, policyRevision: context.pin.policyRevision) }
        catch { return nil }
        let environment = [
            BotSelfConfigCatalog.callerEnvironmentKey: context.pin.botID.value.uuidString,
            BotPeerDelegation.threadEnvironmentKey: context.threadID.value.uuidString,
            BotPeerDelegation.runEnvironmentKey: binding.runID,
        ]
        let adapter = BotContextSecretStore(identity: identity, store: secretStore) { [weak self] in
            guard let self, let context = binding.context else { return false }
            return self.bindingIsAuthorized(binding) && self.context == context
        }
        return Route(name: name, allowedTools: [BotSelfConfigCatalog.listSecrets], keepsServerInstructions: false) { _, line in
            guard Self.contextualArgumentsAreSupported(line, botID: context.pin.botID) else { return nil }
            return ManagedBotSelfConfigMCP(environment: environment, storeFactory: { _ in store }, secretStore: adapter).handle(line)
        }
    }

    private static func contextualArgumentsAreSupported(_ line: String, botID: BotID) -> Bool {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "tools/call" else { return true }
        let params = message["params"] as? [String: Any] ?? [:]
        guard params["name"] as? String == BotSelfConfigCatalog.listSecrets else { return true }
        guard params["arguments"] == nil || params["arguments"] is [String: Any] else { return false }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard Set(arguments.keys).isSubset(of: ["bot_id"]) else { return false }
        guard let raw = arguments["bot_id"] else { return true }
        guard let value = raw as? String, let id = UUID(uuidString: value) else { return false }
        return id == botID.value
    }

    /// The Mac handlers' text sends website writes to `bot_browser_open` (the
    /// `bot_set_settings` description and its website rejection), a Mac relay
    /// this gateway never serves; a guest run opens sites with Playwright.
    static func guestFacing(_ reply: String) -> String {
        reply.replacingOccurrences(of: BotBrainCompiler.websiteHonesty, with: BotBrainCompiler.guestWebsiteHonesty)
    }

    private func filtered(_ data: Data, method: String, route: Route) -> Data {
        guard method == "tools/list" || (method == "initialize" && !route.keepsServerInstructions),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var result = object["result"] as? [String: Any] else {
            return data
        }
        if method == "tools/list" {
            let tools = result["tools"] as? [[String: Any]] ?? []
            result["tools"] = tools.filter { route.allowedTools.contains($0["name"] as? String ?? "") }
        } else {
            result["instructions"] = nil
        }
        object["result"] = result
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }

    private func authenticate(_ header: String?) -> LiveBinding? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let presented = Self.digest(parts[1].trimmingCharacters(in: .whitespaces))
        lock.lock()
        defer { lock.unlock() }
        var match: LiveBinding?
        // Visit every binding and compare every byte, so timing says nothing
        // about which token or how much of it matched.
        for live in bindings where Self.constantTimeEqual(live.digest, presented) {
            match = live
        }
        return match
    }

    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    private static func digest(_ token: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(token.utf8)))
    }

    private func acquireSlot(_ live: LiveBinding) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !live.revoked, live.inFlight < maxConcurrentCallsPerRun else { return false }
        live.inFlight += 1
        return true
    }

    private func releaseSlot(_ live: LiveBinding) {
        lock.lock(); defer { lock.unlock() }
        live.inFlight -= 1
    }

    private func isRevoked(_ live: LiveBinding) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return live.revoked
    }

    private static func runEndedResponse(id: Any) -> LoopbackHTTPResponse {
        errorResponse(id: id, code: -32000, message: "The MacCode run that made this call has ended.")
    }

    private static func errorResponse(id: Any, code: Int, message: String) -> LoopbackHTTPResponse {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]
        return .json((try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}
