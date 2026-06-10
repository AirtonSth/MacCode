import XCTest
import Foundation
@testable import AppShell
import SocketServer

/// Tests for the direct-access configuration surface of `AppDelegate`:
/// `stableServerId` (T020), the Bonjour TXT record (T021), and the GAP-5
/// auth-provider retention regression (T019).
///
/// WHY these matter:
///   T020 — the server id is the identity the iOS client pins (RCA-022). If an
///          empty persisted value were treated as valid, the pin would key on
///          "" and every device would have to re-pair; if it were non-stable
///          across launches the same break would happen on every restart.
///   T021 — the Bonjour TXT record is the *only* data the iOS client reads
///          before connecting. A dropped/renamed key makes this Mac silently
///          undiscoverable or mis-identified on the LAN.
///   T019 — `DirectHTTPServer.auth` is declared `weak` (HTTPServer.swift:150).
///          The app delegate is therefore the *sole* strong owner of the auth
///          provider. If that strong reference is ever dropped or weakened, the
///          provider deallocates the instant launch returns and pairing AND the
///          LAN auth gate silently break. This file pins that ownership.
final class DirectAccessConfigTests: XCTestCase {

    // MARK: - T020: stableServerId pure decision (AppDelegate.swift:443-460)

    func test_resolveServerId_returnsPersistedWhenPresent() {
        // A non-empty persisted id must always win so the identity stays stable
        // across launches (GAP-2): re-minting on each restart would force the
        // iOS identity pin to invalidate and re-pair every time.
        let result = AppDelegate.resolveServerId(persisted: "ABC-123", fresh: "FRESH-999")
        XCTAssertEqual(result, "ABC-123",
            "a non-empty persisted server_id must be reused verbatim; minting a " +
            "fresh one despite a stored value would break the RCA-022 identity pin")
    }

    func test_resolveServerId_ignoresEmptyPersisted() {
        // Empty string is NOT a valid identity. Treating "" as valid would pin
        // the client to the empty id and silently break auth/identity matching.
        let result = AppDelegate.resolveServerId(persisted: "", fresh: "FRESH-999")
        XCTAssertEqual(result, "FRESH-999",
            "an empty persisted value must be treated as missing so the caller " +
            "mints a real id; keying identity on \"\" would silently break pairing")
    }

    func test_resolveServerId_ignoresNilPersisted() {
        // No stored value yet (first launch) -> caller must mint a fresh id.
        let result = AppDelegate.resolveServerId(persisted: nil, fresh: "FRESH-999")
        XCTAssertEqual(result, "FRESH-999",
            "with no persisted id the fresh mint must be used so a first launch " +
            "still publishes a stable identity")
    }

    func test_resolveServerId_isDeterministicForSameInput() {
        // Determinism: identical input must yield identical output, otherwise the
        // published server id could differ between two reads in the same launch.
        let a = AppDelegate.resolveServerId(persisted: "STABLE-ID", fresh: nil)
        let b = AppDelegate.resolveServerId(persisted: "STABLE-ID", fresh: nil)
        XCTAssertEqual(a, b, "same persisted input must resolve to the same id every time")
        XCTAssertEqual(a, "STABLE-ID")
    }

    func test_resolveServerId_differsForDifferentInput() {
        // Two different Macs (different persisted ids) must resolve to different
        // ids so the iOS client can tell them apart on the same LAN.
        let macA = AppDelegate.resolveServerId(persisted: "MAC-A", fresh: nil)
        let macB = AppDelegate.resolveServerId(persisted: "MAC-B", fresh: nil)
        XCTAssertNotEqual(macA, macB,
            "distinct persisted ids must resolve distinctly so two Macs are not " +
            "collapsed into one identity on the LAN")
    }

    // MARK: - T021: Bonjour TXT record builder (AppDelegate.swift:1010-1024)

    func test_bonjourTXTRecord_hasExactExpectedKeys() {
        // The iOS client reads these keys by name before connecting. Pin the
        // exact set so a rename/drop fails loudly instead of making this Mac
        // undiscoverable or mis-identified.
        let txt = AppDelegate.bonjourTXTRecord(serverId: "SID-1", version: "1.2.3")
        XCTAssertEqual(Set(txt.keys), ["server_id", "app", "version", "api"],
            "TXT record must carry exactly server_id/app/version/api; any extra " +
            "or missing key changes what the iOS discovery layer parses")
    }

    func test_bonjourTXTRecord_encodesValuesAsUTF8() {
        // Values must be the UTF-8 bytes of each field exactly as setTXTRecord
        // requires; a wrong encoding would surface as garbage in the iOS list.
        let txt = AppDelegate.bonjourTXTRecord(serverId: "SID-1", version: "1.2.3")
        XCTAssertEqual(txt["server_id"], Data("SID-1".utf8),
            "server_id must carry the stable id so the client can match the device")
        XCTAssertEqual(txt["app"], Data("remotecode".utf8),
            "app tag must be the literal 'remotecode' so non-RemoteCode services are filtered out")
        XCTAssertEqual(txt["version"], Data("1.2.3".utf8),
            "version must be the running build's short version for the pre-connect display")
        XCTAssertEqual(txt["api"], Data("2".utf8),
            "api must be '2' so the client can gate on protocol compatibility before connecting")
    }

    func test_bonjourTXTRecord_threadsServerIdAndVersionThrough() {
        // The builder must use its arguments, not constants: a regression that
        // hardcoded the id/version would publish the wrong identity for every Mac.
        let txt = AppDelegate.bonjourTXTRecord(serverId: "OTHER-SID", version: "9.9.9")
        XCTAssertEqual(txt["server_id"], Data("OTHER-SID".utf8),
            "server_id value must come from the argument, not a hardcoded constant")
        XCTAssertEqual(txt["version"], Data("9.9.9".utf8),
            "version value must come from the argument, not a hardcoded constant")
    }

    // MARK: - T019 / GAP-5: auth provider strong-retention regression

    @MainActor
    func test_retainAuthProvider_keepsProviderAliveAfterLocalRefDropped() {
        // GAP-5 regression. Production assigns the auth provider via
        // `retainAuthProvider` (AppDelegate.swift:153) and the only strong owner
        // is `AppDelegate.authProvider`. Here we hand the delegate a provider,
        // drop our own strong reference, and confirm the delegate still holds it.
        // If `authProvider` is ever changed to weak/unowned (or the assignment
        // removed), this assertion flips to false and the test FAILS loud.
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.authProviderIsRetained,
            "a fresh delegate must not yet retain any auth provider")

        autoreleasepool {
            let provider = MockAuthProvider()
            delegate.retainAuthProvider(provider)
            // `provider` is the only other strong ref; it goes out of scope here.
        }

        XCTAssertTrue(delegate.authProviderIsRetained,
            "after retainAuthProvider, the delegate must still strongly hold the " +
            "provider even though every other strong reference was dropped — " +
            "DirectHTTPServer.auth is weak, so losing this owner silently disables pairing")
    }

    @MainActor
    func test_weakAuthRefDeallocatesWithoutStrongOwner_documentsGAP5() {
        // Documents the exact bug class GAP-5 guards against: a weak reference
        // (mirroring DirectHTTPServer.auth) does NOT keep a provider alive on its
        // own. This is why AppDelegate.authProvider MUST be a strong owner.
        let holder = WeakAuthHolder()
        autoreleasepool {
            let provider = MockAuthProvider()
            holder.auth = provider
            XCTAssertNotNil(holder.auth,
                "while a strong ref exists the weak holder still sees the provider")
        }
        XCTAssertNil(holder.auth,
            "with no strong owner the weakly-held provider deallocates — exactly the " +
            "silent pairing break GAP-5 prevents by retaining authProvider strongly")
    }
}

/// Mirrors `DirectHTTPServer.auth` (weak var) so the GAP-5 documentation test
/// exercises real ARC weak-reference behavior without the full HTTP stack.
private final class WeakAuthHolder {
    weak var auth: DirectAuthProvider?
}

/// Minimal `DirectAuthProvider` stand-in. Only object lifetime matters for
/// these tests, so every method returns a trivial/empty value.
private final class MockAuthProvider: DirectAuthProvider {
    func verify(token: String) -> Bool { false }
    func createPairingCode() -> String? { nil }
    func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? { nil }
    func createPairingRequest(deviceName: String) -> (requestId: String, code: String)? { nil }
    func createPairingRequest(deviceName: String, privateAccountAccessToken: String?) -> (requestId: String, code: String)? { nil }
    func pairingRequestStatus(requestId: String) -> (status: String, deviceId: String?, token: String?)? { nil }
    func cancelPairingRequest(requestId: String) -> Bool { false }
    func listDevices() -> [[String: Any]] { [] }
    func revokeDevice(_ id: String) {}
}
