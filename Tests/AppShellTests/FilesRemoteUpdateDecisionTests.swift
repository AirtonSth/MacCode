import XCTest
@testable import AppShell

/// WHY (UX-MAC_FILES remote-edit conflict): a remote edit must never silently
/// clobber the user's in-progress local typing. `filesRemoteUpdateDecision` is the
/// single authoritative gate that determines whether an incoming remote edit is
/// applied immediately or held back to preserve the local draft.
///
/// Failure modes prevented:
/// - .apply when localDirty=true + texts differ => user loses mid-type work.
/// - .conflictKeepLocal when not dirty => unnecessary conflict notice for clean files.
/// - .conflictKeepLocal when remote==local and dirty => spurious conflict when
///   both sides converged on the same content.
final class FilesRemoteUpdateDecisionTests: XCTestCase {

    // MARK: - Not dirty

    /// WHY: when the user has no local edits the remote version is authoritative;
    /// applying it immediately is always safe and must not show a conflict notice.
    func test_notDirty_alwaysApply() {
        let decision = filesRemoteUpdateDecision(
            localDirty: false,
            localText: "hello",
            remoteText: "hello world",
            lastSyncedText: "hello"
        )
        XCTAssertEqual(decision, .apply,
            "not-dirty: remote edit must be applied without a conflict notice")
    }

    /// WHY: even if the remote text is completely different, a clean local editor
    /// has no in-progress work to protect; applying immediately is correct.
    func test_notDirty_remoteCompletelyDifferent_apply() {
        let decision = filesRemoteUpdateDecision(
            localDirty: false,
            localText: "line one",
            remoteText: "totally different content",
            lastSyncedText: "line one"
        )
        XCTAssertEqual(decision, .apply,
            "not-dirty + diverged remote: must still apply since there is no local work to protect")
    }

    // MARK: - Dirty, remote equals local

    /// WHY: if the user typed the same characters the remote also produced, there
    /// is no real conflict -- the state has converged. Applying is safe and avoids
    /// a spurious conflict banner that would confuse the user.
    func test_dirty_remoteEqualsLocal_apply() {
        let decision = filesRemoteUpdateDecision(
            localDirty: true,
            localText: "same content",
            remoteText: "same content",
            lastSyncedText: "base"
        )
        XCTAssertEqual(decision, .apply,
            "dirty + remote==local: content converged, no conflict notice needed")
    }

    // MARK: - Dirty, remote differs from local

    /// WHY: the user is mid-edit and the remote version differs -- this is the
    /// exact scenario that would silently destroy the user's work. The decision
    /// must be conflictKeepLocal so the local draft is preserved.
    func test_dirty_remoteDiffers_conflictKeepLocal() {
        let decision = filesRemoteUpdateDecision(
            localDirty: true,
            localText: "my local draft",
            remoteText: "remote version",
            lastSyncedText: "base"
        )
        XCTAssertEqual(decision, .conflictKeepLocal,
            "dirty + remote!=local: local draft must be protected; remote must NOT overwrite it")
    }

    /// WHY: even a single-character difference in the remote while the user is
    /// typing must trigger conflict protection. A missed character would be a
    /// data-loss bug for the user.
    func test_dirty_remoteDiffersByOneChar_conflictKeepLocal() {
        let decision = filesRemoteUpdateDecision(
            localDirty: true,
            localText: "hello world",
            remoteText: "hello World",
            lastSyncedText: "hello"
        )
        XCTAssertEqual(decision, .conflictKeepLocal,
            "dirty + single-char difference: conflict must fire; local draft preserved")
    }

    /// WHY: empty remote arriving while the user has local edits must also conflict-protect.
    /// Silently emptying the file while someone is typing would be catastrophic.
    func test_dirty_remoteEmpty_conflictKeepLocal() {
        let decision = filesRemoteUpdateDecision(
            localDirty: true,
            localText: "important draft",
            remoteText: "",
            lastSyncedText: "important draft"
        )
        XCTAssertEqual(decision, .conflictKeepLocal,
            "dirty + remote cleared the file: must protect local draft, not silently delete it")
    }
}
