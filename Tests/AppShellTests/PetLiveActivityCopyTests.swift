import XCTest
@testable import AppShell
import CoreModel
import RemoteCodeTreaty
import SocketServer

final class PetLiveActivityCopyTests: XCTestCase {
    private let workspace = WorkspaceID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let thread = AgentThreadID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)

    private func item(
        id: String,
        kind: AgentActivityKind = .agent,
        state: AgentActivityState,
        needsAction: Bool = false,
        blocking: Bool = false,
        finishedAt: Date? = nil,
        viewedAt: Date? = nil,
        attentionAcknowledgedAt: Date? = nil,
        includeThread: Bool = true,
        surfaceID: UUID? = nil
    ) -> AgentActivityItem {
        AgentActivityItem(
            id: id,
            kind: kind,
            runID: state == .running || finishedAt != nil ? UUID() : nil,
            requestID: kind == .request ? "request-1" : nil,
            workspaceID: workspace.value,
            threadID: includeThread ? thread.value : nil,
            surfaceID: surfaceID,
            state: state,
            title: "raw private prompt must not escape",
            summary: "raw assistant transcript must not escape",
            occurredAt: finishedAt ?? Date(timeIntervalSince1970: 10),
            startedAt: state == .running ? Date(timeIntervalSince1970: 1) : nil,
            finishedAt: finishedAt,
            viewedAt: viewedAt,
            attentionAcknowledgedAt: attentionAcknowledgedAt,
            needsAction: needsAction,
            blocking: blocking
        )
    }

    private func page(
        _ items: [AgentActivityItem],
        running: Int = 0,
        needsYou: Int = 0,
        finished: Int = 0,
        newResults: Int = 0
    ) -> AgentActivityPage {
        AgentActivityPage(
            items: items,
            counts: AgentActivityCounts(
                running: running,
                queued: 0,
                needsYou: needsYou,
                finished: finished,
                newResults: newResults
            ),
            generatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    func testPendingCallbackTakesNeedsYouPhaseBeforeRunningAndHistory() throws {
        let run = item(id: "run:1", state: .running)
        let callback = item(
            id: "request:1",
            kind: .request,
            state: .waitingApproval,
            needsAction: true,
            blocking: true
        )
        let failure = item(
            id: "run:failed",
            state: .failed,
            needsAction: true,
            finishedAt: Date(timeIntervalSince1970: 9)
        )
        let output = try XCTUnwrap(PetLiveActivityCopy.makeActivity(
            page: page([run, failure, callback], running: 1, needsYou: 2, finished: 1, newResults: 1)
        ))

        XCTAssertEqual(output.title, "2 items need attention", "Action count must not be added to history or running counts.")
        XCTAssertEqual(output.statusLine, "Approval required")
        XCTAssertEqual(output.preview, "Needs you · Approval required")
        XCTAssertEqual(output.phase, .failed)
        XCTAssertEqual(output.activeThreadCount, 1)
        XCTAssertNil(output.threadId, "Blocking callback must not deep-link to the running thread.")
        for privateText in ["raw private prompt", "raw assistant transcript"] {
            XCTAssertFalse(output.preview.contains(privateText))
            XCTAssertFalse(output.statusLine.contains(privateText))
        }
    }

    func testRunningUsesActivityServiceCount() throws {
        let running = item(id: "run:running", state: .running)
        let output = try XCTUnwrap(PetLiveActivityCopy.makeActivity(page: page([running], running: 1)))
        XCTAssertEqual(output.title, "1 running")
        XCTAssertEqual(output.preview, "Agent running")
        XCTAssertEqual(output.phase, .running)
        XCTAssertEqual(output.activeThreadCount, 1)
        XCTAssertEqual(output.threadId, thread.value.uuidString)
    }

    func testRegisteredOperationWithoutAgentThreadUsesGenericRunningCopyAndInheritedMetadata() throws {
        let surface = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let operation = item(id: "operation:build", kind: .operation, state: .running, includeThread: false, surfaceID: surface)
        let output = try XCTUnwrap(PetLiveActivityCopy.makeActivity(page: page([operation], running: 1)))
        XCTAssertEqual(output.title, "1 running")
        XCTAssertEqual(output.preview, "Registered operation running")
        XCTAssertEqual(output.phase, .running)
        XCTAssertEqual(output.activeThreadCount, 1)
        XCTAssertEqual(output.runStartDate, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(output.workspaceId, workspace.value.uuidString)
        XCTAssertNil(output.threadId)
    }

    func testStoppedRunHasExplicitNonFailureStatus() throws {
        let stopped = item(
            id: "run:stopped",
            state: .stopped,
            finishedAt: Date(timeIntervalSince1970: 20)
        )
        let output = try XCTUnwrap(PetLiveActivityCopy.makeActivity(
            page: page([stopped], finished: 1, newResults: 1)
        ))
        XCTAssertEqual(output.title, "1 Thread Completed")
        XCTAssertEqual(output.statusLine, "Stopped by you")
        XCTAssertEqual(output.phase, .completed)
    }

    func testSeenUnacknowledgedFailureStaysActionAndIsNotAddedToHistoryCount() throws {
        let failed = item(
            id: "run:seen-failure",
            state: .failed,
            needsAction: true,
            finishedAt: Date(timeIntervalSince1970: 20),
            viewedAt: Date(timeIntervalSince1970: 30)
        )
        let output = try XCTUnwrap(PetLiveActivityCopy.makeActivity(page:
            page([failed], needsYou: 1, finished: 1, newResults: 0)
        ))
        XCTAssertEqual(output.title, "1 item needs attention")
        XCTAssertEqual(output.statusLine, "Action required", "unrecognized action copy must stay generic to avoid exposing private transcript content")
        XCTAssertEqual(output.phase, .failed)
        XCTAssertEqual(output.activeThreadCount, 0)
    }

    func testAcknowledgedFailureRemainsFinishedHistoryUsingServiceCounts() throws {
        let failed = item(
            id: "run:acked-failure",
            state: .failed,
            needsAction: true,
            finishedAt: Date(timeIntervalSince1970: 20),
            attentionAcknowledgedAt: Date(timeIntervalSince1970: 30)
        )
        let output = try XCTUnwrap(PetLiveActivityCopy.makeActivity(page:
            page([failed], needsYou: 0, finished: 1, newResults: 1)
        ))
        XCTAssertEqual(output.title, "1 Thread Completed")
        XCTAssertEqual(output.statusLine, "Failed")
        XCTAssertEqual(output.phase, .failed)
        XCTAssertTrue(output.preview.contains("1 new result"))

        let seenAndAcknowledged = item(
            id: "run:seen-acked-failure",
            state: .failed,
            needsAction: true,
            finishedAt: Date(timeIntervalSince1970: 20),
            viewedAt: Date(timeIntervalSince1970: 31),
            attentionAcknowledgedAt: Date(timeIntervalSince1970: 30)
        )
        XCTAssertNil(
            PetLiveActivityCopy.makeActivity(
                page: page([seenAndAcknowledged], needsYou: 0, finished: 1, newResults: 0)
            ),
            "Seen and acknowledged failure remains in Activity history but no longer needs a Live Activity."
        )
    }

    func testOfflinePageDoesNotCreateSurface() {
        XCTAssertNil(PetLiveActivityCopy.makeActivity(page: nil))
    }

    func testRouterJSONValueDecodesAsRemoteCodeTreatyPage() throws {
        let date = Date(timeIntervalSince1970: 123)
        let expected = page([item(id: "run:decode", state: .completed, finishedAt: date)], finished: 1, newResults: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let value = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(expected))
        XCTAssertEqual(try PetController.decodeActivityPage(value), expected)
    }

    func testItemStartedPreviewSurfacesSafeProseAndFiltersRuntimeNoise() {
        let thinking = PetController.itemStartedPreview(payload: [
            "item": .object([
                "id": .string("r1"),
                "type": .string("reasoning"),
                "body": .string("Considering how to run the distill checks.")
            ])
        ])
        XCTAssertEqual(thinking, "Considering how to run the distill checks.")

        let noise = PetController.itemStartedPreview(payload: [
            "item": .object([
                "id": .string("n1"),
                "type": .string("tool"),
                "summary": .string("claude.session.snapshot"),
                "body": .string("")
            ])
        ])
        XCTAssertNil(noise)
        XCTAssertTrue(PetController.isProviderRuntimeNoise("claude runtime: claude.session.snapshot"))
        XCTAssertFalse(PetController.isProviderRuntimeNoise("Running: git status"))
    }

    func testItemDeltaPreviewSurfacesAssistantProseOnly() {
        XCTAssertEqual(PetController.itemDeltaPreview(payload: [
            "item": .object([
                "type": .string("assistantMessage"),
                "body": .string("Checking the reconcile path next.")
            ])
        ]), "Checking the reconcile path next.")
        XCTAssertNil(PetController.itemDeltaPreview(payload: [
            "item": .object([
                "type": .string("tool"),
                "body": .string("claude.session.snapshot")
            ])
        ]))
    }

    func testTitleHelpersAreStableAcrossCounts() {
        XCTAssertEqual(PetLiveActivityCopy.runningTitle(count: 0), "0 Threads Running")
        XCTAssertEqual(PetLiveActivityCopy.runningTitle(count: 1), "1 Thread Running")
        XCTAssertEqual(PetLiveActivityCopy.completedTitle(count: 1), "1 Thread Completed")
        XCTAssertEqual(PetLiveActivityCopy.doneFailedLine(done: 2, failed: 7), "2 done - 7 failed")
        XCTAssertEqual(PetLiveActivityCopy.doneFailedLine(done: 0, failed: 0), "")
    }
}
