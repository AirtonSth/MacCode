import CryptoKit
import Darwin
import XCTest
@testable import SocketServer

@MainActor
final class TailcatLoopbackListenerTests: XCTestCase {
    private let secret = Data(repeating: 0x11, count: 32)
    private let listenerID = Data(repeating: 0x22, count: 16)
    private let peer = Data(repeating: 0x33, count: 32)

    func testTailcatListenerBindsDedicatedIPv4AndIPv6LoopbacksWithoutTouchingLAN() throws {
        let directPort = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: directPort,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            bootEpoch: 1
        )
        try server.start()
        defer { server.stop() }

        let authenticator = configuredAuthenticator()
        let listener = TailcatLoopbackListener(authenticator: authenticator)
        listener.setHTTPServer(server)
        let tailcatPort = try listener.start()
        defer { listener.stop() }

        XCTAssertNotEqual(tailcatPort, directPort)
        XCTAssertEqual(listener.portForTesting, tailcatPort)
        XCTAssertEqual(listener.boundAddressesForTesting, ["127.0.0.1", "::1"])

        let directResponse = try request(
            fd: connectIPv4(port: directPort),
            payload: Data("GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
        )
        XCTAssertTrue(directResponse.starts(with: Data("HTTP/1.1 200".utf8)))

        let ipv6Response = try request(
            fd: connectIPv6(port: tailcatPort),
            payload: preamble(counter: 1) + Data(
                "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8
            )
        )
        XCTAssertTrue(ipv6Response.starts(with: Data("HTTP/1.1 200".utf8)))

        listener.stop()
        let directAfterTailcatStop = try request(
            fd: connectIPv4(port: directPort),
            payload: Data("GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
        )
        XCTAssertTrue(directAfterTailcatStop.starts(with: Data("HTTP/1.1 200".utf8)))
    }

    func testTailcatListenerRequiresBearerForHTTPAndWebSocket() throws {
        let auth = TailcatTestAuth()
        let server = DirectHTTPServer(
            port: UInt16.random(in: 44_001...54_000),
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            auth: auth,
            serverId: "host",
            bootEpoch: 1
        )
        let authenticator = configuredAuthenticator()
        let listener = TailcatLoopbackListener(authenticator: authenticator)
        listener.setHTTPServer(server)
        let port = try listener.start()
        defer { listener.stop() }

        let unauthorizedHTTP = try request(
            fd: connectIPv4(port: port),
            payload: preamble(counter: 2) + Data(
                "GET /v1/rpc HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8
            )
        )
        XCTAssertTrue(unauthorizedHTTP.starts(with: Data("HTTP/1.1 401".utf8)))

        let authorizedHTTP = try request(
            fd: connectIPv4(port: port),
            payload: preamble(counter: 3) + Data(
                "GET /v1/capabilities/authenticated HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer good-token\r\nConnection: close\r\n\r\n".utf8
            )
        )
        XCTAssertTrue(authorizedHTTP.starts(with: Data("HTTP/1.1 200".utf8)))

        let wsHeaders = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        let unauthorizedWebSocket = try request(
            fd: connectIPv4(port: port),
            payload: preamble(counter: 4) + Data(
                "GET /v1/ws HTTP/1.1\r\nHost: localhost\r\n\(wsHeaders)\r\n".utf8
            )
        )
        XCTAssertTrue(unauthorizedWebSocket.starts(with: Data("HTTP/1.1 401".utf8)))

        let authorizedWebSocket = try request(
            fd: connectIPv4(port: port),
            payload: preamble(counter: 5) + Data(
                "GET /v1/ws HTTP/1.1\r\nHost: localhost\r\n\(wsHeaders)Authorization: Bearer good-token\r\n\r\n".utf8
            )
        )
        XCTAssertTrue(authorizedWebSocket.starts(with: Data("HTTP/1.1 101".utf8)))
    }

    private func configuredAuthenticator() -> TailcatRemoteConnectionAuthenticator {
        let authenticator = TailcatRemoteConnectionAuthenticator()
        authenticator.replaceContexts([.init(
            serverID: "host.primary",
            listenerID: listenerID,
            secret: secret,
            allowedPeerPublic: [nodePublic(peer)]
        )])
        return authenticator
    }

    private func preamble(counter: UInt64) -> Data {
        var authenticated = Data("RCTC".utf8)
        authenticated.append(1)
        authenticated.append(contentsOf: [0, 0, 0])
        authenticated.append(listenerID)
        authenticated.append(Data(SHA256.hash(data: Data("host.primary".utf8))))
        var bigEndianCounter = counter.bigEndian
        withUnsafeBytes(of: &bigEndianCounter) { authenticated.append(contentsOf: $0) }
        authenticated.append(Data(repeating: UInt8(counter), count: 16))
        authenticated.append(peer)
        authenticated.append(contentsOf: HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: secret)
        ))
        return authenticated
    }

    private func nodePublic(_ data: Data) -> String {
        "nodekey:" + data.map { String(format: "%02x", $0) }.joined()
    }

    private func connectIPv4(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    private func connectIPv6(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(port).bigEndian
        address.sin6_addr = in6addr_loopback
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    private func request(fd: Int32, payload: Data) throws -> Data {
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            response.append(buffer, count: count)
            if response.range(of: Data("\r\n\r\n".utf8)) != nil,
               response.starts(with: Data("HTTP/1.1 101".utf8)) {
                break
            }
        }
        return response
    }
}

private final class TailcatTestAuth: DirectAuthProvider {
    func verify(token: String) -> Bool { token == "good-token" }
    func createPairingCode() -> String? { nil }
    func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? { nil }
    func listDevices() -> [[String: Any]] { [] }
    func revokeDevice(_ id: String) {}
}
