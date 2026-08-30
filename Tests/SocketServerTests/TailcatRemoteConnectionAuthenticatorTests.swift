import CryptoKit
import XCTest
@testable import SocketServer

final class TailcatRemoteConnectionAuthenticatorTests: XCTestCase {
    func testValidPreambleIsConsumedOnceAndRemoteLoopbackStillRequiresBearer() {
        let secret = Data(repeating: 0x11, count: 32)
        let listenerID = Data(repeating: 0x22, count: 16)
        let peer = Data(repeating: 0x33, count: 32)
        let authenticator = TailcatRemoteConnectionAuthenticator()
        authenticator.replaceContexts([.init(
            serverID: "host.primary",
            listenerID: listenerID,
            secret: secret,
            allowedPeerPublic: [nodePublic(peer)]
        )])
        let preamble = makePreamble(
            secret: secret,
            listenerID: listenerID,
            serverID: "host.primary",
            counter: 1,
            nonce: Data(repeating: 0x44, count: 16),
            peer: peer
        )

        XCTAssertTrue(authenticator.verify(preamble))
        XCTAssertFalse(authenticator.verify(preamble), "a duplicate counter/nonce must be rejected")
        XCTAssertTrue(DirectHTTPServer.wsUpgradeRequiresToken(
            loopbackOnly: true,
            hasAuthProvider: true,
            remoteAuthenticated: true
        ))
        XCTAssertTrue(DirectHTTPServer.httpAuthGateRequiresToken(
            loopbackOnly: true,
            path: "/v1/rpc",
            hasAuthProvider: true,
            remoteAuthenticated: true
        ))
        XCTAssertFalse(DirectHTTPServer.httpAuthGateRequiresToken(
            loopbackOnly: true,
            path: "/v1/rpc",
            hasAuthProvider: true,
            remoteAuthenticated: false
        ))
    }

    func testPreambleRejectsSubstitutedPeerCrossLaunchAndCrossServer() {
        let secret = Data(repeating: 0x51, count: 32)
        let listenerID = Data(repeating: 0x52, count: 16)
        let admittedPeer = Data(repeating: 0x53, count: 32)
        let substitutedPeer = Data(repeating: 0x54, count: 32)
        let preamble = makePreamble(
            secret: secret,
            listenerID: listenerID,
            serverID: "host.primary",
            counter: 9,
            nonce: Data(repeating: 0x55, count: 16),
            peer: substitutedPeer
        )

        let substituted = TailcatRemoteConnectionAuthenticator()
        substituted.replaceContexts([.init(
            serverID: "host.primary",
            listenerID: listenerID,
            secret: secret,
            allowedPeerPublic: [nodePublic(admittedPeer)]
        )])
        XCTAssertFalse(substituted.verify(preamble))

        let crossLaunch = TailcatRemoteConnectionAuthenticator()
        crossLaunch.replaceContexts([.init(
            serverID: "host.primary",
            listenerID: Data(repeating: 0x62, count: 16),
            secret: Data(repeating: 0x61, count: 32),
            allowedPeerPublic: [nodePublic(substitutedPeer)]
        )])
        XCTAssertFalse(crossLaunch.verify(preamble))

        let crossServer = TailcatRemoteConnectionAuthenticator()
        crossServer.replaceContexts([.init(
            serverID: "host.fallback",
            listenerID: listenerID,
            secret: secret,
            allowedPeerPublic: [nodePublic(substitutedPeer)]
        )])
        XCTAssertFalse(crossServer.verify(preamble))
    }

    private func makePreamble(
        secret: Data,
        listenerID: Data,
        serverID: String,
        counter: UInt64,
        nonce: Data,
        peer: Data
    ) -> Data {
        var authenticated = Data("RCTC".utf8)
        authenticated.append(1)
        authenticated.append(contentsOf: [0, 0, 0])
        authenticated.append(listenerID)
        authenticated.append(Data(SHA256.hash(data: Data(serverID.utf8))))
        var bigEndianCounter = counter.bigEndian
        withUnsafeBytes(of: &bigEndianCounter) { authenticated.append(contentsOf: $0) }
        authenticated.append(nonce)
        authenticated.append(peer)
        let code = HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: secret)
        )
        authenticated.append(contentsOf: code)
        XCTAssertEqual(authenticated.count, TailcatRemoteConnectionAuthenticator.preambleSize)
        return authenticated
    }

    private func nodePublic(_ bytes: Data) -> String {
        "nodekey:" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}
