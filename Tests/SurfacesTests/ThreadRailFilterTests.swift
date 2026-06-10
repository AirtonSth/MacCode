import XCTest
@testable import Surfaces
import CoreModel

/// Proves the pure thread-rail filter helper that drives search/filter above
/// the thread list. The helper is nonisolated static (no MainActor, no UI
/// types), so these tests run without the surface.
///
/// Business rule: rails with 30+ threads are unscannable. The filter must
/// reduce the visible list to threads whose title OR model contains the query,
/// case-insensitively, so users can find threads by topic or by which model
/// ran them.
final class ThreadRailFilterTests: XCTestCase {

    // MARK: helpers

    private func thread(title: String, model: String) -> AgentThread {
        AgentThread(
            workspaceId: WorkspaceID(),
            title: title,
            provider: .codex,
            model: model
        )
    }

    // MARK: tests

    func test_filter_emptyQueryKeepsAll() {
        // An empty search field must never hide threads — the rail shows
        // the full list when the user hasn't typed anything.
        let threads = [
            thread(title: "Fix login bug", model: "gpt-5.5"),
            thread(title: "Add dark mode",  model: "claude-sonnet-4-5")
        ]
        let result = AgentAppViewModel.filterThreads(threads, query: "")
        XCTAssertEqual(result.map(\.title), threads.map(\.title),
                       "empty query must keep all threads visible")
    }

    func test_filter_matchesTitle() {
        // The canonical use case: the user types part of a thread title
        // to jump directly to it without scrolling 30+ rows.
        let target = thread(title: "Refactor auth module", model: "gpt-5.5")
        let other  = thread(title: "Add dark mode",        model: "gpt-5.5")
        let result = AgentAppViewModel.filterThreads([target, other], query: "auth")
        XCTAssertEqual(result.map(\.title), ["Refactor auth module"],
                       "query matching title substring must include that thread")
    }

    func test_filter_matchesModel() {
        // Users often remember which model they used rather than the exact
        // title; filtering by model surfaces those threads immediately.
        let a = thread(title: "Task A", model: "claude-sonnet-4-5")
        let b = thread(title: "Task B", model: "gpt-5.5")
        let result = AgentAppViewModel.filterThreads([a, b], query: "claude")
        XCTAssertEqual(result.map(\.title), ["Task A"],
                       "query matching model substring must include that thread")
    }

    func test_filter_noMatchReturnsEmpty() {
        // A query that doesn't match any title or model must return nothing,
        // giving users a clear \"no results\" signal.
        let threads = [
            thread(title: "Fix login bug", model: "gpt-5.5"),
            thread(title: "Add dark mode",  model: "gpt-5.5")
        ]
        let result = AgentAppViewModel.filterThreads(threads, query: "zzznomatch")
        XCTAssertTrue(result.isEmpty,
                      "query matching nothing must return an empty list")
    }

    func test_filter_caseInsensitive() {
        // Users shouldn't need to remember capitalisation; the search must
        // match regardless of case.
        let t = thread(title: "Deploy to Production", model: "GPT-5.5")
        let result = AgentAppViewModel.filterThreads([t], query: "production")
        XCTAssertEqual(result.count, 1,
                       "filter must be case-insensitive for title match")
        let result2 = AgentAppViewModel.filterThreads([t], query: "gpt")
        XCTAssertEqual(result2.count, 1,
                       "filter must be case-insensitive for model match")
    }

    func test_filter_matchesTitleOrModel_returnsUnion() {
        // A query broad enough to match by different fields in different
        // threads must keep all of them visible.
        let a = thread(title: "Improve codex prompt",   model: "gpt-5.5")
        let b = thread(title: "Review dark mode specs", model: "codex-special")
        let c = thread(title: "Unrelated task",         model: "gpt-5.5")
        let result = AgentAppViewModel.filterThreads([a, b, c], query: "codex")
        XCTAssertEqual(Set(result.map(\.title)), Set(["Improve codex prompt", "Review dark mode specs"]),
                       "query matching title in one thread and model in another must keep both")
    }
}
