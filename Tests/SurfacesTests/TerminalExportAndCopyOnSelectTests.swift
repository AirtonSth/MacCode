import XCTest
@testable import Surfaces

/// Tests for two pure P3 helpers:
///   - TerminalExportHelpers.fileExtension(for:)  — export filename/extension chooser
///   - TerminalCopyOnSelect.shouldCopy(prefEnabled:hasSelection:) — copy-on-select gate
///
/// Both helpers are nonisolated static; no @MainActor is needed.
final class TerminalExportAndCopyOnSelectTests: XCTestCase {

    // MARK: - fileExtension(for:)

    func test_fileExtension_txt_returnsTxt() {
        // A "Save Output..." panel defaulting to .txt must append ".txt" so the
        // OS associates the file with a plain-text viewer, not an unknown type.
        XCTAssertEqual(
            TerminalExportHelpers.fileExtension(for: .txt),
            "txt",
            "txt format must produce extension 'txt' so the saved file opens in a text editor"
        )
    }

    func test_fileExtension_ansi_returnsAnsi() {
        // An ANSI export must carry the ".ansi" extension so tooling that reads
        // raw escape sequences (e.g. `cat`, `less -R`) can identify it; a ".txt"
        // extension would mislead viewers that strip escape sequences.
        XCTAssertEqual(
            TerminalExportHelpers.fileExtension(for: .ansi),
            "ansi",
            "ansi format must produce extension 'ansi' so the file is recognizable as an ANSI escape sequence document"
        )
    }

    // MARK: - shouldCopy(prefEnabled:hasSelection:)

    func test_shouldCopy_prefOnAndSelectionPresent_returnsTrue() {
        // The only state where copy-on-select fires: both the preference is on
        // AND the user has a live selection. Any other combination must not copy.
        XCTAssertTrue(
            TerminalCopyOnSelect.shouldCopy(prefEnabled: true, hasSelection: true),
            "copy-on-select must trigger when the preference is enabled and a selection exists"
        )
    }

    func test_shouldCopy_prefOffSelectionPresent_returnsFalse() {
        // Having a selection alone must not copy when the user has not opted in;
        // doing so would silently overwrite the pasteboard, breaking workflows
        // that rely on an explicit Cmd+C.
        XCTAssertFalse(
            TerminalCopyOnSelect.shouldCopy(prefEnabled: false, hasSelection: true),
            "copy-on-select must not fire when the preference is disabled, even if a selection exists"
        )
    }

    func test_shouldCopy_prefOnNoSelection_returnsFalse() {
        // A enabled preference without an active selection must be a no-op;
        // copying an empty selection would push an empty string to the pasteboard.
        XCTAssertFalse(
            TerminalCopyOnSelect.shouldCopy(prefEnabled: true, hasSelection: false),
            "copy-on-select must not fire when there is no selection, even if the preference is enabled"
        )
    }

    func test_shouldCopy_prefOffNoSelection_returnsFalse() {
        // Both off: clearly a no-op. Explicit guard against future regressions
        // that might treat (false, false) as an edge case.
        XCTAssertFalse(
            TerminalCopyOnSelect.shouldCopy(prefEnabled: false, hasSelection: false),
            "copy-on-select must not fire when both preference and selection are absent"
        )
    }
}
