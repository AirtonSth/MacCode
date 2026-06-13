import XCTest
import CoreImage
@testable import AppShell

/// Unit tests for `PairingQRPayload`.
///
/// WHY these tests exist: the payload string is a contract between the macOS
/// QR renderer and the iOS scanner. Any accidental change to the scheme, host
/// name, query-key names, or parameter order will silently make every phone
/// fail to parse the QR at first-run — the exact failure mode this feature
/// exists to eliminate. These tests pin the contract so a format change is
/// immediately caught.
///
/// Tests are pure (no AppKit, no I/O, no MainActor) and run in any context.
final class PairingQRPayloadTests: XCTestCase {

    // MARK: - buildPayload

    /// WHY: the scheme must be `remotecode` so the iOS deep-link handler
    /// recognises the URL and routes it to the pairing flow. A generic `https`
    /// or a typo silently falls through to Safari and no pairing occurs.
    func test_buildPayload_schemeIsRemotecode() {
        let url = PairingQRPayload.buildPayload(
            code: "ABC123", host: "mymac.local", port: 18217, serverId: "srv-1"
        )
        XCTAssertTrue(url.hasPrefix("remotecode://"),
            "payload must start with 'remotecode://' so the iOS deep-link handler " +
            "recognises it; any other scheme silently routes to Safari and drops the pair")
    }

    /// WHY: `host=pair` is the authority component that signals the iOS scanner
    /// this URL encodes pairing info vs. any future remotecode:// deep links.
    func test_buildPayload_hostIsPair() {
        let url = PairingQRPayload.buildPayload(
            code: "ABC123", host: "mymac.local", port: 18217, serverId: "srv-1"
        )
        XCTAssertTrue(url.hasPrefix("remotecode://pair"),
            "authority must be 'pair' to distinguish the pairing deep-link from " +
            "future remotecode:// schemes (e.g. remotecode://session)")
    }

    /// WHY: the iOS scanner must be able to extract `code` by name. If the key
    /// changes (e.g., to `pairing_code`) parsing fails and the phone cannot
    /// authenticate the pairing request.
    func test_buildPayload_containsCodeParam() {
        let url = PairingQRPayload.buildPayload(
            code: "ABC123", host: "mymac.local", port: 18217, serverId: "srv-1"
        )
        XCTAssertTrue(url.contains("code=ABC123"),
            "payload must contain 'code=<CODE>' so the iOS scanner can locate the " +
            "short-lived pairing secret by its canonical query-key name")
    }

    /// WHY: the iOS scanner needs `host` to open the TCP connection; without it
    /// the phone has no address to dial and cannot reach the Mac's HTTP server.
    func test_buildPayload_containsHostParam() {
        let url = PairingQRPayload.buildPayload(
            code: "ABC123", host: "mymac.local", port: 18217, serverId: "srv-1"
        )
        XCTAssertTrue(url.contains("host=mymac.local"),
            "payload must contain 'host=<HOST>' so the iOS scanner can open the TCP " +
            "connection to the Mac without requiring the user to type the IP manually")
    }

    /// WHY: the iOS scanner needs `port` to connect to the correct listener.
    /// If port is omitted it defaults to 80/443 and connection fails.
    func test_buildPayload_containsPortParam() {
        let url = PairingQRPayload.buildPayload(
            code: "ABC123", host: "mymac.local", port: 18217, serverId: "srv-1"
        )
        XCTAssertTrue(url.contains("port=18217"),
            "payload must contain 'port=18217' so the iOS scanner dials the correct " +
            "listener port; omitting it causes the connection to fall back to HTTP/80")
    }

    /// WHY: the iOS scanner uses `server_id` to verify it is talking to the same
    /// Mac it expects (identity pin, RCA-022). If the key is absent or renamed
    /// the pin check silently passes on any server, defeating the trust model.
    func test_buildPayload_containsServerIdParam() {
        let url = PairingQRPayload.buildPayload(
            code: "ABC123", host: "mymac.local", port: 18217, serverId: "srv-1"
        )
        XCTAssertTrue(url.contains("server_id=srv-1"),
            "payload must contain 'server_id=<ID>' so the iOS scanner can verify " +
            "the identity pin (RCA-022); a missing key makes every server appear trusted")
    }

    /// WHY: special characters in serverId (e.g., UUID with hyphens) must not
    /// break URL parsing on the iOS side. URLComponents percent-encodes them;
    /// this test guards against dropping encoding.
    func test_buildPayload_uuidServerId_isWellFormed() throws {
        let uuid = "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"
        let url = PairingQRPayload.buildPayload(
            code: "XYZ789", host: "mymac.local", port: 18217, serverId: uuid
        )
        // Must be parseable as a URL (not crash or produce garbage).
        let parsed = URL(string: url)
        XCTAssertNotNil(parsed,
            "payload must be a valid URL even when serverId contains hyphens (UUID format); " +
            "an unparseable URL silently makes iOS scanning fail with no error")
        let comps = try XCTUnwrap(URLComponents(url: parsed!, resolvingAgainstBaseURL: false))
        let serverIdItem = comps.queryItems?.first { $0.name == "server_id" }
        XCTAssertEqual(serverIdItem?.value, uuid,
            "server_id value must round-trip through URL encoding/decoding unchanged; " +
            "corruption here breaks the identity pin on the iOS side")
    }

    /// WHY: an empty serverId (fallback when server_id was not yet written to
    /// settings) must still produce a well-formed payload rather than crashing.
    /// The code is still usable for manual pairing; the server_id check degrades
    /// gracefully on old hosts that haven't persisted the key yet.
    func test_buildPayload_emptyServerId_stillWellFormed() {
        let url = PairingQRPayload.buildPayload(
            code: "ABC123", host: "mymac.local", port: 18217, serverId: ""
        )
        XCTAssertFalse(url.isEmpty,
            "payload must be non-empty even with an empty serverId; " +
            "an empty string would crash the QR generator with zero-byte input")
        XCTAssertNotNil(URL(string: url),
            "payload must be a valid URL even with an empty serverId " +
            "so the iOS scanner can still attempt the connection")
    }

    // MARK: - Security: no long-lived secret in payload

    /// WHY: the QR must encode ONLY the short-lived pairing code plus connection
    /// coordinates. Embedding any bearer token or long-lived credential would let
    /// anyone who photographs the QR gain permanent access. The pairing code
    /// expires in 600 s and is single-use; that is the intended security boundary.
    func test_buildPayload_doesNotContainToken() {
        // Simulate a fake token that must never appear in the payload.
        let fakeToken = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let url = PairingQRPayload.buildPayload(
            code: "ABC123", host: "mymac.local", port: 18217, serverId: "srv-1"
        )
        XCTAssertFalse(url.contains(fakeToken),
            "payload must never embed a bearer token or long-lived secret; " +
            "only the short-lived pairing code is the security boundary")
        // Also verify no 'token' query key appears.
        XCTAssertFalse(url.contains("token="),
            "payload query must not contain a 'token' key; " +
            "any long-lived credential in the QR breaks the security boundary")
    }

    // MARK: - qrCIImage

    /// WHY: if `qrCIImage` returns nil for a non-empty payload the QR view
    /// silently shows nothing — the user sees no QR and cannot scan. Confirming
    /// a non-nil result for a typical payload guards this code path.
    func test_qrCIImage_nonEmptyPayload_returnsImage() {
        let payload = PairingQRPayload.buildPayload(
            code: "ABC123", host: "mymac.local", port: 18217, serverId: "srv-1"
        )
        let image = PairingQRPayload.qrCIImage(payload: payload)
        XCTAssertNotNil(image,
            "qrCIImage must return a non-nil CIImage for a valid payload; " +
            "nil here means the view shows nothing and the user cannot scan to pair")
    }

    /// WHY: the QR pixel grid must be square (equal width and height). A
    /// non-square QR image would render distorted, making it unscannable.
    func test_qrCIImage_outputIsSquare() throws {
        let payload = PairingQRPayload.buildPayload(
            code: "ABC123", host: "mymac.local", port: 18217, serverId: "srv-1"
        )
        let image = try XCTUnwrap(PairingQRPayload.qrCIImage(payload: payload),
            "must produce a CIImage for a standard pairing payload")
        let extent = image.extent
        XCTAssertEqual(extent.width, extent.height, accuracy: 0.5,
            "QR image extent must be square; a non-square image renders distorted " +
            "and most scanner apps will refuse to decode it")
    }
}
