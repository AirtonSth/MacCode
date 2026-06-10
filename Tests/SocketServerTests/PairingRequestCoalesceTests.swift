import XCTest
@testable import SocketServer
@testable import Persistence

/// P3 - Coalesce duplicate pairing requests from the same device name within TTL.
///
/// WHY each assertion encodes intent (Rule 8):
///   - same name within TTL -> coalesce: a device that re-connects before the
///     existing request expires must reuse the outstanding request so the Mac
///     user sees exactly one modal, not one per reconnect. A regression here
///     restores the flood-of-modals bug.
///   - same name past TTL -> new: once the TTL window closes the old request is
///     stale (may be expired/decided); a fresh connection deserves a fresh
///     request. Coalescing onto a stale row would either block approval forever
///     or hand the device the wrong status.
///   - different name -> new: two distinct devices must each get their own
///     request and modal. Merging them would let one device silently inherit
///     another device's approval decision.
///   - non-pending status is never coalesced: an approved or denied request must
///     not be reused; the device should get a new request so the user can make
///     a fresh decision.
final class PairingRequestCoalesceTests: XCTestCase {

    // MARK: - Helpers

    private func makeRequest(
        id: String = UUID().uuidString,
        deviceName: String,
        createdAt: Date,
        ttl: TimeInterval = 300,
        status: String = "pending"
    ) -> PairingRequest {
        PairingRequest(
            id: id,
            code: "000000",
            deviceName: deviceName,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(ttl),
            status: status,
            deviceID: nil,
            decidedAt: nil
        )
    }

    // MARK: - Core coalesce logic

    func test_sameDeviceName_withinTTL_returnsExistingRequest() {
        // WHY: device re-connects within the TTL; must reuse outstanding request
        // so the user sees at most one modal per pairing attempt.
        let anchor = Date()
        let existing = makeRequest(deviceName: "iPhone", createdAt: anchor)
        let now = anchor.addingTimeInterval(100) // 100 s < 300 s TTL

        let result = coalescePairingRequest(
            deviceName: "iPhone",
            outstanding: [existing],
            now: now,
            ttl: 300
        )

        XCTAssertEqual(result?.id, existing.id,
                       "same device name within TTL must coalesce onto the existing request")
    }

    func test_sameDeviceName_exactlyAtTTLBoundary_returnsNil() {
        // WHY: at exactly TTL seconds the window is closed (< not <=); the
        // existing request must NOT be reused so the device gets a fresh one.
        let anchor = Date()
        let existing = makeRequest(deviceName: "iPhone", createdAt: anchor)
        let now = anchor.addingTimeInterval(300) // exactly == TTL

        let result = coalescePairingRequest(
            deviceName: "iPhone",
            outstanding: [existing],
            now: now,
            ttl: 300
        )

        XCTAssertNil(result,
                     "request at exactly TTL boundary must not be coalesced (window is strictly less-than)")
    }

    func test_sameDeviceName_pastTTL_returnsNil() {
        // WHY: stale request must not be reused; a new connection after expiry
        // deserves a new modal so the user can make a fresh approval decision.
        let anchor = Date()
        let existing = makeRequest(deviceName: "iPhone", createdAt: anchor)
        let now = anchor.addingTimeInterval(400) // 400 s > 300 s TTL

        let result = coalescePairingRequest(
            deviceName: "iPhone",
            outstanding: [existing],
            now: now,
            ttl: 300
        )

        XCTAssertNil(result,
                     "same device name past TTL must not coalesce; stale request must not be reused")
    }

    func test_differentDeviceName_returnsNil() {
        // WHY: two distinct devices must each get their own request; coalescing
        // across device names would grant device B the approval meant for device A.
        let anchor = Date()
        let existing = makeRequest(deviceName: "iPhone", createdAt: anchor)
        let now = anchor.addingTimeInterval(50) // well within TTL

        let result = coalescePairingRequest(
            deviceName: "iPad",
            outstanding: [existing],
            now: now,
            ttl: 300
        )

        XCTAssertNil(result,
                     "different device name must never coalesce onto another device's request")
    }

    func test_emptyOutstanding_returnsNil() {
        // WHY: no outstanding requests means no candidate to coalesce onto;
        // a new request must always be created.
        let result = coalescePairingRequest(
            deviceName: "iPhone",
            outstanding: [],
            now: Date(),
            ttl: 300
        )

        XCTAssertNil(result, "empty outstanding list must always return nil")
    }

    // MARK: - Status filtering

    func test_approvedRequest_notCoalesced() {
        // WHY: an already-approved request must not be reused; the device
        // would poll its status and see approval even though the user approved
        // an older connection attempt.
        let anchor = Date()
        let approved = makeRequest(deviceName: "iPhone", createdAt: anchor, status: "approved")
        let now = anchor.addingTimeInterval(50)

        let result = coalescePairingRequest(
            deviceName: "iPhone",
            outstanding: [approved],
            now: now,
            ttl: 300
        )

        XCTAssertNil(result,
                     "approved request must not be coalesced; only pending requests are reusable")
    }

    func test_deniedRequest_notCoalesced() {
        // WHY: a denied request must not be reused; the device would inherit a
        // denial that the user intended for a previous connection attempt.
        let anchor = Date()
        let denied = makeRequest(deviceName: "iPhone", createdAt: anchor, status: "denied")
        let now = anchor.addingTimeInterval(50)

        let result = coalescePairingRequest(
            deviceName: "iPhone",
            outstanding: [denied],
            now: now,
            ttl: 300
        )

        XCTAssertNil(result,
                     "denied request must not be coalesced; only pending requests are reusable")
    }

    // MARK: - Multiple outstanding requests

    func test_multipleOutstanding_returnsCorrectDeviceRequest() {
        // WHY: when multiple devices have outstanding requests, only the one
        // matching the incoming device name must be returned; returning the
        // wrong device's request would route the approval to the wrong device.
        let anchor = Date()
        let phoneReq  = makeRequest(id: "req-phone",  deviceName: "iPhone", createdAt: anchor)
        let tabletReq = makeRequest(id: "req-tablet", deviceName: "iPad",   createdAt: anchor)
        let now = anchor.addingTimeInterval(50)

        let phoneResult = coalescePairingRequest(
            deviceName: "iPhone",
            outstanding: [phoneReq, tabletReq],
            now: now,
            ttl: 300
        )
        let tabletResult = coalescePairingRequest(
            deviceName: "iPad",
            outstanding: [phoneReq, tabletReq],
            now: now,
            ttl: 300
        )

        XCTAssertEqual(phoneResult?.id, "req-phone",
                       "must return the matching device's request, not the other device's")
        XCTAssertEqual(tabletResult?.id, "req-tablet",
                       "must return the matching device's request, not the other device's")
    }

    func test_mixedStatus_onlyPendingIsCoalesced() {
        // WHY: a list with both an approved (old) and a pending (fresh) request
        // for the same device must coalesce onto the pending one only; the
        // approved one is already decided and must not be reused.
        let anchor = Date()
        let old     = makeRequest(id: "req-old",  deviceName: "iPhone", createdAt: anchor, status: "approved")
        let fresh   = makeRequest(id: "req-fresh", deviceName: "iPhone",
                                  createdAt: anchor.addingTimeInterval(10), status: "pending")
        let now = anchor.addingTimeInterval(50)

        let result = coalescePairingRequest(
            deviceName: "iPhone",
            outstanding: [old, fresh],
            now: now,
            ttl: 300
        )

        XCTAssertEqual(result?.id, "req-fresh",
                       "must coalesce onto the pending request, not the already-approved one")
    }

    func test_zeroTTL_neverCoalesces() {
        // WHY: a TTL of 0 means the window is always closed; every request
        // must be treated as fresh regardless of outstanding requests.
        let anchor = Date()
        let existing = makeRequest(deviceName: "iPhone", createdAt: anchor)
        let now = anchor // same instant

        let result = coalescePairingRequest(
            deviceName: "iPhone",
            outstanding: [existing],
            now: now,
            ttl: 0
        )

        XCTAssertNil(result, "TTL=0 must never coalesce (window is always closed)")
    }
}
