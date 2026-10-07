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

    func test_takeFromAPairedDeviceTakesTheBotsOpenManualActionLikeTheMacCard() async throws {
        // WHY: on the Mac, Take with an open request marks it taken; the
        // iPhone's Take must leave the same card state, not an "open" card on
        // a computer the user already drives.
        let (router, control, _) = try makeRouter()
        let bot = try await createBot(router)
        let request = ManualActionRequest(botID: bot.botID, threadID: AgentThreadID(), kind: .login, reason: "Sign in")
        try router.manualActionStore.upsert(request)

        let taken = try await router.dispatchPairedBotRemote(method: "bot.guest.control", params: [
            "client_request_id": .string("take"),
            "bot_id": .string(bot.id),
            "host_id": .string("paired-host"),
            "action": .string("take"),
        ])
        XCTAssertEqual(taken.objectValue?["status"]?.stringValue, "completed")
        XCTAssertEqual(taken.objectValue?["readback"]?.objectValue?["controlled_by_user"]?.boolValue, true)
        XCTAssertTrue(control.isControlledByUser(bot.botID), "the bot's act/exec are refused while the user drives")
        let stored = router.manualActionStore.all(threadID: try XCTUnwrap(request.threadID))
        XCTAssertEqual(stored.first?.state, .taken)

        _ = try await router.dispatchPairedBotRemote(method: "bot.guest.control", params: [
            "client_request_id": .string("release"),
            "bot_id": .string(bot.id),
            "host_id": .string("paired-host"),
            "action": .string("release"),
        ])
        XCTAssertFalse(control.isControlledByUser(bot.botID))
        XCTAssertEqual(
            router.manualActionStore.all(threadID: try XCTUnwrap(request.threadID)).first?.state, .taken,
            "release does not answer the request; agent.manual_action.resolve does"
        )
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
