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

    // MARK: - Remote content update

    func test_editEventIsRemote_missingDeviceIsLocalEcho() {
        // WHY: FileEditSessionStore open/save/discard publish without
        // updated_by_device. Treating that echo as remote made Studio Files
        // say "Edited on another device" after a this-Mac New skill open.
        XCTAssertFalse(filesEditEventIsRemote(updatedByDevice: nil),
            "omitted device is the local session echo, not another device")
        XCTAssertFalse(filesEditEventIsRemote(updatedByDevice: ""),
            "empty device is the same as omitted")
        XCTAssertFalse(filesEditEventIsRemote(updatedByDevice: "mac-local"),
            "mac-local is this Mac")
        XCTAssertTrue(filesEditEventIsRemote(updatedByDevice: "ios"),
            "a present foreign device must stay remote")
        XCTAssertTrue(filesEditEventIsRemote(updatedByDevice: "mac-host"),
            "mac-host is a paired writer, not this editor")
    }

    func test_remoteContentUpdate_cleanDraftAppliesRemoteText() {
        // WHY: when there are no unsaved local edits, a remote patch from iOS should update both
        // editor and preview immediately and must not show a conflict banner.
        let update = filesRemoteContentUpdate(
            localDirty: false,
            draftText: "old",
            renderedText: "old",
            remoteText: "new from iOS",
            lastSyncedText: "old"
        )

        XCTAssertEqual(update.draftText, "new from iOS",
            "remote edit on a clean draft must replace the editor text")
        XCTAssertEqual(update.renderedText, "new from iOS",
            "remote edit on a clean draft must replace the rendered preview")
        XCTAssertNil(update.pendingRemoteText,
            "clean remote edits should apply immediately, not park pending text")
        XCTAssertFalse(update.remoteEditConflict,
            "clean remote edits must not show a conflict notice")
    }

    func test_remoteContentUpdate_dirtyDivergedDraftPreservesLocalAndParksRemote() {
        // WHY: this is the data-loss case. A remote edit arriving while the user has a different
        // unsaved draft must be held for explicit user action instead of clobbering local text.
        let update = filesRemoteContentUpdate(
            localDirty: true,
            draftText: "local unsaved",
            renderedText: "local preview",
            remoteText: "remote version",
            lastSyncedText: "base"
        )

        XCTAssertEqual(update.draftText, "local unsaved",
            "dirty divergent remote edit must preserve the local editor draft")
        XCTAssertEqual(update.renderedText, "local preview",
            "dirty divergent remote edit must preserve the current preview")
        XCTAssertEqual(update.pendingRemoteText, "remote version",
            "remote content must be parked so Load Remote can apply it explicitly")
        XCTAssertTrue(update.remoteEditConflict,
            "dirty divergent remote edit must surface the conflict banner")
    }
}
