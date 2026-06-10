import XCTest
@testable import AppShell

/// Tests for the database-open failure alert copy.
///
/// WHY: The previous behavior showed a raw Swift error string as the alert
/// body — "SQLiteError(code: 14, ...)" — which gives the user no actionable
/// guidance. The fix replaces it with human copy explaining where the database
/// lives and how to recover. These tests pin the contract so the copy cannot
/// silently regress back to a raw error dump.
///
///   R1 — The text includes the support directory path so the user knows
///         exactly where to look.
///   R2 — The text includes "remotecode.sqlite" so the user knows which
///         file to delete.
///   R3 — The text includes ".corrupt-<date>" to hint that a quarantined
///         backup may be present.
///   R4 — The text includes the error description so support can diagnose
///         without reading logs.
///   R5 — The helper is nonisolated (no @MainActor, no AppKit) so it is
///         safe to call from any context.
final class DBOpenFailureCopyTests: XCTestCase {

    private let sampleDir = "/Users/test/Library/Application Support/RemoteCode"
    private let sampleError = "The file could not be opened for reading and writing."

    // MARK: - R1: path included

    func test_informativeText_containsSupportDir() {
        let text = AppDelegate.dbOpenFailureInformativeText(
            supportDir: sampleDir,
            errorDescription: sampleError
        )
        XCTAssertTrue(text.contains(sampleDir),
            "the failure copy must contain the support directory path " +
            "so the user knows which folder to open — omitting it leaves them guessing")
    }

    // MARK: - R2: sqlite file name mentioned

    func test_informativeText_mentionsSQLiteFile() {
        let text = AppDelegate.dbOpenFailureInformativeText(
            supportDir: sampleDir,
            errorDescription: sampleError
        )
        XCTAssertTrue(text.contains("remotecode.sqlite"),
            "the failure copy must name the SQLite file so the user knows which " +
            "file to delete during recovery — generic 'database file' is not actionable")
    }

    // MARK: - R3: backup hint present

    func test_informativeText_mentionsCorruptBackup() {
        let text = AppDelegate.dbOpenFailureInformativeText(
            supportDir: sampleDir,
            errorDescription: sampleError
        )
        XCTAssertTrue(text.contains(".corrupt-"),
            "the copy must hint that a quarantined backup may exist with a " +
            "\".corrupt-\" suffix so users know their data is not permanently lost")
    }

    // MARK: - R4: technical detail included

    func test_informativeText_containsErrorDescription() {
        let text = AppDelegate.dbOpenFailureInformativeText(
            supportDir: sampleDir,
            errorDescription: sampleError
        )
        XCTAssertTrue(text.contains(sampleError),
            "the error description must appear verbatim so support staff can " +
            "diagnose the root cause from a screenshot without needing the log file")
    }

    // MARK: - R4: never the raw Swift error type name

    func test_informativeText_doesNotContainRawErrorType() {
        // Regression guard: the old copy printed e.g. "SQLiteError(code: 14, ...)"
        // which is incomprehensible to end users.
        let rawErrorDump = "SQLiteError(code:"
        let text = AppDelegate.dbOpenFailureInformativeText(
            supportDir: sampleDir,
            errorDescription: sampleError
        )
        XCTAssertFalse(text.contains(rawErrorDump),
            "the copy must not expose raw Swift error type names — " +
            "a user reading 'SQLiteError(code: 14)' has no idea what to do")
    }
}
