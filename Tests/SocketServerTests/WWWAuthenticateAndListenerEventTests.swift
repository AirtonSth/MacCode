import XCTest
@testable import SocketServer

/// Tests for two pure helpers added in P3:
///   (a) wwwAuthenticateHeaderValue - 401 responses must advertise the auth
///       scheme+realm so a generic HTTP client knows HOW to authenticate,
///       not just THAT it failed.
///   (b) serverListenerEventPayload - bind success/failure must be observable
///       as a structured EventBus payload so UI and iOS can show remote-access
///       health without parsing NSLog output.
final class WWWAuthenticateAndListenerEventTests: XCTestCase {

    // MARK: wwwAuthenticateHeaderValue

    func test_wwwAuthenticate_includesSchemeAndRealm() {
        // WHY: a bare 401 gives no scheme/realm; RFC 7235 requires
        // WWW-Authenticate so clients can attempt re-auth automatically.
        let value = wwwAuthenticateHeaderValue(scheme: "Bearer", realm: "RC2")
        XCTAssertTrue(value.contains("Bearer"),
                      "scheme must be present in WWW-Authenticate header value")
        XCTAssertTrue(value.contains("realm="),
                      "realm parameter must be present in WWW-Authenticate header value")
        XCTAssertTrue(value.contains("RC2"),
                      "realm value must be RC2")
    }

    func test_wwwAuthenticate_realmIsQuoted() {
        // WHY: RFC 7235 s2.2 mandates realm as a quoted-string;
        // unquoted realm breaks strict parsers.
        let value = wwwAuthenticateHeaderValue(scheme: "Bearer", realm: "MyRealm")
        XCTAssertTrue(value.contains("realm=\"MyRealm\""),
                      "realm value must be enclosed in double-quotes per RFC 7235")
    }

    func test_wwwAuthenticate_customSchemeAndRealm() {
        // WHY: helper must be reusable for any scheme (e.g. Basic in tests),
        // not hardcoded to Bearer.
        let value = wwwAuthenticateHeaderValue(scheme: "Basic", realm: "Admin")
        XCTAssertTrue(value.hasPrefix("Basic "),
                      "scheme must be the first token in the header value")
        XCTAssertTrue(value.contains("realm=\"Admin\""),
                      "realm must reflect the provided realm argument")
    }

    // MARK: serverListenerEventPayload

    func test_listenerPayload_boundTrue_carriesAddressAndPort() {
        // WHY: on successful bind, UI/iOS must know the server is reachable
        // at a specific address:port - \"bound=true\" alone is insufficient.
        let payload = serverListenerEventPayload(bound: true, address: "127.0.0.1", port: 18217)
        XCTAssertEqual(payload["bound"] as? Bool, true,
                       "bound key must be true on successful bind")
        XCTAssertEqual(payload["address"] as? String, "127.0.0.1",
                       "address key must reflect the bind address")
        XCTAssertEqual(payload["port"] as? Int, 18217,
                       "port key must reflect the bind port")
    }

    func test_listenerPayload_boundFalse_carriesAddressAndPort() {
        // WHY: on bind failure, UI/iOS needs the attempted address+port
        // to show a useful error (e.g. \"port 18217 in use on 0.0.0.0\").
        let payload = serverListenerEventPayload(bound: false, address: "0.0.0.0", port: 9999)
        XCTAssertEqual(payload["bound"] as? Bool, false,
                       "bound key must be false on failed bind")
        XCTAssertEqual(payload["address"] as? String, "0.0.0.0",
                       "address must be the attempted bind address even on failure")
        XCTAssertEqual(payload["port"] as? Int, 9999,
                       "port must be the attempted bind port even on failure")
    }

    func test_listenerPayload_keysAreExactlyBoundAddressPort() {
        // WHY: extra keys would silently add fields to a published EventBus
        // event that iOS parses; the contract must be stable and minimal.
        let payload = serverListenerEventPayload(bound: true, address: "127.0.0.1", port: 18217)
        let keys = Set(payload.keys)
        XCTAssertEqual(keys, ["bound", "address", "port"],
                       "payload must contain exactly the three keys: bound, address, port")
    }

    // MARK: wsUpgradeRequiresToken (P1 security gate)

    func test_wsUpgrade_nonLoopback_withAuth_requiresToken() {
        // WHY (P1, worst defect found): the /v1/ws upgrade runs BEFORE the HTTP
        // auth gate and returns early. Without this gate an unauthenticated
        // non-loopback LAN peer could subscribe to /v1/ws and receive terminal
        // output, agent messages, and file-edit contents. On a LAN bind with an
        // auth provider configured, the upgrade MUST demand a valid token.
        XCTAssertTrue(
            DirectHTTPServer.wsUpgradeRequiresToken(loopbackOnly: false, hasAuthProvider: true),
            "LAN bind + auth enabled must gate /v1/ws upgrade behind a token")
    }

    func test_wsUpgrade_loopbackOnly_isOpen() {
        // WHY: loopback is trusted, matching the HTTP /v1/* gate (which skips
        // auth when bindLoopbackOnly). The loopbackOnly:true test harness relies
        // on the upgrade staying open without a token.
        XCTAssertFalse(
            DirectHTTPServer.wsUpgradeRequiresToken(loopbackOnly: true, hasAuthProvider: true),
            "loopback-only bind must NOT require a token for /v1/ws (trusted)")
    }

    func test_wsUpgrade_noAuthProvider_isOpen() {
        // WHY: a nil auth provider means auth is disabled for this server; the
        // gate must not block the upgrade when there is no token to verify
        // against, mirroring the HTTP gate's `let auth = auth` guard.
        XCTAssertFalse(
            DirectHTTPServer.wsUpgradeRequiresToken(loopbackOnly: false, hasAuthProvider: false),
            "no auth provider means /v1/ws upgrade stays open (auth disabled)")
    }

    func test_wsUpgrade_loopbackAndNoAuth_isOpen() {
        // WHY: boundary - both trust signals present; must remain open.
        XCTAssertFalse(
            DirectHTTPServer.wsUpgradeRequiresToken(loopbackOnly: true, hasAuthProvider: false),
            "loopback + no auth must remain open")
    }
}
