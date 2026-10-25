import Foundation
import CoreModel
import Persistence

/// App-owned execution boundary. Provider processes get only the existing per-run host capability.
public actor ConnectionBroker {
    private let store: ConnectionStore
    private let secrets: any ConnectionSecretStore
    private var clients: [UUID: (Int, ConnectionMCPClient)] = [:]
    private var calls: [String: Int] = [:]
    private let beforeClientClose: (@Sendable () async -> Void)?
    public init(store: ConnectionStore, secrets: any ConnectionSecretStore = ConnectionKeychainSecretStore()) { self.store = store; self.secrets = secrets; beforeClientClose = nil }
    init(store: ConnectionStore, secrets: any ConnectionSecretStore, beforeClientCloseForTesting: @escaping @Sendable () async -> Void) {
        self.store = store; self.secrets = secrets; beforeClientClose = beforeClientCloseForTesting
    }

    /// The complete remote URL can itself be a credential (including hosted session IDs).
    private static let protectedEndpointKey = "__MACCODE_REMOTE_ENDPOINT"
    public func save(_ connection: AppConnection, credentials: [String: String]?, expectedRevision: Int? = nil) async throws {
        if let expectedRevision, try store.get(connection.id)?.revision != expectedRevision { throw ConnectionError.stale }
        let previous = try store.get(connection.id)
        let oldSecrets = try secrets.load(connection.id)
        var protected = credentials ?? (previous?.kind == connection.kind ? oldSecrets.filter { $0.key != Self.protectedEndpointKey } : [:])
        guard !protected.keys.contains(Self.protectedEndpointKey) else { throw ConnectionError.invalidConfiguration }
        var next = connection
        if connection.kind != .stdio {
            let unchanged = previous?.kind == connection.kind && previous?.endpoint == connection.endpoint
            let endpoint: String
            if unchanged {
                guard let savedEndpoint = oldSecrets[Self.protectedEndpointKey] else { throw ConnectionError.endpointRequired }
                endpoint = savedEndpoint
            } else { endpoint = connection.endpoint }
            guard let url = URLComponents(string: endpoint), let host = url.host,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { throw ConnectionError.invalidConfiguration }
            var display = url; display.path = "/protected-mcp-endpoint"; display.query = nil; display.fragment = nil
            guard let safeEndpoint = display.string else { throw ConnectionError.invalidConfiguration }
            next.endpoint = safeEndpoint
            protected[Self.protectedEndpointKey] = endpoint
        }
        try next.validate()
        next.status = .untested; next.testedAt = nil
        try secrets.save(protected, for: connection.id)
        do { try store.save(next, expectedRevision: expectedRevision) }
        catch {
            // A rejected metadata save must not silently replace a working credential.
            try? secrets.save(oldSecrets, for: connection.id)
            throw error
        }
        if let old = clients.removeValue(forKey: connection.id) { await old.1.close() }
    }
    public func disconnect(_ id: UUID) async throws {
        // Durable revocation first, including while another call is awaiting its response.
        try store.disconnect(id)
        let old = clients.removeValue(forKey: id)
        // Delete the old credentials before yielding: a reconnect may run during close.
        let deletion = Result { try secrets.delete(id) }
        if let old {
            await beforeClientClose?()
            await old.1.close()
        }
        try deletion.get()
    }
    public func test(_ id: UUID) async throws -> Int {
        guard let connection = try store.get(id), connection.status != .disconnected else { throw ConnectionError.unavailable }
        do {
            let tools = try await listTools(connection)
            try store.markTest(id, revision: connection.revision, success: true)
            return tools.count
        } catch {
            try? store.markTest(id, revision: connection.revision, success: false)
            throw (error as? ConnectionError) ?? ConnectionError.unavailable
        }
    }
    public func handle(_ message: [String: ConnectionJSONValue], scope: ConnectionScope, runID: String, authorize: @escaping @Sendable () async throws -> Void) async throws -> [String: ConnectionJSONValue] {
        try await authorize()
        guard (calls[runID] ?? 0) < 8 else { throw ConnectionError.busy }
        calls[runID, default: 0] += 1
        defer { calls[runID, default: 1] -= 1; if calls[runID] == 0 { calls.removeValue(forKey: runID) } }
        let method = message["method"]?.stringValue ?? ""
        if method == "tools/list" { return ["tools": .array(ConnectionMCPCatalog.toolsCatalog)] }
        guard method == "tools/call", let params = message["params"]?.objectValue else { throw ConnectionError.invalidResponse }
        let name = params["name"]?.stringValue ?? ""
        let args = params["arguments"]?.objectValue ?? [:]
        if name == ConnectionMCPCatalog.list {
            let rows = try store.list().filter { $0.status != .disconnected && $0.access.allows(scope) }.map { connection in
                ConnectionJSONValue.object(["id": .string(connection.id.uuidString.lowercased()), "name": .string(connection.name), "account": .string(connection.account), "status": .string(connection.status.title)])
            }
            return try content(.array(rows))
        }
        guard let rawID = args["connection_id"]?.stringValue, let id = UUID(uuidString: rawID) else { throw ConnectionError.invalidConfiguration }
        let connection = try admitted(id, scope: scope)
        let result: [String: ConnectionJSONValue]
        if name == ConnectionMCPCatalog.tools {
            result = try content(.array(try await listTools(connection)))
        } else if name == ConnectionMCPCatalog.call {
            guard let tool = args["name"]?.stringValue else { throw ConnectionError.invalidConfiguration }
            let client = try await client(for: connection)
            // Check the tool actually exists before dispatch; no execution retries.
            let tools = try await listTools(connection)
            guard tools.contains(where: { $0.objectValue?["name"]?.stringValue == tool }) else { throw ConnectionError.invalidConfiguration }
            try await authorize()
            _ = try admitted(id, scope: scope, revision: connection.revision)
            result = try await client.request("tools/call", params: ["name": .string(tool), "arguments": .object(args["arguments"]?.objectValue ?? [:])])
        } else { throw ConnectionError.invalidConfiguration }
        // A disconnected/reconfigured connection or revoked run cannot publish a late result.
        try await authorize()
        _ = try admitted(id, scope: scope, revision: connection.revision)
        return result
    }
    private func admitted(_ id: UUID, scope: ConnectionScope, revision: Int? = nil) throws -> AppConnection {
        guard let c = try store.get(id), c.status != .disconnected, c.status != .unavailable, c.access.allows(scope), revision == nil || c.revision == revision else { throw ConnectionError.accessDenied }
        return c
    }
    private func client(for connection: AppConnection) async throws -> ConnectionMCPClient {
        if let (revision, client) = clients[connection.id], revision == connection.revision { return client }
        let old = clients.removeValue(forKey: connection.id)
        var credentials = try secrets.load(connection.id)
        var runtime = connection
        if connection.kind != .stdio {
            // Legacy direct store callers remain useful for owned fixtures; native saves always protect the full URL.
            runtime.endpoint = credentials.removeValue(forKey: Self.protectedEndpointKey) ?? connection.endpoint
        }
        let client = ConnectionMCPClient(connection: runtime, credentials: credentials)
        clients[connection.id] = (connection.revision, client)
        if let old { await old.1.close() }
        return client
    }
    private func listTools(_ connection: AppConnection) async throws -> [ConnectionJSONValue] {
        let client = try await client(for: connection)
        do {
            var tools: [ConnectionJSONValue] = [], cursor: String?
            var seen = Set<String>()
            var pages = 0
            repeat {
                guard pages < 64 else { throw ConnectionError.invalidResponse }
                pages += 1
                let response = try await client.request("tools/list", params: cursor.map { ["cursor": .string($0)] } ?? [:])
                guard let page = response["tools"]?.arrayValue, page.allSatisfy({ $0.objectValue?["name"]?.stringValue != nil && $0.objectValue?["inputSchema"]?.objectValue != nil }) else { throw ConnectionError.invalidResponse }
                tools += page
                guard tools.count <= 10_000 else { throw ConnectionError.invalidResponse }
                cursor = response["nextCursor"]?.stringValue
                if let cursor, !seen.insert(cursor).inserted { throw ConnectionError.invalidResponse }
            } while cursor != nil
            return tools
        } catch {
            // Only retire the session used by this failed discovery. A concurrent
            // reconnect may already have installed a newer revision/client.
            if let cached = clients[connection.id], cached.0 == connection.revision, cached.1 === client {
                clients.removeValue(forKey: connection.id)
                await cached.1.close()
            }
            throw error
        }
    }
    private func content(_ value: ConnectionJSONValue) throws -> [String: ConnectionJSONValue] {
        let data = try JSONEncoder().encode(value)
        return ["content": .array([.object(["type": .string("text"), "text": .string(String(decoding: data, as: UTF8.self))])]), "isError": .bool(false)]
    }
}
