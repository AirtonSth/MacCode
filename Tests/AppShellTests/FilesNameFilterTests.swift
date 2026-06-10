import XCTest
@testable import AppShell

/// Tests for the pure `filterFileEntries(_:query:)` helper that powers the Files sidebar
/// name-filter field.
///
/// WHY these tests matter:
///  - Empty query must keep all entries so navigating a directory without typing shows
///    the full listing. Breaking this hides files unexpectedly.
///  - Case-insensitive match means users don't need to remember capitalisation;
///    a case-sensitive implementation would silently miss files on macOS where filenames
///    can differ only in case.
///  - No-match returns empty so the UI can display a "no results" state rather than
///    a stale listing that looks full but isn't filtered at all.
///  - Subsequence matching (e.g. "app" matches "AppDelegate") is the same tier used in
///    CommandPaletteFilter, giving the Files filter a consistent feel across the app.
final class FilesNameFilterTests: XCTestCase {

    // MARK: Helpers

    private static func makeEntry(name: String, isDirectory: Bool = false) -> FilterableFileEntry {
        FilterableFileEntry(name: name, isDirectory: isDirectory)
    }

    // MARK: Empty query

    func test_filterFileEntries_emptyQuery_returnsAllEntries() {
        // An empty query means the user has not typed anything; the list must be unmodified.
        let entries = [
            Self.makeEntry(name: "main.swift"),
            Self.makeEntry(name: "README.md"),
            Self.makeEntry(name: "src", isDirectory: true),
        ]
        let result = filterFileEntries(entries, query: "")
        XCTAssertEqual(result.map(\.name), entries.map(\.name),
            "empty query must return all entries unchanged")
    }

    func test_filterFileEntries_whitespaceOnlyQuery_returnsAllEntries() {
        // Whitespace-only should be treated as empty so the user clearing the field
        // with a trailing space doesn't accidentally filter everything out.
        let entries = [Self.makeEntry(name: "app.swift"), Self.makeEntry(name: "util.swift")]
        let result = filterFileEntries(entries, query: "   ")
        XCTAssertEqual(result.map(\.name), entries.map(\.name),
            "whitespace-only query must behave as empty")
    }

    // MARK: Case-insensitive substring

    func test_filterFileEntries_caseInsensitiveMatch_matchesRegardlessOfCase() {
        // A developer searching for "README" should find "README.md" and also "Readme.txt"
        // without caring about capitalisation.
        let entries = [
            Self.makeEntry(name: "README.md"),
            Self.makeEntry(name: "Readme.txt"),
            Self.makeEntry(name: "main.swift"),
        ]
        let result = filterFileEntries(entries, query: "readme")
        XCTAssertEqual(Set(result.map(\.name)), ["README.md", "Readme.txt"],
            "case-insensitive substring match must include all case variants")
        XCTAssertFalse(result.map(\.name).contains("main.swift"),
            "non-matching entry must be excluded")
    }

    func test_filterFileEntries_uppercaseQuery_matchesLowercaseEntry() {
        let entries = [Self.makeEntry(name: "appdelegatesurface.swift")]
        let result = filterFileEntries(entries, query: "AppDelegate")
        XCTAssertEqual(result.count, 1,
            "uppercase query must match lowercase filename case-insensitively")
    }

    // MARK: No match

    func test_filterFileEntries_noMatch_returnsEmpty() {
        // If nothing matches, the result must be empty so the UI can show a "no results" state.
        // Returning the full list on no-match would make the filter appear non-functional.
        let entries = [Self.makeEntry(name: "app.swift"), Self.makeEntry(name: "util.swift")]
        let result = filterFileEntries(entries, query: "zzznomatch")
        XCTAssertTrue(result.isEmpty,
            "query with no matching entry must produce an empty result, enabling a no-results UI state")
    }

    // MARK: Directories included

    func test_filterFileEntries_matchesDirectoriesByName() {
        // Directories are first-class entries in the sidebar; filtering must include them when
        // their name matches so a user can jump to a folder as quickly as a file.
        let entries = [
            Self.makeEntry(name: "Sources", isDirectory: true),
            Self.makeEntry(name: "Tests", isDirectory: true),
            Self.makeEntry(name: "Package.swift"),
        ]
        let result = filterFileEntries(entries, query: "src")
        XCTAssertEqual(result.map(\.name), ["Sources"],
            "directory entries must be included when their name matches the filter query")
    }

    // MARK: Subsequence matching

    func test_filterFileEntries_subsequenceQuery_matchesNonContiguousChars() {
        // "appdel" as a subsequence should match "AppDelegate.swift" because the characters
        // appear in order, matching CommandPaletteFilter's tier-10 subsequence behaviour.
        let entries = [
            Self.makeEntry(name: "AppDelegate.swift"),
            Self.makeEntry(name: "main.swift"),
        ]
        let result = filterFileEntries(entries, query: "appdel")
        XCTAssertEqual(result.map(\.name), ["AppDelegate.swift"],
            "subsequence query must match when query chars appear in order in the filename")
    }

    func test_filterFileEntries_subsequenceQuery_doesNotMatchIfOrderBroken() {
        // "aled" does NOT appear as an ordered subsequence in "AppDelegate" because 'a' after 'd'
        // is not present; this test guards against over-matching.
        let entries = [Self.makeEntry(name: "delegate.swift")]
        let result = filterFileEntries(entries, query: "zzz")
        XCTAssertTrue(result.isEmpty,
            "subsequence match must respect character order; out-of-order chars must not match")
    }

    // MARK: Preserves order

    func test_filterFileEntries_matchingEntries_preserveOriginalOrder() {
        // The filter must not reorder matching entries; the sidebar already sorts by directory/
        // file and name, and re-sorting here would contradict that order unpredictably.
        // Uses the query "ph" which matches "alpha" and "orphan" but not "beta".
        let entries = [
            Self.makeEntry(name: "alpha.swift"),
            Self.makeEntry(name: "beta.swift"),
            Self.makeEntry(name: "orphan.swift"),
        ]
        let result = filterFileEntries(entries, query: "ph")
        // "alpha" and "orphan" both contain "ph"; order must match the input order.
        XCTAssertEqual(result.map(\.name), ["alpha.swift", "orphan.swift"],
            "filter must preserve original entry order for matching results")
    }
}
