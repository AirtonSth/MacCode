import XCTest
import CoreModel
@testable import AppShell

/// Tests for the `detachedFrameAutosaveName(workspaceID:)` pure helper.
///
/// WHY these tests matter:
///   - Stability: AppKit silently creates a different NSUserDefaults key each
///     time the name changes, so the frame is never found; the user sees the
///     window re-centred on every open despite having moved it.
///   - Uniqueness: two workspaces with the same name would share one key,
///     meaning one workspace overrides the other's saved position.
///   - No collision with main window: the main window uses the key
///     "io.remotecode.mainWindow"; a collision would corrupt its frame.
///
/// All assertions are against the pure helper only -- no AppKit calls, no
/// @MainActor required, no flakiness.
final class DetachedFrameAutosaveNameTests: XCTestCase {

    // MARK: - Stability

    func test_stability_sameIDReturnsSameName() {
        let id = WorkspaceID(UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!)
        let first  = detachedFrameAutosaveName(workspaceID: id)
        let second = detachedFrameAutosaveName(workspaceID: id)
        XCTAssertEqual(first, second,
            "same WorkspaceID must always produce the same autosave name " +
            "so AppKit can find the persisted frame on subsequent opens")
    }

    // MARK: - Uniqueness

    func test_uniqueness_distinctIDsProduceDistinctNames() {
        let a = WorkspaceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
        let b = WorkspaceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)
        XCTAssertNotEqual(
            detachedFrameAutosaveName(workspaceID: a),
            detachedFrameAutosaveName(workspaceID: b),
            "distinct workspace IDs must map to distinct autosave names " +
            "so workspace A never restores workspace B's window frame")
    }

    // MARK: - Namespace

    func test_namespace_containsExpectedPrefix() {
        let id = WorkspaceID()
        let name = detachedFrameAutosaveName(workspaceID: id)
        XCTAssertTrue(name.hasPrefix("io.remotecode.detachedWorkspace."),
            "name must be prefixed with 'io.remotecode.detachedWorkspace.' " +
            "to avoid colliding with the main window key 'io.remotecode.mainWindow'")
    }

    func test_namespace_doesNotCollideWithMainWindowKey() {
        // The main window autosave key is a known constant.
        let mainWindowKey = "io.remotecode.mainWindow"
        let id = WorkspaceID()
        let name = detachedFrameAutosaveName(workspaceID: id)
        XCTAssertNotEqual(name, mainWindowKey,
            "detached workspace autosave name must not equal the main window " +
            "key or AppKit would corrupt the main window's saved frame")
    }

    // MARK: - Content

    func test_content_embedsWorkspaceUUID() {
        let uuid = UUID(uuidString: "12345678-ABCD-ABCD-ABCD-1234567890AB")!
        let id = WorkspaceID(uuid)
        let name = detachedFrameAutosaveName(workspaceID: id)
        XCTAssertTrue(name.contains(uuid.uuidString),
            "the autosave name must embed the workspace UUID string so it is " +
            "stable and debuggable in NSUserDefaults")
    }
}
