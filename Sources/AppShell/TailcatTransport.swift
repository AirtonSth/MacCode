import CryptoKit
import Foundation
import RCTailcat
import Security
import SocketServer

enum TailcatTransportContract {
    static let buildID = "tailcat-88929418b1a3f3c74904a3136d6a9e87b1b5b9bb+rcpatch1"
    static let primaryDERPHost = "derp.remotecode.io"
    static let primaryDERPIPv4 = "82.25.69.175"
    static let primaryDERPPort: UInt16 = 444
    static let primarySTUNPort: UInt16 = 3478
    static let primaryRegionID: UInt32 = 1
    static let pollInterval: TimeInterval = 15
    static let renewalInterval: TimeInterval = 5 * 60
    static let hostLease: TimeInterval = 15 * 60
}

enum TailcatEndpointKind: String, Codable, Sendable {
    case direct
    case derp
}

struct TailcatCatalogEndpoint: Codable, Equatable, Sendable {
    let kind: TailcatEndpointKind
    let priority: Int
    let connBlob: String
}

struct TailcatCatalogClient: Codable, Equatable, Sendable {
    let clientId: String
    let displayName: String
    let nodePublic: String
    let transportBuildId: String
    let createdAt: String
    let updatedAt: String
    let leaseExpiresAt: String
    let version: Int64
}

struct TailcatAllowlistSnapshot: Codable, Equatable, Sendable {
    let epoch: String
    let revision: Int64
    let clients: [TailcatCatalogClient]

    var admittedNodePublics: [String] {
        clients
            .filter { $0.transportBuildId == TailcatTransportContract.buildID }
            .map(\.nodePublic)
            .sorted()
    }

    var hash: String {
        let data = (try? JSONEncoder.tailcatCanonical.encode(self)) ?? Data()
        return Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}

struct TailcatCatalogHost: Codable, Equatable, Sendable {
    let serverId: String
    let displayName: String
    let endpoints: [TailcatCatalogEndpoint]
    let transportBuildId: String
    let createdAt: String
    let updatedAt: String
    let leaseExpiresAt: String
    let version: Int64
}

struct TailcatHostSnapshot: Sendable {
    let host: TailcatCatalogHost?
    let snapshot: TailcatAllowlistSnapshot
    let eTag: String?
}

struct TailcatPublishedHost: Sendable {
    let host: TailcatCatalogHost
    let eTag: String
}

enum TailcatCatalogError: Error, Equatable {
    case invalidResponse
    case http(status: Int, code: String?)

    var deniesSubscription: Bool {
        guard case .http(let status, _) = self else { return false }
        return status == 401 || status == 403
    }

    var isConflict: Bool {
        guard case .http(let status, let code) = self else { return false }
        return status == 409 && code == "tailcat_etag_conflict"
    }
}

protocol TailcatCatalogAPI: Sendable {
    func host(serverID: String, accessToken: String) async throws -> TailcatHostSnapshot
    func publishHost(
        serverID: String,
        displayName: String,
        endpoints: [TailcatCatalogEndpoint],
        accessToken: String,
        ifMatch: String?
    ) async throws -> TailcatPublishedHost
    func deleteHost(serverID: String, accessToken: String) async throws
}

final class URLSessionTailcatCatalogAPI: TailcatCatalogAPI, @unchecked Sendable {
    private struct FailureResponse: Decodable { let code: String? }
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder.tailcatCanonical

    init(
        baseURL: URL = URL(string: "https://private.remotecode.io")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func host(serverID: String, accessToken: String) async throws -> TailcatHostSnapshot {
        struct Response: Decodable {
            let host: TailcatCatalogHost?
            let snapshot: TailcatAllowlistSnapshot
        }
        let (response, eTag): (Response, String?) = try await request(
            serverID: serverID,
            method: "GET",
            accessToken: accessToken
        )
        if let host = response.host, host.transportBuildId != TailcatTransportContract.buildID {
            throw TailcatCatalogError.http(status: 409, code: "unsupported_tailcat_version")
        }
        return TailcatHostSnapshot(host: response.host, snapshot: response.snapshot, eTag: eTag)
    }

    func publishHost(
        serverID: String,
        displayName: String,
        endpoints: [TailcatCatalogEndpoint],
        accessToken: String,
        ifMatch: String?
    ) async throws -> TailcatPublishedHost {
        struct Body: Encodable {
            let displayName: String
            let endpoints: [TailcatCatalogEndpoint]
        }
        struct Response: Decodable { let host: TailcatCatalogHost }
        let (response, eTag): (Response, String?) = try await request(
            serverID: serverID,
            method: "PUT",
            accessToken: accessToken,
            ifMatch: ifMatch,
            body: Body(displayName: displayName, endpoints: endpoints),
            requiresETag: true
        )
        guard response.host.transportBuildId == TailcatTransportContract.buildID else {
            throw TailcatCatalogError.http(status: 409, code: "unsupported_tailcat_version")
        }
        guard let eTag else { throw TailcatCatalogError.invalidResponse }
        return TailcatPublishedHost(host: response.host, eTag: eTag)
    }

    func deleteHost(serverID: String, accessToken: String) async throws {
        let escaped = serverID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serverID
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/private/tailcat/hosts/\(escaped)")
        )
        request.httpMethod = "DELETE"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            TailcatTransportContract.buildID,
            forHTTPHeaderField: "x-tailcat-transport-build-id"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TailcatCatalogError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = try? decoder.decode(FailureResponse.self, from: data).code
            throw TailcatCatalogError.http(status: http.statusCode, code: code)
        }
    }

    private func request<Response: Decodable>(
        serverID: String,
        method: String,
        accessToken: String,
        ifMatch: String? = nil,
        body: (any Encodable)? = nil,
        requiresETag: Bool = false
    ) async throws -> (Response, String?) {
        let escaped = serverID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serverID
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/private/tailcat/hosts/\(escaped)")
        )
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            TailcatTransportContract.buildID,
            forHTTPHeaderField: "x-tailcat-transport-build-id"
        )
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(TailcatAnyEncodable(body))
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TailcatCatalogError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = try? decoder.decode(FailureResponse.self, from: data).code
            throw TailcatCatalogError.http(status: http.statusCode, code: code)
        }
        let eTag = http.value(forHTTPHeaderField: "ETag")
        if requiresETag, eTag?.isEmpty != false {
            throw TailcatCatalogError.invalidResponse
        }
        do {
            return (try decoder.decode(Response.self, from: data), eTag)
        } catch {
            throw TailcatCatalogError.invalidResponse
        }
    }
}

private extension JSONEncoder {
    static var tailcatCanonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private struct TailcatAnyEncodable: Encodable {
    private let encodeBody: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        encodeBody = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeBody(encoder)
    }
}

struct TailcatBridgeKey: Codable, Equatable, Sendable {
    let privateKey: String
    let publicKey: String
}

struct TailcatRunningServer: Equatable, Sendable {
    let handle: UInt64
    let connBlob: String
    let nodePublic: String
}

enum TailcatRelay: Sendable {
    case primary
    case publicFallback
}

enum TailcatBridgeError: Error, Equatable {
    case invalidResponse
    case rejected(String)
    case buildMismatch(String)
}

protocol TailcatBridgeRuntime: Sendable {
    func buildID() throws -> String
    func generateKey() throws -> TailcatBridgeKey
    func startServer(
        key: TailcatBridgeKey,
        allowedNodePublics: [String],
        secret: Data,
        listenerID: Data,
        serverID: String,
        loopbackPort: UInt16,
        relay: TailcatRelay
    ) throws -> TailcatRunningServer
    func closeServer(handle: UInt64) throws
}

final class LinkedTailcatBridge: TailcatBridgeRuntime, @unchecked Sendable {
    private struct ResultEnvelope: Decodable {
        let handle: UInt64?
        let connBlob: String?
        let nodePublic: String?
        let error: String?
    }

    func buildID() throws -> String {
        try consume(RCTailcatBuildID()) { String(cString: $0) }
    }

    func generateKey() throws -> TailcatBridgeKey {
        let result: ResultEnvelope = try decode(RCTailcatGeneratePrivateKey())
        if let error = result.error { throw TailcatBridgeError.rejected(error) }
        guard let privateKey = result.connBlob, let publicKey = result.nodePublic else {
            throw TailcatBridgeError.invalidResponse
        }
        return TailcatBridgeKey(privateKey: privateKey, publicKey: publicKey)
    }

    func startServer(
        key: TailcatBridgeKey,
        allowedNodePublics: [String],
        secret: Data,
        listenerID: Data,
        serverID: String,
        loopbackPort: UInt16,
        relay: TailcatRelay
    ) throws -> TailcatRunningServer {
        let actualBuild = try buildID()
        guard actualBuild == TailcatTransportContract.buildID else {
            throw TailcatBridgeError.buildMismatch(actualBuild)
        }
        guard !allowedNodePublics.isEmpty,
              secret.count == 32,
              listenerID.count == 16,
              let allowedData = try? JSONEncoder.tailcatCanonical.encode(allowedNodePublics),
              let allowed = String(data: allowedData, encoding: .utf8) else {
            throw TailcatBridgeError.rejected("invalid_server_configuration")
        }
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()
        let listenerHex = listenerID.map { String(format: "%02x", $0) }.joined()
        let resultPointer = key.privateKey.withCString { privateValue in
            allowed.withCString { allowedValue in
                secretHex.withCString { secretValue in
                    listenerHex.withCString { listenerValue in
                        serverID.withCString { serverIDValue in
                            switch relay {
                            case .primary:
                                return TailcatTransportContract.primaryDERPHost.withCString { hostValue in
                                    TailcatTransportContract.primaryDERPIPv4.withCString { ipv4Value in
                                        RCTailcatServerStartWithDERP(
                                            UnsafeMutablePointer(mutating: privateValue),
                                            UnsafeMutablePointer(mutating: allowedValue),
                                            UnsafeMutablePointer(mutating: secretValue),
                                            UnsafeMutablePointer(mutating: listenerValue),
                                            UnsafeMutablePointer(mutating: serverIDValue),
                                            UnsafeMutablePointer(mutating: hostValue),
                                            UnsafeMutablePointer(mutating: ipv4Value),
                                            loopbackPort,
                                            TailcatTransportContract.primaryDERPPort,
                                            TailcatTransportContract.primarySTUNPort,
                                            TailcatTransportContract.primaryRegionID
                                        )
                                    }
                                }
                            case .publicFallback:
                                return RCTailcatServerStart(
                                    UnsafeMutablePointer(mutating: privateValue),
                                    UnsafeMutablePointer(mutating: allowedValue),
                                    UnsafeMutablePointer(mutating: secretValue),
                                    UnsafeMutablePointer(mutating: listenerValue),
                                    UnsafeMutablePointer(mutating: serverIDValue),
                                    loopbackPort
                                )
                            }
                        }
                    }
                }
            }
        }
        let result: ResultEnvelope = try decode(resultPointer)
        if let error = result.error { throw TailcatBridgeError.rejected(error) }
        guard let handle = result.handle,
              let connBlob = result.connBlob,
              let nodePublic = result.nodePublic else { throw TailcatBridgeError.invalidResponse }
        return TailcatRunningServer(handle: handle, connBlob: connBlob, nodePublic: nodePublic)
    }

    func closeServer(handle: UInt64) throws {
        let result: ResultEnvelope = try decode(RCTailcatServerClose(handle))
        if let error = result.error { throw TailcatBridgeError.rejected(error) }
    }

    private func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?) throws -> T {
        try consume(pointer) { pointer in
            guard let data = String(cString: pointer).data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                throw TailcatBridgeError.invalidResponse
            }
            return decoded
        }
    }

    private func consume<T>(_ pointer: UnsafeMutablePointer<CChar>?, _ body: (UnsafeMutablePointer<CChar>) throws -> T) throws -> T {
        guard let pointer else { throw TailcatBridgeError.invalidResponse }
        defer { RCTailcatFree(pointer) }
        return try body(pointer)
    }
}

enum TailcatPersistentPhase: String, Codable, Sendable {
    case revoked
    case publishing
    case active
}

struct TailcatKeyVersion: Codable, Equatable, Sendable {
    let primary: TailcatBridgeKey
    let fallback: TailcatBridgeKey
}

struct TailcatSecureState: Codable, Equatable, Sendable {
    var phase: TailcatPersistentPhase
    var accountID: String
    var allowlistEpoch: String
    var revision: Int64
    var snapshotHash: String
    var eTag: String?
    var active: TailcatKeyVersion?
    var pending: TailcatKeyVersion?
}

protocol TailcatSecureStateStoring: Sendable {
    func load() throws -> TailcatSecureState?
    func save(_ state: TailcatSecureState) throws
    func clear() throws
}

enum TailcatSecureStateError: Error {
    case keychain(OSStatus)
    case encoding
}

final class KeychainTailcatSecureStateStore: TailcatSecureStateStoring, @unchecked Sendable {
    private let service = "io.remotecode.desktop.tailcat"
    private let account = "server-key-and-allowlist-v1"

    func load() throws -> TailcatSecureState? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let state = try? JSONDecoder().decode(TailcatSecureState.self, from: data) else {
            throw TailcatSecureStateError.keychain(status)
        }
        return state
    }

    func save(_ state: TailcatSecureState) throws {
        guard let data = try? JSONEncoder.tailcatCanonical.encode(state) else {
            throw TailcatSecureStateError.encoding
        }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TailcatSecureStateError.keychain(status) }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw TailcatSecureStateError.keychain(addStatus) }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TailcatSecureStateError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
