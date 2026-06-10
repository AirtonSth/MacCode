import XCTest
import CoreModel
@testable import Surfaces

/// Tests for the per-workspace WKWebsiteDataStore isolation helper.
///
/// WHY: Cookies and logins must not bleed across workspaces. Each workspace
/// must receive its own persistent WKWebsiteDataStore. The helper
/// `dataStoreIdentifier(for:)` is the seam that encodes this contract;
/// if it ever returns the same value for two distinct workspace IDs, or
/// changes the value for the same ID, isolation silently breaks.
///
/// Pure helper is `nonisolated static` so no @MainActor needed here.
final class BrowserSurfaceDataStoreTests: XCTestCase {

    // MARK: Stability

    func test_sameWorkspaceID_producesSameIdentifier() {
        // WHY: WKWebsiteDataStore(forIdentifier:) creates / reopens the same
        // on-disk store when given the same UUID. If the mapping is not
        // deterministic a workspace would get a fresh (empty) store on every
        // app launch and logins would be lost.
        let id = WorkspaceID(UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000001")!)
        let first  = BrowserSurface.dataStoreIdentifier(for: id)
        let second = BrowserSurface.dataStoreIdentifier(for: id)

        XCTAssertEqual(first, second,
                       "same workspace id must always map to the same data-store identifier")
    }

    // MARK: Isolation

    func test_distinctWorkspaceIDs_produceDistinctIdentifiers() {
        // WHY: Two workspaces sharing one identifier would share cookies/logins,
        // violating the per-workspace isolation contract.
        let alpha = WorkspaceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
        let beta  = WorkspaceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)

        let idAlpha = BrowserSurface.dataStoreIdentifier(for: alpha)
        let idBeta  = BrowserSurface.dataStoreIdentifier(for: beta)

        XCTAssertNotEqual(idAlpha, idBeta,
                          "distinct workspace ids must map to distinct data-store identifiers to prevent cookie bleed-over")
    }

    // MARK: Valid UUID

    func test_identifier_isValidUUID() {
        // WHY: WKWebsiteDataStore(forIdentifier:) requires a non-nil UUID value;
        // an all-zero or nil-derived UUID would crash or silently fall back to
        // the default shared store.
        let id = WorkspaceID()
        let identifier = BrowserSurface.dataStoreIdentifier(for: id)

        // UUID is a value type and is always non-nil. Verify it is non-zero
        // (all-zero UUIDs are considered nil-equivalent by some WebKit versions).
        let allZeroUUID = UUID(uuid: (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0))
        XCTAssertNotEqual(identifier, allZeroUUID,
                          "data-store identifier must be a valid non-zero UUID")

        // Round-trips through uuidString to confirm it is a well-formed UUID.
        let roundTripped = UUID(uuidString: identifier.uuidString)
        XCTAssertNotNil(roundTripped,
                        "data-store identifier uuidString must round-trip to a valid UUID")
        XCTAssertEqual(identifier, roundTripped!,
                       "round-tripped UUID must equal the original identifier")
    }

    // MARK: Derivation from workspace value

    func test_identifierMatchesWorkspaceUUIDValue() {
        // WHY: The simplest safe mapping is workspace.value -> identifier directly.
        // This test encodes that invariant explicitly so any future change to
        // the mapping (e.g. adding a namespace hash) must be a conscious decision
        // and must update this test with a documented reason.
        let raw = UUID(uuidString: "CAFEBABE-CAFE-BABE-CAFE-BABECAFEBABE")!
        let workspaceID = WorkspaceID(raw)

        let identifier = BrowserSurface.dataStoreIdentifier(for: workspaceID)

        XCTAssertEqual(identifier, raw,
                       "data-store identifier must equal the workspace UUID value so store location on disk is predictable and stable across launches")
    }
}
