import XCTest
@testable import AppShell
import CoreModel
import Persistence
import SocketServer

/// WHY: the sidebar's green "finished" dot and Activity's Just finished are the
/// same unread state; clearing one must clear the other.
@MainActor
final class SidebarActivitySeenSyncTests: XCTestCase {
    private func makeContext() throws -> AppContext {
        try AppContext(channel: .debug, appSupportOverride: NSTemporaryDirectory() + "rc2-seen-sync-" + UUID().uuidString)
    }

    func test_openingThreadMarksItsFinishedRunsViewedInActivity() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let thread = AgentThread(workspaceId: WorkspaceID(), title: "Task", provider: .codex, model: "gpt-5")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, providerInstanceId: "codex", model: "gpt-5",
                           status: .completed, startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 20))
        try context.runRepo.upsert(run)
        let results = AgentRunResultRepository(db: context.db)
        XCTAssertNil(try results.get(runId: run.id)?.viewedAt)

        try router.markAgentThreadRead(thread: thread.id)

        XCTAssertNotNil(try results.get(runId: run.id)?.viewedAt, "seen in the sidebar leaves Just finished")
        XCTAssertEqual(try results.threadIDs(runIds: [run.id]), [thread.id])
        XCTAssertTrue(try results.markFinishedRunsViewed(threadId: thread.id).isEmpty, "already viewed runs are not re-stamped")
    }

    func test_activityViewOrClearNamesRunsButUndoDoesNot() {
        let run = AgentRunID(UUID())
        let ids: JSONValue = .array([.string("run:\(run.value.uuidString.lowercased())"), .string("notification:x")])
        for reason in ["viewed", "acknowledged"] {
            let payload: JSONValue = .object(["activity_item_ids": ids, "reason": .string(reason)])
            XCTAssertEqual(SidebarViewModel.seenRunIDs(kind: "notification.read", payload: payload), [run])
        }
        let reopened: JSONValue = .object(["activity_item_ids": ids, "reason": .string("reopened")])
        XCTAssertTrue(SidebarViewModel.seenRunIDs(kind: "notification.read", payload: reopened).isEmpty)
        let thread = AgentThreadID(UUID())
        XCTAssertEqual(SidebarViewModel.seenThreadIDs(kind: "agent.thread.read", payload: .object(["thread_id": .string(thread.value.uuidString)])), [thread])
    }
}
