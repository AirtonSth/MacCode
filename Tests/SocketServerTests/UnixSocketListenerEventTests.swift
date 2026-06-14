import XCTest
@testable import SocketServer

/// Tests that UnixSocketServer publishes `server.listener` EventBus events on
/// both success and failure paths.
///
/// WHY: AppDelegate (and any future observer) must be able to subscribe to
/// `server.listener` events and surface server-start failures in the UI
/// instead of silently logging them. Without these events the app violates
/// Rule-6 (fail loud) for a path that makes the local `rc2` CLI and all
/// remote access dead.
final class UnixSocketListenerEventTests: XCTestCase {

    // MARK: - Pure helper: unixSocketListenerEventPayload

    func testPayloadBoundTrue_hasCorrectShape() {
        let p = unixSocketListenerEventPayload(bound: true, path: "/tmp/test.sock")
        XCTAssertEqual(p["bound"] as? Bool, true,
                       "bound=true must be set so subscribers distinguish up from down")
        XCTAssertEqual(p["address"] as? String, "/tmp/test.sock",
                       "address must be the socket path for diagnostic display")
        XCTAssertEqual(p["port"] as? Int, 0,
                       "port must be 0 for a Unix-domain socket (no TCP port)")
    }

    func testPayloadBoundFalse_hasCorrectShape() {
        let p = unixSocketListenerEventPayload(bound: false, path: "/var/run/dead.sock")
        XCTAssertEqual(p["bound"] as? Bool, false,
                       "bound=false must be set so the UI can show a failure banner")
        XCTAssertEqual(p["address"] as? String, "/var/run/dead.sock",
                       "address must reflect the failed path for diagnostics")
        XCTAssertEqual(p["port"] as? Int, 0)
    }

    // MARK: - EventBus integration: success path

    @MainActor
    func testStart_publishesListenerEvent_boundTrue() throws {
        let shortID = UUID().uuidString.prefix(8)
        let socketURL = URL(fileURLWithPath: "/tmp/rc2-ok-\(shortID).sock")
        defer {
            if FileManager.default.fileExists(atPath: socketURL.path) {
                try? FileManager.default.removeItem(at: socketURL)
            }
        }

        let startSeq = EventBus.shared.snapshot().lastSeq
        var received: [EventBus.Event] = []
        let subID = EventBus.shared.subscribe(since: startSeq) { ev in
            if ev.kind == "server.listener" { received.append(ev) }
        }
        defer { EventBus.shared.unsubscribe(subID) }

        let server = UnixSocketServer(
            socketPath: socketURL.path,
            dispatcher: JSONRPCDispatcher(router: FakeRouter())
        )
        try server.start()
        defer { server.stop() }

        // Publish is synchronous inside start(), so no sleep needed.
        XCTAssertFalse(received.isEmpty,
                       "start() must publish server.listener so callers can observe bind status without polling")
        guard let first = received.first else { return }
        guard case .object(let payload) = first.payload else {
            return XCTFail("server.listener payload must be a JSON object")
        }
        XCTAssertEqual(payload["bound"], .bool(true),
                       "successful bind must report bound=true so the UI shows a green status")
        XCTAssertEqual(payload["port"], .number(0),
                       "Unix socket port must always be 0 (no TCP port)")
        if case .string(let addr) = payload["address"] {
            XCTAssertEqual(addr, socketURL.path,
                           "address must match the socket path so diagnostics show the right location")
        } else {
            XCTFail("address key must be a string in the server.listener payload")
        }
    }

    // MARK: - EventBus integration: failure path (too-long path)

    @MainActor
    func testStart_publishesNoSuccessEvent_whenPathTooLong() throws {
        // A path longer than UNIX_PATH_MAX (104 on Darwin) triggers
        // the path-too-long guard before bind(2) is called.
        let longPath = "/tmp/" + String(repeating: "a", count: 200) + ".sock"

        let startSeq = EventBus.shared.snapshot().lastSeq
        var received: [EventBus.Event] = []
        let subID = EventBus.shared.subscribe(since: startSeq) { ev in
            if ev.kind == "server.listener" { received.append(ev) }
        }
        defer { EventBus.shared.unsubscribe(subID) }

        let server = UnixSocketServer(
            socketPath: longPath,
            dispatcher: JSONRPCDispatcher(router: FakeRouter())
        )
        XCTAssertThrowsError(try server.start(),
                             "start() must throw when the socket path is too long")

        // The too-long-path error is thrown before bind(2), so the server
        // never reaches the failure-publish path. Crucially, it must NOT
        // emit bound=true (which would mislead observers into thinking the
        // server is up).
        let falsePositives = received.filter {
            guard case .object(let p) = $0.payload else { return false }
            return p["bound"] == .bool(true)
        }
        XCTAssertTrue(falsePositives.isEmpty,
                      "a failed start must never publish bound=true; that would show wrong server status")
    }

    // MARK: - EventBus integration: failure path (bind error)

    @MainActor
    func testStart_publishesListenerEvent_boundFalse_onBindFailure() throws {
        // Use a path whose *parent directory does not exist* so bind(2) fails
        // with ENOENT. start() calls unlink() first (which silently fails on a
        // missing parent), then tries bind(2) which returns -1.
        let missingParent = "/tmp/rc2-no-such-dir-\(UUID().uuidString)/test.sock"

        let startSeq = EventBus.shared.snapshot().lastSeq
        var received: [EventBus.Event] = []
        let subID = EventBus.shared.subscribe(since: startSeq) { ev in
            if ev.kind == "server.listener" { received.append(ev) }
        }
        defer { EventBus.shared.unsubscribe(subID) }

        let server = UnixSocketServer(
            socketPath: missingParent,
            dispatcher: JSONRPCDispatcher(router: FakeRouter())
        )
        XCTAssertThrowsError(try server.start(),
                             "start() must throw when bind(2) fails due to missing parent directory")

        // A bound=false event must have been published so the caller can
        // surface the failure in the UI instead of silently ignoring it.
        let failures = received.filter {
            guard case .object(let p) = $0.payload else { return false }
            return p["bound"] == .bool(false)
        }
        XCTAssertFalse(failures.isEmpty,
                       "bind failure must publish server.listener with bound=false so the UI can show a banner")

        // Confirm the address in the event matches the attempted path.
        if let failEvent = failures.first,
           case .object(let p) = failEvent.payload,
           case .string(let addr) = p["address"] {
            XCTAssertEqual(addr, missingParent,
                           "failure event address must reflect the attempted socket path for diagnostics")
        }
    }
}
