import XCTest
@testable import AgentRuntime
import CoreModel

/// Concurrent stress coverage for the shared Claude transcript path cache.
///
/// WHY: production crashed (SIGABRT) when concurrent cooperative tasks hit
/// `ClaudeTranscriptStore.readSession` → `TranscriptPathIndex.setPath` without
/// synchronization (`Dictionary._Variant.setValue` corruption during thread
/// select / session recovery). These tests drive the **shipped** store on one
/// shared instance — not a re-implementation of the cache.
final class ClaudeTranscriptStoreConcurrencyTests: XCTestCase {

    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-transcript-conc-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTranscript(projectsRoot: URL, threadId: String, marker: String) throws {
        try fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        let obj: [String: Any] = [
            "type": "assistant",
            "uuid": "msg-\(threadId)",
            "message": [
                "id": "msg-\(threadId)",
                "content": [["type": "text", "text": marker]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: projectsRoot.appendingPathComponent(threadId + ".jsonl"))
    }

    // MARK: - Concurrent path-index set/get via shared store

    func test_concurrentReadSession_pathIndexSetGet_doesNotCrashAndIsolatesPaths() throws {
        // WHY: concurrent recoverSession/readThread paths populate the same
        // pathIndex; unguarded Dictionary mutation SIGABRTs. A shared store
        // must complete concurrent cold + warm reads without crash and keep
        // each providerThreadId bound to its own transcript content.
        let base = try makeTempDir()
        defer { try? fm.removeItem(at: base) }
        let projectsRoot = base.appendingPathComponent("config/projects", isDirectory: true)
        let threadCount = 24
        let threadIds = (0..<threadCount).map { "conc-thread-\($0)" }
        for (i, id) in threadIds.enumerated() {
            try writeTranscript(projectsRoot: projectsRoot, threadId: id, marker: "body-for-\(i)")
        }

        let store = ClaudeTranscriptStore(fileManager: fm)
        let env: [String: String] = [
            "CLAUDE_CONFIG_DIR": base.appendingPathComponent("config").path,
            "HOME": base.appendingPathComponent("unused-home").path
        ]

        let iterationsPerThread = 8
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "rc.transcript.conc", attributes: .concurrent)
        let resultsLock = NSLock()
        var markerByThread: [String: Set<String>] = [:]
        var failures: [String] = []

        for id in threadIds {
            for _ in 0..<iterationsPerThread {
                group.enter()
                queue.async {
                    let events = store.readSession(providerThreadId: id, environment: env)
                    let texts = events.compactMap { ev -> String? in
                        if case .itemDelta(_, let body, _, _) = ev { return body }
                        return nil
                    }
                    resultsLock.lock()
                    if texts.isEmpty {
                        failures.append("empty events for \(id)")
                    } else {
                        markerByThread[id, default: []].formUnion(texts)
                    }
                    resultsLock.unlock()
                    group.leave()
                }
            }
        }

        let waitResult = group.wait(timeout: .now() + 60)
        XCTAssertEqual(waitResult, .success, "concurrent readSession must finish without hang")
        XCTAssertTrue(failures.isEmpty, "concurrent reads failed: \(failures.prefix(5))")

        for (i, id) in threadIds.enumerated() {
            let expected = "body-for-\(i)"
            let seen = markerByThread[id] ?? []
            XCTAssertEqual(seen, [expected],
                           "path isolation: \(id) must only yield its own marker, got \(seen)")
        }
    }

    // MARK: - Concurrent same-id warm cache hits

    func test_concurrentReadSession_sameProviderId_warmCache_doesNotCrash() throws {
        // WHY: after the first resolution, many tasks hammer the cached path
        // for one id (rapid thread re-select). Concurrent get+existence-check
        // must not race setPath from a sibling cold id on the same store.
        let base = try makeTempDir()
        defer { try? fm.removeItem(at: base) }
        let projectsRoot = base.appendingPathComponent("config/projects", isDirectory: true)
        let warmId = "warm-shared"
        let coldIds = (0..<16).map { "cold-\($0)" }
        try writeTranscript(projectsRoot: projectsRoot, threadId: warmId, marker: "warm-body")
        for id in coldIds {
            try writeTranscript(projectsRoot: projectsRoot, threadId: id, marker: "cold-\(id)")
        }

        let store = ClaudeTranscriptStore(fileManager: fm)
        let env: [String: String] = [
            "CLAUDE_CONFIG_DIR": base.appendingPathComponent("config").path
        ]
        // Seed warm path once so subsequent concurrent hits use the cache.
        let seed = store.readSession(providerThreadId: warmId, environment: env)
        XCTAssertFalse(seed.isEmpty, "seed read must populate path cache")

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "rc.transcript.warm", attributes: .concurrent)
        let lock = NSLock()
        var warmBodies: [String] = []
        var coldOK = 0

        for _ in 0..<64 {
            group.enter()
            queue.async {
                let events = store.readSession(providerThreadId: warmId, environment: env)
                let texts = events.compactMap { ev -> String? in
                    if case .itemDelta(_, let body, _, _) = ev { return body }
                    return nil
                }
                lock.lock()
                warmBodies.append(contentsOf: texts)
                lock.unlock()
                group.leave()
            }
        }
        for id in coldIds {
            for _ in 0..<4 {
                group.enter()
                queue.async {
                    let events = store.readSession(providerThreadId: id, environment: env)
                    if !events.isEmpty {
                        lock.lock()
                        coldOK += 1
                        lock.unlock()
                    }
                    group.leave()
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        XCTAssertFalse(warmBodies.isEmpty)
        XCTAssertTrue(warmBodies.allSatisfy { $0 == "warm-body" },
                      "warm concurrent reads must not cross-contaminate markers")
        XCTAssertEqual(coldOK, coldIds.count * 4,
                       "cold concurrent path-index sets interleaved with warm gets must succeed")
    }

    // MARK: - Nested project path resolution under concurrency

    func test_concurrentReadSession_nestedTranscriptPaths_isolatesProviderIds() throws {
        // WHY: nested projects/*/*/*.jsonl path uses enumerator + setPath;
        // concurrent enumerators on the same store were in the crash dump
        // (Thread 2 setPath vs Thread 3 enumerator). Nested layout must stay safe.
        let base = try makeTempDir()
        defer { try? fm.removeItem(at: base) }
        let projectsRoot = base.appendingPathComponent("config/projects", isDirectory: true)
        let nestedA = projectsRoot.appendingPathComponent("proj-a/sub", isDirectory: true)
        let nestedB = projectsRoot.appendingPathComponent("proj-b/sub", isDirectory: true)
        try writeTranscript(projectsRoot: nestedA, threadId: "nested-a", marker: "nested-a-body")
        try writeTranscript(projectsRoot: nestedB, threadId: "nested-b", marker: "nested-b-body")

        let store = ClaudeTranscriptStore(fileManager: fm)
        let env: [String: String] = [
            "CLAUDE_CONFIG_DIR": base.appendingPathComponent("config").path
        ]

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "rc.transcript.nested", attributes: .concurrent)
        let lock = NSLock()
        var bodiesA: Set<String> = []
        var bodiesB: Set<String> = []

        for _ in 0..<32 {
            group.enter()
            queue.async {
                let events = store.readSession(providerThreadId: "nested-a", environment: env)
                let texts = events.compactMap { ev -> String? in
                    if case .itemDelta(_, let body, _, _) = ev { return body }
                    return nil
                }
                lock.lock()
                bodiesA.formUnion(texts)
                lock.unlock()
                group.leave()
            }
            group.enter()
            queue.async {
                let events = store.readSession(providerThreadId: "nested-b", environment: env)
                let texts = events.compactMap { ev -> String? in
                    if case .itemDelta(_, let body, _, _) = ev { return body }
                    return nil
                }
                lock.lock()
                bodiesB.formUnion(texts)
                lock.unlock()
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(bodiesA, ["nested-a-body"])
        XCTAssertEqual(bodiesB, ["nested-b-body"])
    }
}
