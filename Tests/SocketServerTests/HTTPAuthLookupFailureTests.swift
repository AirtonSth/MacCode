import Darwin
import XCTest
@testable import SocketServer
import CoreModel

/// Auth provider whose trust lookup can fail, as a storage error does in
/// production: the non-throwing lookups then answer "no", which is the same
/// value they give for an unknown bearer.
private final class LookupAuth: DirectAuthProvider, @unchecked Sendable {
    enum Mode {
        /// The trust store cannot be read.
        case lookupFails
        /// The store answers: this bearer is unknown or revoked.
        case unknownBearer
        /// The first lookup failed, the retry inside the same request works.
        case lookupRecovers
    }

    struct LookupFailed: Error {}

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func verify(token: String) -> Bool { false }

    func resolveRPCPrincipal(token: String) throws -> DirectRPCPrincipal? {
        switch mode {
        case .lookupFails:
            throw LookupFailed()
        case .unknownBearer:
            return nil
        case .lookupRecovers:
            return DirectRPCPrincipal(ownerFingerprint: "owner-recovered", grantedCapabilities: "*")
        }
    }

    func createPairingCode() -> String? { nil }
    func redeemPairingCode(
        _ code: String,
        deviceName: String
    ) -> (deviceId: String, token: String)? { nil }
    func listDevices() -> [[String: Any]] { [] }
    func revokeDevice(_ id: String) {}
}

/// ISC-N2 / IDP-06 / MHS-02 / MDP-07: iOS treats 401 as "this device is no
/// longer paired": it stops reconnecting and asks the user to pair again. The
/// host answered 401 both for a revoked bearer and when its own trust lookup
/// failed, so a transient storage error on the Mac signed the phone out.
/// A failed lookup must be answered as "retry" on the calls that carry no
/// mutation (the `/v1/ws` upgrade, GET, and a top-level `/v1/rpc` batch,
/// which the host only runs when every call is read-only), never by
/// accepting the bearer. Any other POST keeps the 401: an unchanged iOS
/// reads a 5xx on a mutation as an unknown outcome it cannot clear.
final class HTTPAuthLookupFailureTests: XCTestCase {
    private struct Response {
        let status: Int
        let headers: [String: String]
    }

    private static let rpcBody = #"{"jsonrpc":"2.0","id":1,"method":"system.ping"}"#

    /// `DirectHTTPServer.auth` is weak: without this the provider is released
    /// when `startServer` returns and the gate under test is switched off.
    private var retainedAuth: DirectAuthProvider?

    private static let authenticatedGet =
        "GET /v1/capabilities/authenticated HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer some-token\r\n\r\n"
    private static let rpcPost =
        "POST /v1/rpc HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer some-token\r\nContent-Type: application/json\r\nContent-Length: \(rpcBody.utf8.count)\r\n\r\n\(rpcBody)"
    /// The shape iOS reads its baseline with: one top-level batch.
    private static let rpcBatchBody =
        #"[{"jsonrpc":"2.0","id":"a","method":"workspace.list"},{"jsonrpc":"2.0","id":"b","method":"window.current"}]"#
    private static let rpcBatchPost = rpcPostRequest(body: rpcBatchBody)
    private static func rpcPostRequest(body: String, extraHeaders: String = "") -> String {
        "POST /v1/rpc HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer some-token\r\nContent-Type: application/json\r\n\(extraHeaders)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }
    private static let webSocketUpgrade =
        "GET /v1/ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer some-token\r\n\r\n"

    @MainActor
    func test_failedTrustLookup_isAnsweredAsRetry_onTheUpgradeAndOnGet() throws {
        let (server, port) = try startServer(auth: LookupAuth(mode: .lookupFails))
        defer { server.stop() }

        for (name, request) in [("GET", Self.authenticatedGet), ("upgrade", Self.webSocketUpgrade)] {
            let response = try XCTUnwrap(exchange(port: port, request: request), name)
            XCTAssertEqual(response.status, 503, "\(name): a lookup failure is not a sign-out")
            XCTAssertEqual(response.headers["retry-after"], "1", name)
            XCTAssertNil(response.headers["www-authenticate"],
                         "\(name): a Bearer challenge would tell the client its token is bad")
        }
    }

    @MainActor
    func test_failedTrustLookup_onPost_keeps401_soAMutationIsADefiniteFailure() throws {
        let (server, port) = try startServer(auth: LookupAuth(mode: .lookupFails))
        defer { server.stop() }

        let response = try XCTUnwrap(exchange(port: port, request: Self.rpcPost))

        XCTAssertEqual(response.status, 401, "the bearer is never accepted on a failed lookup")
        XCTAssertNotNil(response.headers["www-authenticate"])
    }

    /// iOS refreshes a workspace selection with a batch POST and no GET or
    /// upgrade before it; a 401 there shows "Not authorized" with a valid
    /// token. The host runs no mutation from a top-level batch, so "retry"
    /// cannot leave a mutation with an unknown outcome.
    @MainActor
    func test_failedTrustLookup_onAReadOnlyBatchPost_isAnsweredAsRetry() throws {
        let (server, port) = try startServer(auth: LookupAuth(mode: .lookupFails))
        defer { server.stop() }

        let response = try XCTUnwrap(exchange(port: port, request: Self.rpcBatchPost))

        XCTAssertEqual(response.status, 503, "a lookup failure is not a sign-out")
        XCTAssertEqual(response.headers["retry-after"], "1")
        XCTAssertNil(response.headers["www-authenticate"],
                     "a Bearer challenge would tell the client its token is bad")
    }

    /// The body is only looked at when it is plain: an encoded body is not
    /// decoded for a bearer that was not verified, so it keeps the 401.
    @MainActor
    func test_failedTrustLookup_onAnEncodedPost_keeps401_withoutDecodingTheBody() throws {
        let (server, port) = try startServer(auth: LookupAuth(mode: .lookupFails))
        defer { server.stop() }

        let response = try XCTUnwrap(exchange(port: port, request: Self.rpcPostRequest(
            body: Self.rpcBatchBody,
            extraHeaders: "Content-Encoding: rc-lzfse\r\n"
        )))

        XCTAssertEqual(response.status, 401)
        XCTAssertNotNil(response.headers["www-authenticate"])
    }

    @MainActor
    func test_unknownBearer_stillGets401WithChallenge_everywhere() throws {
        let (server, port) = try startServer(auth: LookupAuth(mode: .unknownBearer))
        defer { server.stop() }

        for (name, request) in [
            ("GET", Self.authenticatedGet), ("POST", Self.rpcPost), ("batch POST", Self.rpcBatchPost),
            ("upgrade", Self.webSocketUpgrade),
        ] {
            let response = try XCTUnwrap(exchange(port: port, request: request), name)
            XCTAssertEqual(response.status, 401, "\(name): a revoked device must still be told to pair again")
            XCTAssertNotNil(response.headers["www-authenticate"], name)
            XCTAssertNil(response.headers["retry-after"], name)
        }
    }

    /// The upgrade's owner lookup failed but the store answers a moment later:
    /// the bearer is probably valid, so the client retries; the socket is not
    /// opened on the strength of the second lookup alone.
    @MainActor
    func test_upgradeWhoseFirstLookupFailed_isAskedToRetry_notUpgraded() throws {
        let (server, port) = try startServer(auth: LookupAuth(mode: .lookupRecovers))
        defer { server.stop() }

        let response = try XCTUnwrap(exchange(port: port, request: Self.webSocketUpgrade))

        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(response.headers["retry-after"], "1")
        XCTAssertNil(response.headers["www-authenticate"])
    }

    // MARK: - Helpers

    @MainActor
    private func startServer(auth: DirectAuthProvider) throws -> (DirectHTTPServer, UInt16) {
        retainedAuth = auth
        for _ in 0..<20 {
            let port = UInt16.random(in: 33_000...44_000)
            // The gate is only active on a non-loopback bind.
            let server = DirectHTTPServer(
                port: port,
                loopbackOnly: false,
                dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                auth: auth,
                serverId: "auth-lookup-host",
                bootEpoch: 1
            )
            if (try? server.start()) != nil {
                usleep(80_000)
                return (server, port)
            }
        }
        throw NSError(domain: "HTTPAuthLookupFailureTests", code: 1)
    }

    /// One raw request, returning the status line and headers of the reply.
    private func exchange(port: UInt16, request: String) -> Response? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let bytes = Array(request.utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { return nil }

        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while received.count < 64 * 1_024,
              String(decoding: received, as: UTF8.self).range(of: "\r\n\r\n") == nil {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            received.append(contentsOf: buffer.prefix(count))
        }
        let text = String(decoding: received, as: UTF8.self)
        guard let head = text.components(separatedBy: "\r\n\r\n").first else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusParts = lines.removeFirst().split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return Response(status: status, headers: headers)
    }
}
