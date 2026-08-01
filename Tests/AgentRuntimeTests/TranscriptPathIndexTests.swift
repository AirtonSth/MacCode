import XCTest
@testable import AgentRuntime

/// Tests for TranscriptPathIndex — the pure in-memory cache that maps
/// providerThreadId -> transcript file URL so ClaudeTranscriptStore avoids
/// re-enumerating ~/.claude/projects on every readSession call.
///
/// Concurrency of the shared store's path cache is covered by
/// ClaudeTranscriptStoreReadSessionTests.test_readSession_concurrentPathResolution_doesNotCorruptCache
/// (the index itself is intentionally not thread-safe).
final class TranscriptPathIndexTests: XCTestCase {

    // MARK: - set then get returns the stored path

    func test_setThenGet_returnsStoredPath() {
        // WHY: primary contract — a resolved path must survive round-trip so
        //      the next readSession call skips filesystem enumeration.
        var index = TranscriptPathIndex()
        let url = URL(fileURLWithPath: "/home/.claude/projects/p/abc123.jsonl")
        index.setPath(url, forProviderThreadId: "abc123")
        XCTAssertEqual(index.path(forProviderThreadId: "abc123"), url)
    }

    // MARK: - miss returns nil

    func test_get_unknownId_returnsNil() {
        // WHY: a cold-cache miss must return nil so the store falls back to
        //      filesystem enumeration — a stale "found" result would skip the
        //      enumeration and silently return no transcript.
        let index = TranscriptPathIndex()
        XCTAssertNil(index.path(forProviderThreadId: "does-not-exist"))
    }

    // MARK: - distinct ids are isolated

    func test_distinctIds_areIsolated() {
        // WHY: two concurrent sessions must not bleed paths into each other;
        //      a lookup for id-A must not return the path stored for id-B.
        var index = TranscriptPathIndex()
        let urlA = URL(fileURLWithPath: "/projects/a/thread-a.jsonl")
        let urlB = URL(fileURLWithPath: "/projects/b/thread-b.jsonl")
        index.setPath(urlA, forProviderThreadId: "thread-a")
        index.setPath(urlB, forProviderThreadId: "thread-b")
        XCTAssertEqual(index.path(forProviderThreadId: "thread-a"), urlA)
        XCTAssertEqual(index.path(forProviderThreadId: "thread-b"), urlB)
    }

    // MARK: - overwrite updates the stored path

    func test_overwrite_updatesPath() {
        // WHY: if a transcript file moves (e.g. project folder renamed) the
        //      index must accept a corrected path and serve the new location,
        //      not the stale one, so recovery stays correct after re-resolution.
        var index = TranscriptPathIndex()
        let old = URL(fileURLWithPath: "/old/thread.jsonl")
        let new = URL(fileURLWithPath: "/new/thread.jsonl")
        index.setPath(old, forProviderThreadId: "thread-x")
        index.setPath(new, forProviderThreadId: "thread-x")
        XCTAssertEqual(index.path(forProviderThreadId: "thread-x"), new)
    }

    // MARK: - empty string id is not cached

    func test_emptyId_isNotCached() {
        // WHY: ClaudeTranscriptStore guards against empty providerThreadId;
        //      the index must not silently cache an empty-key entry that could
        //      be retrieved by the guard-bypass path.
        var index = TranscriptPathIndex()
        let url = URL(fileURLWithPath: "/projects/empty.jsonl")
        index.setPath(url, forProviderThreadId: "")
        XCTAssertNil(index.path(forProviderThreadId: ""))
    }
}
