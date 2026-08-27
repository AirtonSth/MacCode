import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: user-initiated wire retry (and live translate when run metadata is
/// gone) used to full-get 26 columns + routing JSON just to learn `provider`.
final class WireTranslateProviderChromeProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentMessageRepository,
        AgentRunRepository
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentMessageRepository(db: db),
            AgentRunRepository(db: db)
        )
    }

    func test_retryWireResponse_usesListChromeWithoutDurableGet() async throws {
        let (threadRepo, messageRepo, runRepo) = try makeRepos("wire-chrome")
        let thread = AgentThread(title: "wire", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let seen = SeenProvider()
        coordinator.finalResponseTranslator = { response, provider, _, _ in
            seen.value = provider
            return response
        }
        let getsBefore = threadRepo.durableGetCountForTesting
        let chromeBefore = threadRepo.listChromeCallCountForTesting
        let translated = await coordinator.retryWireResponse("plain", threadId: thread.id)
        XCTAssertEqual(translated, "plain")
        XCTAssertEqual(seen.value, .claude)
        XCTAssertEqual(
            threadRepo.listChromeCallCountForTesting,
            chromeBefore + 1,
            "retryWireResponse must probe listChrome once for provider"
        )
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "retryWireResponse must not compile a full 26-column get just to read provider"
        )
    }

    func test_translateWireResponse_sourceUsesListChrome() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "private func translateWireResponse("))
        let end = try XCTUnwrap(source.range(of: "private func persistMinimalCheckpointIdentity("))
        let body = String(source[range.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.listChrome(ids: [threadId])"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_wireTranslate_listChrome_fasterThanDurableGet() throws {
        let (threadRepo, _, _) = try makeRepos("wire-chrome-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try threadRepo.listChrome(ids: [thread.id])
            _ = try threadRepo.get(id: thread.id)
        }
        var chromeSamples: [Double] = []
        var getSamples: [Double] = []
        chromeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            chromeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.listChrome(ids: [thread.id])
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: thread.id)
                }
            })
        }
        let chromeMed = median(chromeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - chromeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] wire-translate listChrome_ms=%@ durable_get_ms=%@ improvement_pct=%.2f chrome=%@ get=%@",
            String(chromeMed), String(getMed), improvement,
            String(describing: chromeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "listChrome must beat durable get by ≥5% (got \(improvement)%; chrome=\(chromeMed)ms get=\(getMed)ms)"
        )
    }
}

private final class SeenProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentProvider?
    var value: AgentProvider? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
