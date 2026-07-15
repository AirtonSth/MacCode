import XCTest
@testable import CoreModel
@testable import Persistence

final class AgentProposedPlanDurabilityTests: XCTestCase {
    func test_markImplementedFailsLoudWhenPlanDoesNotExist() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-plan-missing-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        let source = AgentThread(title: "source", provider: .codex, model: "gpt")
        let implementation = AgentThread(title: "implementation", provider: .codex, model: "gpt")
        let threads = AgentThreadRepository(db: db)
        try threads.upsert(source)
        try threads.upsert(implementation)

        XCTAssertThrowsError(try AgentProposedPlanRepository(db: db).markImplemented(
            threadId: source.id,
            planId: "missing-plan",
            implementationThreadId: implementation.id
        ), "a run must not be reported as a successfully implemented plan when the durable plan row is absent")
    }

    func test_markImplementedPersistsExactlyOneExistingPlan() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-plan-mark-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        let source = AgentThread(title: "source", provider: .codex, model: "gpt")
        let implementation = AgentThread(title: "implementation", provider: .codex, model: "gpt")
        let threads = AgentThreadRepository(db: db)
        try threads.upsert(source)
        try threads.upsert(implementation)
        let plans = AgentProposedPlanRepository(db: db)
        try plans.upsert(threadId: source.id, plan: AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "Implement safely"))

        try plans.markImplemented(
            threadId: source.id,
            planId: "plan-1",
            implementationThreadId: implementation.id,
            at: Date(timeIntervalSince1970: 42)
        )

        let record = try XCTUnwrap(plans.list(threadId: source.id).first)
        XCTAssertEqual(record.plan.implementedAtMs, 42_000)
        XCTAssertEqual(record.implementationThreadId, implementation.id)
    }
}
