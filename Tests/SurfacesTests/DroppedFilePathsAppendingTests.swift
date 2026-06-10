import XCTest
import AppKit
@testable import Surfaces

/// Tests for DroppedFilePaths pure helpers (T065/T066).
///
/// WHY: appending() must place exactly one space between the existing text
/// and the inserted paths. If it inserts two spaces (text already ends in
/// space) or zero spaces (text non-empty, no separator), the prompt
/// rendered to the composer is malformed and paths are joined incorrectly.
/// canReadFileDrop is the gate for whether the drag-accept operation is
/// offered; a false negative silently disables file drop for users.
final class DroppedFilePathsAppendingTests: XCTestCase {

    // MARK: - appending() whitespace rules

    // WHY: when the existing prompt text ends without a space the appended
    // paths must get exactly one space separator. Without it the first path
    // is concatenated onto the last word of the prompt, producing garbage.
    func test_appending_toNonEmptyTextWithoutTrailingSpace_addsSingleSpace() {
        let result = DroppedFilePaths.appending("/tmp/file.txt", to: "Hello")
        XCTAssertEqual(result, "Hello /tmp/file.txt",
                       "one space must be added between prompt and inserted path")
    }

    // WHY: when the existing prompt text already ends in whitespace adding
    // another space would double-space the prompt, which looks wrong in the
    // composer and can confuse downstream argument parsing.
    func test_appending_toTextWithTrailingSpace_doesNotDoubleSpace() {
        let result = DroppedFilePaths.appending("/tmp/file.txt", to: "Hello ")
        XCTAssertEqual(result, "Hello /tmp/file.txt",
                       "must not add an extra space when the text already ends in space")
    }

    // WHY: empty existing text means the insertion becomes the entire prompt
    // content. Prepending a space would produce " /tmp/file.txt" which is
    // not a valid path (leading space).
    func test_appending_toEmptyText_returnsInsertionOnly() {
        let result = DroppedFilePaths.appending("/tmp/file.txt", to: "")
        XCTAssertEqual(result, "/tmp/file.txt",
                       "empty existing text must produce insertion without a leading space")
    }

    // WHY: an empty insertion must be a no-op regardless of existing text.
    // Adding an empty string to a prompt must not append a trailing space or
    // change the prompt at all.
    func test_appending_emptyInsertion_returnsOriginalText() {
        let result = DroppedFilePaths.appending("", to: "Hello")
        XCTAssertEqual(result, "Hello",
                       "empty insertion must return original text unchanged")
    }

    func test_appending_emptyInsertionToEmptyText_returnsEmpty() {
        let result = DroppedFilePaths.appending("", to: "")
        XCTAssertEqual(result, "",
                       "empty + empty must produce empty string")
    }

    // WHY: a newline at the end of text is whitespace; same rule as trailing
    // space: the insertion must not be double-separated.
    func test_appending_toTextWithTrailingNewline_doesNotAddSpace() {
        let result = DroppedFilePaths.appending("/a/b", to: "cmd\n")
        XCTAssertEqual(result, "cmd\n/a/b",
                       "trailing newline counts as whitespace; no extra space should be added")
    }

    // MARK: - canReadFileDrop (T065)

    // WHY: canReadFileDrop is the gate for accepting a drag-operation.
    // A false negative means the drop target shows no-drop cursor and the
    // user cannot drag files at all -- a hard-to-diagnose UX break.
    func test_canReadFileDrop_withFileURLObject_returnsTrue() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/test.txt")])
        XCTAssertTrue(DroppedFilePaths.canReadFileDrop(from: pasteboard),
                      "a pasteboard with a file URL object must be accepted as a file drop")
    }

    func test_canReadFileDrop_withFileURLString_returnsTrue() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("file:///tmp/test.txt", forType: .fileURL)
        XCTAssertTrue(DroppedFilePaths.canReadFileDrop(from: pasteboard),
                      "a pasteboard with a file:// URL string must be accepted as a file drop")
    }

    func test_canReadFileDrop_emptyPasteboard_returnsFalse() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertFalse(DroppedFilePaths.canReadFileDrop(from: pasteboard),
                       "an empty pasteboard must not be accepted as a file drop")
    }

    func test_canReadFileDrop_plainTextOnly_returnsFalse() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("hello world", forType: .string)
        XCTAssertFalse(DroppedFilePaths.canReadFileDrop(from: pasteboard),
                       "a plain-text pasteboard must not be accepted as a file drop")
    }

    // MARK: - triple-representation dedupe (T066)

    // WHY: a drag from Finder can place the same file URL in three pasteboard
    // representations (.fileURL object, .fileURL string, NSFilenamesPboardType).
    // Without deduplication the surface receives the same path three times and
    // pastes the same path three times into the terminal or composer.
    func test_paths_tripleRepresentation_deduplicatesToOnePath() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        // Write the same path via the NSURL object API (covers .fileURL type).
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/dedup.txt")])
        // Also write via the string type (second representation).
        pasteboard.addTypes([.fileURL], owner: nil)
        pasteboard.setString("file:///tmp/dedup.txt", forType: .fileURL)

        let paths = DroppedFilePaths.paths(from: pasteboard)
        let unique = Set(paths)
        XCTAssertEqual(unique.count, 1,
                       "the same path appearing in multiple pasteboard representations must be deduplicated to one entry")
        XCTAssertEqual(paths.first, "/tmp/dedup.txt")
    }

    // MARK: - composerInputText (no shell escaping)

    // WHY: composerInputText is used in the AI composer text field where paths
    // are passed as human-readable context, not shell arguments. Shell-escaping
    // them would surround paths in quotes that the AI model would read literally.
    func test_composerInputText_joinsWithSpaceNoEscaping() {
        let text = DroppedFilePaths.composerInputText(for: ["/tmp/a.txt", "/home/user/my file.txt"])
        XCTAssertEqual(text, "/tmp/a.txt /home/user/my file.txt",
                       "composerInputText must join paths with a space and must NOT shell-escape them")
    }

    // MARK: - terminalInputText shell-escaping

    // WHY: terminal input is sent to a shell. Paths with spaces must be
    // shell-escaped so the shell does not split them into multiple tokens.
    // A missing shell-escape causes "cp /my file.txt /dest" to be parsed
    // as "cp /my file.txt /dest" -> four arguments.
    func test_terminalInputText_pathWithSpace_isSingleQuoted() {
        let text = DroppedFilePaths.terminalInputText(for: ["/home/user/my file.txt"])
        XCTAssertEqual(text, "'/home/user/my file.txt'",
                       "path with space must be single-quoted for safe shell insertion")
    }

    func test_terminalInputText_plainPath_isNotQuoted() {
        let text = DroppedFilePaths.terminalInputText(for: ["/tmp/plain.txt"])
        XCTAssertEqual(text, "/tmp/plain.txt",
                       "plain ASCII path with no special chars must not be quoted")
    }
}
