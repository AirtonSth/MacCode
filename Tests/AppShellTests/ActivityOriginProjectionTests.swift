import XCTest
import RemoteCodeTreaty
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

@MainActor
final class ActivityOriginProjectionTests: XCTestCase {
    func testScheduledQueuedOccurrenceCannotBeViewedOrAcknowledged() throws {
        let fixture = try makeScheduled(status: "queued")
        let id = "scheduled-occurrence:\(fixture.occurrenceID)"
        XCTAssertEqual(try page(fixture.context).items.first { $0.id == id }?.state, .queued)
        XCTAssertThrowsError(try fixture.service.setViewed(["item_ids": .array([.string(id)]), "viewed": .bool(true)]))
        XCTAssertThrowsError(try fixture.service.acknowledge(["item_id": .string(id)]))
    }

    func testScheduledPreAdmissionFailureViewedRemainsNeedsYouAndAckPersistsAcrossReopen() throws {
        let fixture = try makeScheduled(status: "failed")
        let id = "scheduled-occurrence:\(fixture.occurrenceID)"
        _ = try fixture.service.setViewed(["item_ids": .array([.string(id)]), "viewed": .bool(true)])
        let seen = try XCTUnwrap(page(fixture.context).items.first { $0.id == id })
        XCTAssertNotNil(seen.viewedAt)
        XCTAssertTrue(seen.needsAction, "Seen failure must remain in Needs You until acknowledged.")
        _ = try fixture.service.acknowledge(["item_id": .string(id)])
        let reopened = try makeContext(at: fixture.path)
        let restored = try XCTUnwrap(page(reopened).items.first { $0.id == id })
        XCTAssertNotNil(restored.viewedAt)
        XCTAssertNotNil(restored.attentionAcknowledgedAt)
        XCTAssertFalse(restored.needsAction)
        XCTAssertEqual(restored.state, .failed)
        XCTAssertEqual(try page(reopened).counts.needsYou, 0)
        XCTAssertEqual(try page(reopened).counts.finished, 1)
    }

    func testLinkedScheduledOccurrenceIsRepresentedOnlyByCanonicalAgentRun() throws {
        let fixture = try makeScheduled(status: "failed", linked: true)
        let page = try page(fixture.context)
        XCTAssertFalse(page.items.contains { $0.id == "scheduled-occurrence:\(fixture.occurrenceID)" })
        XCTAssertEqual(page.items.filter { $0.runID == fixture.runID }.count, 1)
    }

    func testLinkedOccurrenceFailureNotificationOpensTheListedRunRow() throws {
        // WHY: the failure notification routes Activity to one exact row. Activity lists an
        // occurrence that started an agent run only as `run:<id>`, so naming the occurrence
        // always missed and showed "Requested activity result was not found." for a row
        // that was right there.
        let fixture = try makeScheduled(status: "failed", linked: true)
        let run = ScheduledTaskRun(
            id: try XCTUnwrap(UUID(uuidString: fixture.occurrenceID)), taskID: UUID(), occurrenceKey: fixture.occurrenceID,
            trigger: .scheduled, scheduledAt: Date(), status: .failed, agentRunID: AgentRunID(fixture.runID)
        )
        let routed = ScheduledTaskScheduler.failureActivityItemID(for: run)
        let data = try JSONEncoder().encode(try ActivityService(context: fixture.context).list(["section": .string("finished")]))
        let finished = try AgentActivityPage.makeJSONDecoder().decode(AgentActivityPage.self, from: data)
        XCTAssertTrue(finished.items.contains { $0.id == routed }, "\(routed) must be a row the routed Finished tab lists")

        let unlinked = ScheduledTaskRun(taskID: UUID(), occurrenceKey: "k", trigger: .scheduled, scheduledAt: Date(), status: .failed)
        XCTAssertEqual(ScheduledTaskScheduler.failureActivityItemID(for: unlinked),
                       "scheduled-occurrence:\(unlinked.id.uuidString.lowercased())",
                       "an occurrence that never started a run is listed under its own id")
    }

    private struct ScheduledFixture {
        let context: AppContext
        let service: ActivityService
        let path: String
        let occurrenceID: String
        let runID: UUID
    }

    private func makeContext(at path: String = NSTemporaryDirectory() + "activity-origin-" + UUID().uuidString) throws -> AppContext {
        try AppContext(channel: .debug, appSupportOverride: path)
    }

    private func makeScheduled(status: String, linked: Bool = false) throws -> ScheduledFixture {
        let path = NSTemporaryDirectory() + "activity-origin-" + UUID().uuidString
        let context = try makeContext(at: path)
        let workspaceID = UUID()
        let taskID = UUID().uuidString
        let occurrenceID = UUID().uuidString
        var linkedRunID: AgentRunID?
        var agentThread: AgentThread?
        if linked {
            let thread = AgentThread(workspaceId: WorkspaceID(workspaceID), title: "Scheduled", provider: .codex, model: "test")
            try context.threadRepo.upsert(thread)
            let run = AgentRun(threadId: thread.id, provider: .codex, model: "test", status: .failed, startedAt: Date(), finishedAt: Date())
            try context.runRepo.upsert(run)
            linkedRunID = run.id
            agentThread = thread
        }
        let stamp = "2026-01-01T00:00:00.000Z"
        let task = try context.db.prepare("INSERT INTO scheduled_tasks (id,title,prompt,workspace_id,workspace_path_snapshot,run_as_user,run_as_uid,provider,provider_instance_id,model,reasoning_effort,recurrence_json,timezone_id,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);")
        for (index, value) in [taskID, "Task", "prompt", workspaceID.uuidString, "/tmp", "current", "0", "codex", "default", "test", "medium", "{}", "UTC", stamp, stamp].enumerated() {
            try task.bind(Int32(index + 1), value)
        }
        _ = try task.step()
        let occurrence = try context.db.prepare("INSERT INTO scheduled_task_runs (id,task_id,occurrence_key,trigger,scheduled_at,queued_at,finished_at,status,agent_run_id,created_at) VALUES (?,?,?,?,?,?,?,?,?,?);")
        let values: [String?] = [occurrenceID, taskID, occurrenceID, "scheduled", stamp, stamp, status == "failed" ? stamp : nil, status, linkedRunID?.description, stamp]
        for (index, value) in values.enumerated() { try occurrence.bind(Int32(index + 1), value) }
        _ = try occurrence.step()
        return ScheduledFixture(context: context, service: ActivityService(context: context), path: path, occurrenceID: occurrenceID, runID: linkedRunID?.value ?? UUID())
    }

    private func page(_ context: AppContext) throws -> AgentActivityPage {
        let data = try JSONEncoder().encode(try ActivityService(context: context).list([:]))
        return try AgentActivityPage.makeJSONDecoder().decode(AgentActivityPage.self, from: data)
    }

    func testLegacyActivityPayloadDecodesWithoutOptionalOriginFields() throws {
        let data = Data(#"{"id":"legacy","kind":"agent","state":"running","title":"Run","occurred_at":"2026-01-01T00:00:00Z","needs_action":false,"blocking":false,"changed_files":[]}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(AgentActivityItem.self, from: data)
        XCTAssertNil(item.botID)
        XCTAssertNil(item.conversationID)
        XCTAssertNil(item.originLabel)
    }
}
