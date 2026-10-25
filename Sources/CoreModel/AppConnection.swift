import Foundation
import Security

public enum ConnectionKind: String, CaseIterable, Codable, Sendable {
    case remoteMCP, stdio, composio
    public var title: String {
        switch self { case .remoteMCP: return "Remote MCP"; case .stdio: return "Local MCP"; case .composio: return "Composio hosted MCP" }
    }
}

public enum ConnectionStatus: String, Codable, Sendable {
    case untested, tested, disconnected, unavailable
    public var title: String {
        switch self { case .untested: return "Not tested"; case .tested: return "Tested"; case .disconnected: return "Disconnected"; case .unavailable: return "Unavailable" }
    }
}

public struct ConnectionScope: Equatable, Sendable {
    public var botID: String?
    public var workspaceID: String?
    public var threadID: String
    public var taskID: String?
    public init(botID: String?, workspaceID: String?, threadID: String, taskID: String? = nil) {
        self.botID = botID?.lowercased(); self.workspaceID = workspaceID?.lowercased(); self.threadID = threadID.lowercased(); self.taskID = taskID?.lowercased()
    }
}

public struct ConnectionAccess: Codable, Equatable, Sendable {
    public var allRuns: Bool
    public var botIDs: [String]
    public var workspaceIDs: [String]
    public var threadIDs: [String]
    public var taskIDs: [String]
    public init(allRuns: Bool = false, botIDs: [String] = [], workspaceIDs: [String] = [], threadIDs: [String] = [], taskIDs: [String] = []) {
        self.allRuns = allRuns; self.botIDs = botIDs.map { $0.lowercased() }; self.workspaceIDs = workspaceIDs.map { $0.lowercased() }; self.threadIDs = threadIDs.map { $0.lowercased() }; self.taskIDs = taskIDs.map { $0.lowercased() }
    }
    public func allows(_ scope: ConnectionScope) -> Bool {
        allRuns || scope.botID.map(botIDs.contains) == true || scope.workspaceID.map(workspaceIDs.contains) == true || threadIDs.contains(scope.threadID) || scope.taskID.map(taskIDs.contains) == true
    }
    public var summary: String {
        if allRuns { return "All bots, workspaces and tasks" }
        let count = botIDs.count + workspaceIDs.count + threadIDs.count + taskIDs.count
        return count == 0 ? "No access granted" : "\(count) selected scopes"
    }
}

/// Metadata only. Headers and environment values live in ConnectionSecretStore.
public struct AppConnection: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var account: String
    public var kind: ConnectionKind
    public var endpoint: String
    public var arguments: [String]
    public var access: ConnectionAccess
    public var status: ConnectionStatus
    public var testedAt: Date?
    public var revision: Int
    public init(id: UUID = UUID(), name: String, account: String = "", kind: ConnectionKind, endpoint: String, arguments: [String] = [], access: ConnectionAccess = ConnectionAccess(), status: ConnectionStatus = .untested, testedAt: Date? = nil, revision: Int = 0) {
        self.id = id; self.name = name; self.account = account; self.kind = kind; self.endpoint = endpoint; self.arguments = arguments; self.access = access; self.status = status; self.testedAt = testedAt; self.revision = revision
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else { throw ConnectionError.invalidConfiguration }
        if kind == .stdio {
            guard endpoint.hasPrefix("/"), !endpoint.contains("\n"), arguments.allSatisfy({ !$0.contains("\u{0}") }) else { throw ConnectionError.invalidConfiguration }
        } else {
            guard let url = URLComponents(string: endpoint), let host = url.host,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { throw ConnectionError.invalidConfiguration }
        }
    }
}

public enum ConnectionError: Error, CustomStringConvertible, Equatable {
    case invalidConfiguration, endpointRequired, supervised, storage, protectedStorage, unavailable, accessDenied, busy, invalidResponse, timeout, stale
    public var description: String {
        switch self {
        case .invalidConfiguration: return "Check the service name, endpoint and JSON fields. Use HTTPS or local HTTP; enter headers or environment values as a JSON object and local arguments as a JSON array."
        case .supervised: return "Service tool execution requires a new run with Full Access. Switch the conversation permission and start a new turn; connection and tool discovery remain available in supervised mode."
        case .endpointRequired: return "Re-enter the full MCP endpoint to reconnect. The previous protected endpoint was removed when this connection was disconnected."
        case .storage: return "Connections could not be read or saved. Existing data was preserved."
        case .protectedStorage: return "Protected connection credentials are unavailable."
        case .unavailable: return "Connection unavailable. Reconnect and test it in Settings → Connections."
        case .accessDenied: return "This run no longer has access to the connection."
        case .busy: return "Too many connection calls are active for this run."
        case .invalidResponse: return "The MCP server returned an invalid or unsupported response."
        case .timeout: return "The MCP request timed out. A tool call was not retried; check the service before repeating a write."
        case .stale: return "The connection changed. Reload it before saving or testing again."
        }
    }
}

public protocol ConnectionSecretStore: Sendable {
    func load(_ id: UUID) throws -> [String: String]
    func save(_ values: [String: String], for id: UUID) throws
    func delete(_ id: UUID) throws
}

/// Separate from bot secrets: never exported into provider or shell environments.
public struct ConnectionKeychainSecretStore: ConnectionSecretStore {
    private let service: String
    public init(service: String = "io.remotecode.connections.v1") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString.lowercased(), kSecAttrSynchronizable as String: false]
    }
    public func load(_ id: UUID) throws -> [String: String] {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = item as? Data, let result = try? JSONDecoder().decode([String: String].self, from: data) else { throw ConnectionError.protectedStorage }
        return result
    }
    public func save(_ values: [String: String], for id: UUID) throws {
        guard let data = try? JSONEncoder().encode(values) else { throw ConnectionError.protectedStorage }
        let fields = [kSecValueData as String: data]
        let status = SecItemUpdate(query(id) as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ConnectionError.protectedStorage }
        var q = query(id); q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ConnectionError.protectedStorage }
    }
    public func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectionError.protectedStorage }
    }
}
