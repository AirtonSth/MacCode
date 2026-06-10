import XCTest
@testable import AppShell

/// Tests for CLIPathCommitPolicy.shouldApply(old:new:committed:).
///
/// Business rule: mid-edit keystrokes must NOT trigger saveCLIPath /
/// replaceProviderAdapter. Only a committed (end-editing) value that actually
/// differs from the last-persisted value should be applied.
final class CLIPathCommitPolicyTests: XCTestCase {

    // MARK: - mid-edit: committed == false

    /// Keystroke while user is still typing must not apply, even if value differs.
    func test_midEdit_doesNotApply() {
        XCTAssertFalse(
            CLIPathCommitPolicy.shouldApply(old: "/usr/local/bin/claude", new: "/usr/local/bin/claud", committed: false),
            "Mid-edit draft must not apply: wiring a half-typed path into the live coordinator corrupts the session"
        )
    }

    /// Blank mid-edit value must not apply either.
    func test_midEdit_emptyNew_doesNotApply() {
        XCTAssertFalse(
            CLIPathCommitPolicy.shouldApply(old: "/usr/bin/codex", new: "", committed: false),
            "Clearing the field mid-edit must not apply: user may still be typing"
        )
    }

    // MARK: - end-editing: committed == true, value changed

    /// Pressing Return (committed) with a new path should apply.
    func test_committed_differentValue_applies() {
        XCTAssertTrue(
            CLIPathCommitPolicy.shouldApply(old: "/usr/local/bin/claude", new: "/opt/homebrew/bin/claude", committed: true),
            "A committed, different path must apply so the user's change is persisted"
        )
    }

    /// Browse-picker result (committed) should apply.
    func test_committed_newPath_fromPicker_applies() {
        XCTAssertTrue(
            CLIPathCommitPolicy.shouldApply(old: "", new: "/Applications/MyTool.app/Contents/MacOS/mytool", committed: true),
            "A picker-selected path is always committed and must apply"
        )
    }

    // MARK: - end-editing: committed == true, value unchanged

    /// Pressing Return without changing the text must NOT re-save / re-wire.
    func test_committed_sameValue_doesNotApply() {
        XCTAssertFalse(
            CLIPathCommitPolicy.shouldApply(old: "/usr/bin/codex", new: "/usr/bin/codex", committed: true),
            "Re-committing the same path must be a no-op: no DB write, no adapter replacement"
        )
    }

    /// Committed empty -> empty (no path configured) should not apply.
    func test_committed_bothEmpty_doesNotApply() {
        XCTAssertFalse(
            CLIPathCommitPolicy.shouldApply(old: "", new: "", committed: true),
            "Committed empty-to-empty must be a no-op"
        )
    }
}
