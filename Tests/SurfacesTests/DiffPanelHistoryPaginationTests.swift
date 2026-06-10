import XCTest
@testable import Surfaces
import AgentRuntime

/// Unit tests for diff-panel history pagination, subject filter, and amend arg builder.
///
/// WHY:
/// - `historyNextLimit` must advance the git-log `-n` limit by exactly one page so
///   "Load 100 more" always fetches a strict superset of the previous window.
/// - `commitMatchesFilter` drives the subject-line filter; a bug here silently hides
///   commits from the user, so every match/no-match boundary matters.
/// - `commitArgv` builds the git CLI invocation; a wrong `--amend` flag would corrupt
///   the wrong commit or create a duplicate, so the argv contract is load-bearing.
///
/// All three helpers are `nonisolated static` — no @MainActor required.
/// The `filteredCommits` and amend-reset tests touch the view model and are @MainActor.
final class DiffPanelHistoryPaginationTests: XCTestCase {

    // MARK: - historyNextLimit

    func test_historyNextLimit_defaultPageSize_advancesBy100() {
        // WHY: the default page size is 100; tapping "Load 100 more" from the
        // initial limit of 100 must request 200 commits so a second page is included.
        let next = DiffPanelViewModel.historyNextLimit(loaded: 100)
        XCTAssertEqual(next, 200,
                       "first 'Load more' from limit 100 must request 200 — a strict superset of the initial window")
    }

    func test_historyNextLimit_subsequentPage_advancesCorrectly() {
        // WHY: repeated taps must keep advancing by the same page size so
        // every page shows exactly one new batch of commits.
        let next = DiffPanelViewModel.historyNextLimit(loaded: 200)
        XCTAssertEqual(next, 300,
                       "second 'Load more' from limit 200 must request 300")
    }

    func test_historyNextLimit_customPageSize_advancesAccordingly() {
        // WHY: the page size is injected so callers can tune it; the helper
        // must respect the parameter and not hard-code 100.
        let next = DiffPanelViewModel.historyNextLimit(loaded: 50, pageSize: 25)
        XCTAssertEqual(next, 75,
                       "custom pageSize must be honoured — next = loaded + pageSize")
    }

    func test_historyNextLimit_zeroLoaded_returnsPageSize() {
        // Edge: starting from 0 (e.g. an empty repo that just got a commit)
        // must still produce a sensible limit.
        let next = DiffPanelViewModel.historyNextLimit(loaded: 0, pageSize: 10)
        XCTAssertEqual(next, 10,
                       "starting from 0 must return pageSize so at least one page is requested")
    }

    // MARK: - commitMatchesFilter

    func test_commitMatchesFilter_emptyQuery_alwaysMatches() {
        // WHY: an empty filter must show ALL commits; otherwise the list would
        // be empty on first load before the user has typed anything.
        let commit = GitCommit(hash: "abc", shortHash: "abc", author: "a", date: "2026-01-01", subject: "fix: handle nil")
        XCTAssertTrue(DiffPanelViewModel.commitMatchesFilter(commit, query: ""),
                      "empty query must match every commit — no filter active")
    }

    func test_commitMatchesFilter_whitespaceOnlyQuery_alwaysMatches() {
        let commit = GitCommit(hash: "abc", shortHash: "abc", author: "a", date: "2026-01-01", subject: "feat: add pagination")
        XCTAssertTrue(DiffPanelViewModel.commitMatchesFilter(commit, query: "   "),
                      "whitespace-only query must be treated as empty — no filter active")
    }

    func test_commitMatchesFilter_exactSubjectMatch_returnsTrue() {
        // WHY: a user typing the exact commit subject must find it.
        let commit = GitCommit(hash: "def", shortHash: "def", author: "b", date: "2026-01-02", subject: "refactor: split helpers")
        XCTAssertTrue(DiffPanelViewModel.commitMatchesFilter(commit, query: "refactor: split helpers"),
                      "exact subject must match so the user can find a specific commit by copying its subject")
    }

    func test_commitMatchesFilter_partialMatch_returnsTrue() {
        let commit = GitCommit(hash: "ghi", shortHash: "ghi", author: "c", date: "2026-01-03", subject: "fix: pagination window")
        XCTAssertTrue(DiffPanelViewModel.commitMatchesFilter(commit, query: "pagination"),
                      "partial substring match must return true — users search by keyword, not full subject")
    }

    func test_commitMatchesFilter_caseInsensitiveMatch_returnsTrue() {
        // WHY: git subjects use mixed case; forcing the user to match case exactly
        // would make the filter feel broken.
        let commit = GitCommit(hash: "jkl", shortHash: "jkl", author: "d", date: "2026-01-04", subject: "Add Amend Support")
        XCTAssertTrue(DiffPanelViewModel.commitMatchesFilter(commit, query: "amend support"),
                      "filter must be case-insensitive so lowercase queries find mixed-case subjects")
        XCTAssertTrue(DiffPanelViewModel.commitMatchesFilter(commit, query: "ADD AMEND"),
                      "uppercase query must also match lowercase portions of the subject")
    }

    func test_commitMatchesFilter_noMatch_returnsFalse() {
        // WHY: a mismatch must return false so unrelated commits are hidden,
        // otherwise the filter has no effect.
        let commit = GitCommit(hash: "mno", shortHash: "mno", author: "e", date: "2026-01-05", subject: "docs: update README")
        XCTAssertFalse(DiffPanelViewModel.commitMatchesFilter(commit, query: "login"),
                       "a query not contained in the subject must return false — commit must be hidden")
    }

    // MARK: - commitArgv

    func test_commitArgv_normalCommit_noAmendFlag() {
        // WHY: a normal commit must NOT contain --amend, otherwise we would
        // silently rewrite the previous commit when the user intended a fresh one.
        let argv = DiffPanelViewModel.commitArgv(message: "feat: add search", amend: false)
        XCTAssertFalse(argv.contains("--amend"),
                       "normal commit argv must not include --amend so a fresh commit is created")
        XCTAssertTrue(argv.contains("-m"),
                      "commit argv must include -m so the message is passed to git")
        XCTAssertTrue(argv.contains("feat: add search"),
                      "commit argv must include the exact message string")
    }

    func test_commitArgv_normalCommit_startsWithCommit() {
        let argv = DiffPanelViewModel.commitArgv(message: "fix: typo", amend: false)
        XCTAssertEqual(argv.first, "commit",
                       "argv must start with 'commit' so it is a valid git subcommand")
    }

    func test_commitArgv_amendCommit_containsAmendFlag() {
        // WHY: --amend must appear in the argv so git rewrites HEAD instead of
        // creating a new commit. Its absence would silently create a duplicate.
        let argv = DiffPanelViewModel.commitArgv(message: "fix: corrected message", amend: true)
        XCTAssertTrue(argv.contains("--amend"),
                      "amend argv must contain --amend so git rewrites HEAD")
        XCTAssertTrue(argv.contains("-m"),
                      "amend argv must also include -m so the new message is applied")
        XCTAssertTrue(argv.contains("fix: corrected message"),
                      "amend argv must carry the updated message text")
    }

    func test_commitArgv_amendCommit_amendAppearsBeforeMessage() {
        // WHY: git commit accepts --amend before -m. Validate relative order
        // so the invocation is syntactically correct.
        let argv = DiffPanelViewModel.commitArgv(message: "msg", amend: true)
        let amendIdx = argv.firstIndex(of: "--amend")
        let mIdx = argv.firstIndex(of: "-m")
        XCTAssertNotNil(amendIdx, "--amend must be present")
        XCTAssertNotNil(mIdx, "-m must be present")
        if let a = amendIdx, let m = mIdx {
            XCTAssertLessThan(a, m, "--amend must precede -m so git parses the flags correctly")
        }
    }

    func test_commitArgv_message_isVerbatim() {
        // WHY: the message must not be trimmed, escaped, or transformed by this
        // helper — the caller owns sanitization; the helper only composes argv.
        let msg = "  leading space "
        let argv = DiffPanelViewModel.commitArgv(message: msg, amend: false)
        XCTAssertTrue(argv.contains(msg),
                      "commitArgv must pass the message verbatim — sanitization is the caller's responsibility")
    }

    // MARK: - filteredCommits (ViewModel integration)

    @MainActor
    func test_filteredCommits_emptyFilter_returnsAll() {
        // WHY: before the user types anything the history list must show every commit.
        let vm = DiffPanelViewModel(cwd: "/tmp")
        vm.commits = [
            GitCommit(hash: "a", shortHash: "a", author: "x", date: "2026-01-01", subject: "feat: one"),
            GitCommit(hash: "b", shortHash: "b", author: "x", date: "2026-01-02", subject: "fix: two")
        ]
        vm.historyFilter = ""
        XCTAssertEqual(vm.filteredCommits.count, 2,
                       "empty filter must return all commits — history list must not be empty by default")
    }

    @MainActor
    func test_filteredCommits_matchingFilter_returnsSubset() {
        // WHY: typing a keyword must narrow the list so the user can locate commits quickly.
        let vm = DiffPanelViewModel(cwd: "/tmp")
        vm.commits = [
            GitCommit(hash: "a", shortHash: "a", author: "x", date: "2026-01-01", subject: "feat: pagination"),
            GitCommit(hash: "b", shortHash: "b", author: "x", date: "2026-01-02", subject: "fix: crash"),
            GitCommit(hash: "c", shortHash: "c", author: "x", date: "2026-01-03", subject: "feat: load more pagination")
        ]
        vm.historyFilter = "pagination"
        let result = vm.filteredCommits
        XCTAssertEqual(result.count, 2,
                       "filter 'pagination' must match exactly the two pagination-related commits")
        XCTAssertTrue(result.allSatisfy { $0.subject.localizedCaseInsensitiveContains("pagination") },
                      "all returned commits must contain the filter query in their subject")
    }

    @MainActor
    func test_filteredCommits_noMatch_returnsEmpty() {
        // WHY: a query that matches nothing must return an empty list so the view
        // can show the "No matches" empty state — not a stale prior result.
        let vm = DiffPanelViewModel(cwd: "/tmp")
        vm.commits = [
            GitCommit(hash: "a", shortHash: "a", author: "x", date: "2026-01-01", subject: "feat: one"),
        ]
        vm.historyFilter = "xyzzy-no-match"
        XCTAssertTrue(vm.filteredCommits.isEmpty,
                      "a non-matching filter must produce an empty list so the empty state is shown")
    }

    // MARK: - amendLastCommit reset behaviour

    @MainActor
    func test_amendLastCommit_defaultsFalse() {
        // WHY: the checkbox must default to unchecked so users are never
        // surprised by an accidental amend on their first commit.
        let vm = DiffPanelViewModel(cwd: "/tmp")
        XCTAssertFalse(vm.amendLastCommit,
                       "amendLastCommit must default to false — accidental amend on first commit would destroy work")
    }

    @MainActor
    func test_commitArgv_amendFalse_vs_true_differ() {
        // WHY: the argv for a normal commit and an amend commit must differ by
        // exactly the --amend flag so that the two paths are never conflated.
        let normal = DiffPanelViewModel.commitArgv(message: "msg", amend: false)
        let amend = DiffPanelViewModel.commitArgv(message: "msg", amend: true)
        XCTAssertNotEqual(normal, amend,
                          "normal and amend argv must differ — they invoke distinct git behaviours")
        XCTAssertEqual(amend.filter { $0 == "--amend" }.count, 1,
                       "--amend must appear exactly once in the amend argv to avoid duplicate flags")
    }
}
