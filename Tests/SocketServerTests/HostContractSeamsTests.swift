import XCTest
@testable import SocketServer

/// Unit tests for the pure host-contract seam introduced in :23.
///
/// WHY: these seams are the authoritative source of the iOS↔macOS wire contract
/// for pairing error codes. Testing it in isolation
/// means a regression (wrong code, missing field, renamed key) fails immediately
/// without spinning up a live socket, so the iOS team can rely on the pinned
/// shapes being stable.
final class HostContractSeamsTests: XCTestCase {

    // MARK: - :23  pairingErrorPayload

    /// WHY: `pairing_disabled` is the PINNED code iOS uses to distinguish
    /// "this Mac cannot pair at all" from "your code is bad". Wrong or absent
    /// code means iOS shows a generic error instead of actionable guidance
    /// ("contact admin" vs "try again").
    func test_pairingErrorPayload_pairingDisabled_pinnedCode() {
        let p = pairingErrorPayload(code: "pairing_disabled")
        let error = p["error"] as? [String: Any]
        XCTAssertNotNil(error, "response must have top-level 'error' key")
        XCTAssertEqual(error?["code"] as? String, "pairing_disabled",
            "pinned machine code 'pairing_disabled' must be present so iOS can distinguish disabled vs expired (:23)")
    }

    /// WHY: `code_expired` covers both "expired" and "already redeemed" --
    /// the PINNED code iOS switches on to show a re-pair CTA. Any drift here
    /// means iOS sees an unrecognised code and falls back to a generic error.
    func test_pairingErrorPayload_codeExpired_pinnedCode() {
        let p = pairingErrorPayload(code: "code_expired")
        let error = p["error"] as? [String: Any]
        XCTAssertNotNil(error, "response must have top-level 'error' key")
        XCTAssertEqual(error?["code"] as? String, "code_expired",
            "pinned machine code 'code_expired' must be present so iOS can show a targeted re-pair CTA (:23)")
    }

    /// WHY: `message` is required so iOS can display a human string without
    /// a client-side string table for every host error code. Absent = blank
    /// UI; wrong type = crash in iOS string interpolation.
    func test_pairingErrorPayload_hasNonEmptyMessage() {
        for code in ["pairing_disabled", "code_expired", "code_invalid"] {
            let p = pairingErrorPayload(code: code)
            let msg = (p["error"] as? [String: Any])?["message"] as? String
            XCTAssertNotNil(msg,
                "pairingErrorPayload('\(code)') must include a 'message' field for iOS UI display (:23)")
            XCTAssertFalse(msg?.isEmpty == true,
                "message for '\(code)' must be non-empty")
        }
    }

    /// WHY: the JSON shape is `{"error":{"code":...,"message":...}}`.
    /// Any structural change (e.g. flat `{"code":...}`) breaks iOS parsing.
    /// Asserting the exact nesting guards the contract shape in one place.
    func test_pairingErrorPayload_shape_matchesContract() {
        let p = pairingErrorPayload(code: "pairing_disabled")
        // Must have exactly one top-level key: "error"
        XCTAssertEqual(p.keys.count, 1, "pairingErrorPayload must have exactly one top-level key 'error'")
        let error = p["error"] as? [String: Any]
        XCTAssertNotNil(error, "top-level value must be a dictionary")
        // Inner dict must contain exactly "code" and "message"
        let keys = Set((error ?? [:]).keys)
        XCTAssertTrue(keys.contains("code"), "error object must contain 'code'")
        XCTAssertTrue(keys.contains("message"), "error object must contain 'message'")
    }

    /// WHY: unknown error codes must not crash. Future codes emitted by new
    /// auth-provider paths must still produce a valid, non-empty payload.
    func test_pairingErrorPayload_unknownCode_fallsBackGracefully() {
        let p = pairingErrorPayload(code: "future_pairing_error")
        let error = p["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "future_pairing_error",
            "unknown code must be forwarded verbatim in the error.code field")
        let msg = error?["message"] as? String
        XCTAssertNotNil(msg, "unknown code must still produce a non-nil message")
        XCTAssertFalse(msg?.isEmpty == true, "unknown code message must be non-empty")
    }
}
