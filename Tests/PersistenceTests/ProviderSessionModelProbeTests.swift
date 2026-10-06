import XCTest
import CoreModel
@testable import Persistence

/// WHY: after an app restart Distill must know which model the persisted
/// provider session last ran before `session/load`; loading a muse-spark
/// session for a Claude Main replays unsigned reasoning that Anthropic rejects.
final class ProviderSessionModelProbeTests: XCTestCase {
    func test_sessionModel_returnsModelOnlyForTheMatchingResumeCursor() throws {
        let tmp = NSTemporaryDirectory() + "rc2-session-model-probe-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "family", provider: .distill, model: "claude/claude-opus-5-5")
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .distill,
            status: .completed,
            resumeCursor: "distill-session-1",
            model: "muse-spark-1.3-contributor"
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting

        XCTAssertEqual(try sessionRepo.sessionModel(of: thread.id, resumeCursor: "distill-session-1"),
                       "muse-spark-1.3-contributor")
        XCTAssertNil(try sessionRepo.sessionModel(of: thread.id, resumeCursor: "distill-session-2"),
                     "a model recorded for another provider session must not describe this cursor")
        XCTAssertNil(try sessionRepo.sessionModel(of: AgentThreadID(), resumeCursor: "distill-session-1"))
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore,
                       "the send path must not pay for the 16-column session get")
    }

    func test_coordinatorReadsPriorSessionModelBeforePendingUpsertOverwritesIt() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let probe = try XCTUnwrap(source.range(of: "effectiveRequest.priorProviderSessionModel = try? repo.sessionModel("))
        let pendingUpsert = try XCTUnwrap(source.range(of: "lastEventKind: \"run.pending\""))
        XCTAssertLessThan(probe.lowerBound, pendingUpsert.lowerBound,
                          "the prior model must be read before this send's pending upsert replaces it")
    }
}
