import XCTest
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// P6 router wiring: `bot.guest.control` from a paired device drives the same
/// BotComputerControl and manual-action card as the Mac, and agent-step
/// `bot.guest.updated` events reach paired devices only while one is watching.
@MainActor
final class BotGuestControlRouterTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        directory = NSTemporaryDirectory() + "rc-bot-guest-control-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
        directory = nil
    }

    private func makeRouter() throws -> (AppCommandRouter, BotComputerControl, AppContext) {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let control = BotComputerControl()
        router.botComputerControl = control
        return (router, control, context)
    }

    private func createBot(_ router: AppCommandRouter) async throws -> (id: String, botID: BotID) {
        let created = try await router.dispatchPairedBotRemote(method: "bot.create", params: [
            "client_request_id": .string("create-\(UUID().uuidString)"),
            "name": .string("Piper"),
        ])
        let id = try XCTUnwrap(created.objectValue?["bot_id"]?.stringValue)
        return (id, BotID(try XCTUnwrap(UUID(uuidString: id))))
    }

    private func thread(_ context: AppContext, target: ExecutionTarget?) throws -> AgentThreadID {
        var thread = AgentThread(workspaceId: WorkspaceID(), title: "Bot thread", provider: .codex, model: "gpt-5")
        thread.executionTarget = target
        try context.threadRepo.upsert(thread)
        return thread.id
    }

    private func guestControl(_ router: AppCommandRouter, _ bot: String, _ action: String) async throws -> JSONValue {
        try await router.dispatchPairedBotRemote(method: "bot.guest.control", params: [
            "client_request_id": .string("\(action)-\(UUID().uuidString)"),
            "bot_id": .string(bot),
            "host_id": .string("paired-host"),
            "action": .string(action),
        ])
    }

    /// `agent.manual_action.updated` states for one request published since `seq`.
    private func manualActionStates(since seq: Int64, id: UUID) -> [String] {
        EventBus.shared.recentEvents(since: seq, maxBytes: nil).events.compactMap { event in
            guard event.kind == "agent.manual_action.updated",
                  let row = event.payload.objectValue?["manual_action"]?.objectValue,
                  row["id"]?.stringValue == id.uuidString else { return nil }
            return row["state"]?.stringValue
        }
    }

    func test_takeFromAPairedDeviceTakesTheBotsOpenManualActionLikeTheMacCard() async throws {
        // WHY: on the Mac, Take with an open request marks it taken; the
        // iPhone's Take must leave the same card state, not an "open" card on
        // a computer the user already drives. Paired devices hear it inside the
        // call (so the ledger puts it in the receipt), and release hands the
        // request back as open without answering it.
        let (router, control, context) = try makeRouter()
        let bot = try await createBot(router)
        let threadID = try thread(context, target: .vm)
        let request = ManualActionRequest(botID: bot.botID, threadID: threadID, kind: .login, reason: "Sign in")
        try router.manualActionStore.upsert(request)

        let beforeTake = EventBus.shared.snapshot().lastSeq
        let taken = try await guestControl(router, bot.id, "take")
        XCTAssertEqual(manualActionStates(since: beforeTake, id: request.id), ["taken"],
                       "published before the call returned")
        XCTAssertEqual(taken.objectValue?["status"]?.stringValue, "completed")
        XCTAssertEqual(taken.objectValue?["readback"]?.objectValue?["controlled_by_user"]?.boolValue, true)
        XCTAssertTrue(control.isControlledByUser(bot.botID), "the bot's act/exec are refused while the user drives")
        XCTAssertEqual(router.manualActionStore.all(threadID: threadID).first?.state, .taken)

        let beforeRelease = EventBus.shared.snapshot().lastSeq
        _ = try await guestControl(router, bot.id, "release")
        XCTAssertFalse(control.isControlledByUser(bot.botID))
        XCTAssertEqual(
            router.manualActionStore.all(threadID: threadID).first?.state, .open,
            "release does not answer the request; agent.manual_action.resolve does"
        )
        XCTAssertEqual(manualActionStates(since: beforeRelease, id: request.id), ["open"],
                       "the store and every paired card agree it is open again")
    }

    func test_takeFromAPairedDeviceLeavesAMacExecutionRequestOpen() async throws {
        // WHY: a thread that runs on the Mac has no bot computer to take; the
        // Mac card and agent.manual_action.resolve refuse it, so must this.
        let (router, control, context) = try makeRouter()
        let bot = try await createBot(router)
        let threadID = try thread(context, target: .mac)
        let request = ManualActionRequest(botID: bot.botID, threadID: threadID, kind: .login, reason: "Sign in")
        try router.manualActionStore.upsert(request)

        _ = try await guestControl(router, bot.id, "take")
        XCTAssertTrue(control.isControlledByUser(bot.botID))
        XCTAssertEqual(router.manualActionStore.all(threadID: threadID).first?.state, .open)
    }

    func test_controlChangesOnTheMacReachPairedDevices() async throws {
        // WHY: parity. A Take/Release on the Mac card or screen toggle must
        // reach the iPhone even when its viewer is closed (no observe poll).
        let (router, control, _) = try makeRouter()
        let bot = try await createBot(router)
        func controlEvents(since seq: Int64) -> [Bool] {
            EventBus.shared.recentEvents(since: seq, maxBytes: nil).events.compactMap { event in
                guard event.kind == "bot.guest.updated",
                      let payload = event.payload.objectValue,
                      payload["reason"]?.stringValue == "control",
                      payload["bot_id"]?.stringValue == bot.id else { return nil }
                XCTAssertNil(payload["request_id"], "not a receipt event")
                return payload["controlled_by_user"]?.boolValue
            }
        }
        let start = EventBus.shared.snapshot().lastSeq
        control.take(bot.botID)
        control.take(bot.botID)
        for _ in 0..<50 where controlEvents(since: start).isEmpty { await Task.yield() }
        XCTAssertEqual(controlEvents(since: start), [true], "a repeated take is not a change")

        let released = EventBus.shared.snapshot().lastSeq
        control.release(bot.botID)
        for _ in 0..<50 where controlEvents(since: released).isEmpty { await Task.yield() }
        XCTAssertEqual(controlEvents(since: released), [false])

        let other = BotComputerControl()
        let unrelated = EventBus.shared.snapshot().lastSeq
        other.take(bot.botID)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(controlEvents(since: unrelated).isEmpty, "only the router's own control is published")
    }

    func test_agentStepEventsAreSentOnlyWhileAPairedViewerWatches() async throws {
        let (router, _, _) = try makeRouter()
        let bot = try await createBot(router)
        func stepEvents(since seq: Int64) -> [[String: JSONValue]] {
            EventBus.shared.recentEvents(since: seq, maxBytes: nil).events.compactMap { event in
                guard event.kind == "bot.guest.updated",
                      let payload = event.payload.objectValue,
                      payload["reason"]?.stringValue == "agent_step",
                      payload["bot_id"]?.stringValue == bot.id else { return nil }
                return payload
            }
        }

        let unwatched = EventBus.shared.snapshot().lastSeq
        router.publishGuestAgentStep(botID: bot.botID, step: "act")
        XCTAssertTrue(stepEvents(since: unwatched).isEmpty, "no viewer: no event noise for older clients")

        // No VM in tests: the observe answers not_running but marks the viewer as watching.
        let observed = try await router.dispatchPairedBotRemote(method: "bot.guest.state", params: [
            "bot_id": .string(bot.id),
            "host_id": .string("paired-host"),
            "observe": .bool(true),
        ])
        XCTAssertEqual(observed.objectValue?["observe"]?.objectValue?["outcome"]?.stringValue, "not_running")
        XCTAssertEqual(observed.objectValue?["controlled_by_user"]?.boolValue, false)

        let watched = EventBus.shared.snapshot().lastSeq
        router.publishGuestAgentStep(botID: bot.botID, step: "exec")
        let events = stepEvents(since: watched)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["step"]?.stringValue, "exec")
        XCTAssertEqual(events.first?["host_id"]?.stringValue, "paired-host")
        XCTAssertEqual(events.first?["frame_stale"]?.boolValue, true)
        XCTAssertNil(events.first?["request_id"], "not a receipt event: old clients ignore it")
    }
}
