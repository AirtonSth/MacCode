import Foundation
import CoreModel

public enum ComposioError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case setupRequired, invalidAPIKey, permissionDenied, invalidResponse, network, timeout, customAuthRequired, accountMismatch, authorizationFailed, notFound, projectInUse, remoteRemovalFailed
    public var errorDescription: String? { description }
    public var description: String {
        switch self {
        case .setupRequired: return "Set up your own Composio project API key to connect apps. The key is stored in Keychain."
        case .invalidAPIKey: return "Composio rejected the project API key. Check it in your Composio project settings."
        case .permissionDenied: return "This project key does not allow the requested operation. Check catalog, connected account, session management and session tool execution permissions in Composio."
        case .invalidResponse: return "Composio returned an unsupported response or an unsafe connection destination. Try again or check your project settings."
        case .network: return "Composio could not be reached. Check your connection and try again."
        case .timeout: return "Account authorization timed out. Connect again when you are ready to finish in the browser."
        case .customAuthRequired: return "This app requires an authentication configuration in your Composio project. Configure its credentials and permissions there, then try again."
        case .accountMismatch: return "The authorized account does not match this app and MacCode user. No connection was granted."
        case .authorizationFailed: return "Account authorization was declined, expired or revoked. Connect again to authorize this app."
        case .notFound: return "The Composio account no longer exists. Connect the app again."
        case .projectInUse: return "Disconnect your current Composio accounts before replacing the project API key."
        case .remoteRemovalFailed: return "Disconnected in MacCode, but the remote account could not be removed. Remove it in your Composio project; provider permissions may also need revoking in the app."
        }
    }
}

public protocol ComposioHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class ComposioNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Dedicated ephemeral session: no cookies, cache, credential storage, or cross-origin redirects.
public final class ComposioURLSessionTransport: ComposioHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 35
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: ComposioNoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw ComposioError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8_388_608 else { throw ComposioError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
}

public struct ComposioAccount: Equatable, Sendable {
    public let id: String
    public let userID: String
    public let toolkitSlug: String
    public let status: String
    public let alias: String?
    public let scopes: [String]
    public let disabled: Bool
    public var isActive: Bool { status == "ACTIVE" && !disabled }
}

public struct ComposioSession: Sendable {
    public let id: String
    /// Credential-bearing session URL: protect in Keychain, never metadata or logs.
    public let mcpURL: URL
}
public struct ComposioAuthLink: Sendable {
    public let accountID: String
    public let redirectURL: URL
}

/// REST v3.1 wire contract follows the official Composio reference. Errors never include payloads.
public struct ComposioClient: Sendable {
    private let transport: any ComposioHTTPTransport
    public init(transport: any ComposioHTTPTransport = ComposioURLSessionTransport()) { self.transport = transport }
    public func catalog(apiKey: String, search: String = "", category: String? = nil, cursor: String? = nil) async throws -> ComposioCatalogPage {
        var query = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "sort_by", value: "usage")]
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if let category, !category.isEmpty { query.append(URLQueryItem(name: "category", value: category)) }
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let response = try await request("GET", "toolkits", apiKey: apiKey, query: query)
        guard let rows = response["items"]?.arrayValue else { throw ComposioError.invalidResponse }
        let items = try rows.map { row -> ComposioToolkit in
            guard let row = row.objectValue, let slug = row["slug"]?.stringValue, let name = row["name"]?.stringValue, Self.validID(slug) else { throw ComposioError.invalidResponse }
            let meta = row["meta"]?.objectValue ?? [:]
            let categories = (meta["categories"]?.arrayValue ?? []).compactMap { item -> ComposioCategory? in
                guard let object = item.objectValue, let id = object["id"]?.stringValue, let name = object["name"]?.stringValue else { return nil }
                return ComposioCategory(id: id, name: name)
            }
            let logo = meta["logo"]?.stringValue.flatMap(URL.init(string:)).flatMap { url -> URL? in
                guard url.scheme == "https", url.user == nil, url.password == nil else { return nil }; return url
            }
            return ComposioToolkit(slug: slug, name: name, description: meta["description"]?.stringValue ?? "", logoURL: logo, categories: categories, managedAuthSchemes: (row["composio_managed_auth_schemes"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
        return ComposioCatalogPage(items: items, nextCursor: response["next_cursor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
    }
    public func createSession(apiKey: String, userID: String, toolkit: String, accountID: String? = nil) async throws -> ComposioSession {
        guard Self.validID(toolkit), Self.validID(userID), accountID.map(Self.validID) ?? true else { throw ComposioError.invalidResponse }
        var body: [String: ConnectionJSONValue] = [
            "user_id": .string(userID), "toolkits": .object(["enable": .array([.string(toolkit)])]),
            "manage_connections": .object(["enable": .bool(accountID == nil)]),
            "workbench": .object(["enable": .bool(false)]), "proxy_execute": .object(["enable": .bool(false)]),
            "instant": .bool(false), "experimental": .object(["no_elicitation_support_fallback": .string("deny")])
        ]
        if let accountID { body["connected_accounts"] = .object([toolkit: .array([.string(accountID)])]) }
        let response = try await request("POST", "tool_router/session", apiKey: apiKey, body: body)
        guard let id = response["session_id"]?.stringValue, Self.validID(id),
              let raw = response["mcp"]?.objectValue?["url"]?.stringValue, let url = URL(string: raw), Self.safeMCPURL(url) else { throw ComposioError.invalidResponse }
        return ComposioSession(id: id, mcpURL: url)
    }
    public func link(apiKey: String, sessionID: String, toolkit: String) async throws -> ComposioAuthLink {
        guard Self.validID(sessionID), Self.validID(toolkit) else { throw ComposioError.invalidResponse }
        let response = try await request("POST", "tool_router/session/\(sessionID)/link", apiKey: apiKey, body: ["toolkit": .string(toolkit)])
        guard let id = response["connected_account_id"]?.stringValue, Self.validID(id),
              let raw = response["redirect_url"]?.stringValue, let url = URL(string: raw),
              url.scheme == "https", let host = url.host?.lowercased(), host == "composio.dev" || host.hasSuffix(".composio.dev"),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw ComposioError.invalidResponse }
        return ComposioAuthLink(accountID: id, redirectURL: url)
    }
    public func account(apiKey: String, id: String) async throws -> ComposioAccount {
        guard Self.validID(id) else { throw ComposioError.invalidResponse }
        let response = try await request("GET", "connected_accounts/\(id)", apiKey: apiKey)
        guard let actualID = response["id"]?.stringValue, let user = response["user_id"]?.stringValue,
              let toolkit = response["toolkit"]?.objectValue?["slug"]?.stringValue, let status = response["status"]?.stringValue else { throw ComposioError.invalidResponse }
        return ComposioAccount(id: actualID, userID: user, toolkitSlug: toolkit, status: status.uppercased(), alias: response["alias"]?.stringValue,
                               scopes: (response["requested_scopes"]?.arrayValue ?? []).compactMap(\.stringValue), disabled: response["is_disabled"]?.boolValue ?? false)
    }
    /// Removes Composio's stored account, not a guarantee of upstream OAuth grant revocation.
    public func deleteAccount(apiKey: String, id: String) async throws {
        guard Self.validID(id) else { throw ComposioError.invalidResponse }
        _ = try await request("DELETE", "connected_accounts/\(id)", apiKey: apiKey)
    }
    public func deleteSession(apiKey: String, id: String) async throws {
        guard Self.validID(id) else { throw ComposioError.invalidResponse }
        _ = try await request("DELETE", "tool_router/session/\(id)", apiKey: apiKey)
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    private static func safeMCPURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "backend.composio.dev" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil && url.fragment == nil
    }
    private func request(_ method: String, _ path: String, apiKey: String, query: [URLQueryItem] = [], body: [String: ConnectionJSONValue]? = nil) async throws -> [String: ConnectionJSONValue] {
        try Task.checkCancellation()
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isWhitespace || $0.asciiValue == 0 }) else { throw ComposioError.invalidAPIKey }
        var components = URLComponents(string: "https://backend.composio.dev/api/v3.1/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, http) = try await transport.send(request)
            try Task.checkCancellation()
            guard http.url?.scheme == "https", http.url?.host?.lowercased() == "backend.composio.dev", http.url?.port == nil || http.url?.port == 443 else { throw ComposioError.invalidResponse }
            switch http.statusCode {
            case 200..<300: break
            case 401: throw ComposioError.invalidAPIKey
            case 403: throw ComposioError.permissionDenied
            case 404: throw ComposioError.notFound
            case 400, 422, 501: throw path.hasSuffix("/link") ? ComposioError.customAuthRequired : ComposioError.invalidResponse
            default: throw ComposioError.network
            }
            if data.isEmpty { return [:] }
            guard data.count <= 8_388_608, let result = try? JSONDecoder().decode([String: ConnectionJSONValue].self, from: data) else { throw ComposioError.invalidResponse }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as ComposioError { throw error }
        catch { throw Task.isCancelled ? CancellationError() : ComposioError.network }
    }
}
