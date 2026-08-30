import XCTest
import CoreModel
import SocketServer
@testable import AppShell

final class BotRuntimeEvidenceProjectorTests: XCTestCase {
    /// WHY: generic Agent events must never advance iOS Bot state unless an
    /// exact completed send receipt first bound their full runtime identity.
    func test_projectsStrictlyOrderedExactStreamAndTerminalEvidence() throws {
        let bus = EventBus(recentLimit: 32)
        var terminals: [BotRuntimeEvidenceProjector.TerminalEvidence] = []
        let projector = BotRuntimeEvidenceProjector(eventBus: bus) { terminals.append($0) }
        let receipt = sendReceipt()
        XCTAssertTrue(projector.registerCompletedSend(receipt))

        var projected: [EventBus.Event] = []
        let token = bus.subscribe(since: bus.currentSeq) { event in
            if event.kind.hasPrefix("bot.run.") { projected.append(event) }
        }
        defer { bus.unsubscribe(token) }

        bus.publish(kind: .agentItemDelta, payload: agentPayload(runID: "wrong-run"))
        bus.publish(kind: .agentItemDelta, payload: agentPayload(threadID: "wrong-thread"))
        bus.publish(kind: .agentItemDelta, payload: agentPayload())
        bus.publish(kind: .agentRunCompleted, payload: agentPayload())
        bus.publish(kind: .agentItemDelta, payload: agentPayload())

        XCTAssertEqual(projected.map(\.kind), ["bot.run.stream", "bot.run.completed"])
        XCTAssertEqual(terminals, [.init(botID: "bot-a", runID: "run-a", failed: false)])
        XCTAssertTrue(zip(projected, projected.dropFirst()).allSatisfy { $0.seq < $1.seq })
        for event in projected {
            let payload = try XCTUnwrap(event.payload.objectValue)
            XCTAssertEqual(payload["host_id"]?.stringValue, "host-a")
            XCTAssertEqual(payload["bot_id"]?.stringValue, "bot-a")
            XCTAssertEqual(payload["conversation_id"]?.stringValue, "conversation-a")
            XCTAssertEqual(payload["request_id"]?.stringValue, "request-a")
            XCTAssertEqual(payload["client_request_id"]?.stringValue, "request-a")
            XCTAssertEqual(payload["run_id"]?.stringValue, "run-a")
        }

        var crossConversation = sendReceipt().objectValue!
        var crossReadback = crossConversation["readback"]!.objectValue!
        var crossRun = crossReadback["run"]!.objectValue!
        crossRun["conversation_id"] = .string("conversation-b")
        crossReadback["run"] = .object(crossRun)
        crossConversation["readback"] = .object(crossReadback)
        XCTAssertFalse(projector.registerCompletedSend(.object(crossConversation)))

        var crossBot = sendReceipt().objectValue!
        var crossBotReadback = crossBot["readback"]!.objectValue!
        var crossBotRun = crossBotReadback["run"]!.objectValue!
        crossBotRun["bot_id"] = .string("bot-b")
        crossBotReadback["run"] = .object(crossBotRun)
        crossBot["readback"] = .object(crossBotReadback)
        XCTAssertFalse(projector.registerCompletedSend(.object(crossBot)))

        var failed = sendReceipt().objectValue!
        failed["status"] = .string("failed")
        XCTAssertFalse(projector.registerCompletedSend(.object(failed)))
    }

    /// WHY: Bot receipts intentionally use lowercase UUIDs while canonical
    /// Agent lifecycle events use Foundation's uppercase UUID spelling. UUID
    /// casing must not strand an otherwise exact Bot run in Working.
    func test_projectsExactTerminalAcrossUUIDCasing() throws {
        let bus = EventBus(recentLimit: 8)
        var terminals: [BotRuntimeEvidenceProjector.TerminalEvidence] = []
        let projector = BotRuntimeEvidenceProjector(eventBus: bus) { terminals.append($0) }
        let runID = "54943aa2-59c1-40e4-b56d-edb6b382edb8"
        let threadID = "2969b74d-0bab-4486-bbf1-8b9a9761f936"
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt(runID: runID, threadID: threadID)))

        bus.publish(kind: .agentRunCompleted, payload: agentPayload(
            runID: runID.uppercased(),
            threadID: threadID.uppercased()
        ))

        XCTAssertEqual(terminals, [.init(botID: "bot-a", runID: runID, failed: false)])
    }

    private func sendReceipt(
        runID: String = "run-a",
        threadID: String = "thread-a"
    ) -> JSONValue {
        .object([
            "status": .string("completed"),
            "host_id": .string("host-a"),
            "bot_id": .string("bot-a"),
            "request_id": .string("request-a"),
            "client_request_id": .string("request-a"),
            "receipt_id": .string("receipt-a"),
            "readback": .object([
                "host_id": .string("host-a"),
                "bot_id": .string("bot-a"),
                "conversation_id": .string("conversation-a"),
                "request_id": .string("request-a"),
                "client_request_id": .string("request-a"),
                "run_id": .string(runID),
                "enqueued": .bool(false),
                "run": .object([
                    "host_id": .string("host-a"),
                    "bot_id": .string("bot-a"),
                    "conversation_id": .string("conversation-a"),
                    "request_id": .string("request-a"),
                    "client_request_id": .string("request-a"),
                    "run_id": .string(runID),
                    "thread_id": .string(threadID),
                ]),
            ]),
        ])
    }

    private func agentPayload(
        runID: String = "run-a",
        threadID: String = "thread-a"
    ) -> JSONValue {
        .object([
            "run_id": .string(runID),
            "thread_id": .string(threadID),
        ])
    }
}
