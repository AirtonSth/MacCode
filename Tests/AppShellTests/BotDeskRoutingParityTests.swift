import XCTest
import AgentRuntime
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// P1: paired `bot.send` runs exactly the route the Mac desk shows for that
/// conversation, Worker included, and that route is persisted per
/// conversation in the DB.
@MainActor
final class BotDeskRoutingParityTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        AgentProvider.selectableForTesting = nil
        directory = NSTemporaryDirectory() + "rc-bot-desk-routing-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
        directory = nil
    }

    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let runner: ControlledBotHandoffRunner
        let vm: BotsViewModel
    }

    private func makeFixture(lastUsed: String? = nil) throws -> Fixture {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [
                AgentModelDescriptor(id: "main-a", label: "Main A", provider: .distill),
                AgentModelDescriptor(id: "main-b", label: "Main B", provider: .distill),
            ],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp",
            capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
        )
        router.rememberProviderSnapshotsForSend([snapshot])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let suiteName = "rc2-bot-desk-routing-" + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let lastModels = AgentLastModelStore(defaults: suite)
        if let lastUsed { lastModels.remember(model: lastUsed, for: .distill) }
        vm.lastModelStore = lastModels
        vm.replaceProvidersForTests([snapshot])
        return Fixture(context: context, router: router, runner: runner, vm: vm)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func test_receiptlessHostSendToANonSelectedConversation_runsThatConversationsRoute() async throws {
        // WHY: an iOS send without a routing receipt used to fall back to a
        // hardcoded grok route; it must run what the Mac desk set for that
        // conversation, even when another conversation is open.
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        let planned = try XCTUnwrap(f.vm.selectedConversation)
        f.vm.setDeskModel("main-b")
        f.vm.setDeskReasoningModel("main-a")
        XCTAssertTrue(f.vm.createDeskThread())
        f.vm.setDeskModel("main-a")
        f.vm.setDeskReasoningModel(nil)
        XCTAssertNotEqual(f.vm.selectedConversation?.id, planned.id)

        let sent = try f.vm.enqueueHostMessage(botID: bot.id, text: "go", conversationID: planned.id)

        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.provider, .distill)
        XCTAssertEqual(request.model, "main-b", "the planned conversation's Main, not the open one's")
        XCTAssertEqual(request.reasoningModel, "main-a", "its Worker too")
        let effective = try XCTUnwrap(sent.objectValue?["effective_routing"]?.objectValue)
        XCTAssertEqual(effective["model"]?.stringValue, "main-b")
        XCTAssertEqual(effective["worker_model"]?.stringValue, "main-a")
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_receiptlessHostSendToANewConversation_resolvesTheDistillDefault() async throws {
        // WHY: an unlinked, never-opened conversation has no saved route; the
        // send must resolve like a new Agent App thread (last-used Distill
        // model), never an empty model or a legacy provider.
        let f = try makeFixture(lastUsed: "main-b")
        let bot = try f.vm.create(name: "Piper", title: "Scout")

        let sent = try f.vm.enqueueHostMessage(botID: bot.id, text: "go", conversationID: nil)

        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.provider, .distill)
        XCTAssertEqual(request.model, "main-b")
        XCTAssertEqual(sent.objectValue?["effective_routing"]?.objectValue?["model"]?.stringValue, "main-b")
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_pairedRoutingSetForAConversation_isWhatTheMacShowsAndWhatTheReceiptSendRuns() async throws {
        // WHY: iOS and the Mac desk kept two route stores; a conversation-scoped
        // bot.routing.set must update the Mac desk route (and tell paired
        // devices), and the receipt-bound send must run its Worker.
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        let conversation = try XCTUnwrap(f.vm.selectedConversation)
        let botID = bot.id.value.uuidString.lowercased()
        let conversationID = conversation.id.value.uuidString.lowercased()
        let before = EventBus.shared.snapshot().lastSeq
        var params: [String: JSONValue] = [
            "client_request_id": .string("route"), "bot_id": .string(botID),
            "host_id": .string("paired-host"), "conversation_id": .string(conversationID),
            "provider": .string("distill"), "provider_instance_id": .string("distill-acp"),
            "model": .string("main-b"), "routing_mode": .string("manual"),
            "permission_mode": .string("supervised"), "reasoning_effort": .string("medium"),
            "service_tier": .string("auto"), "worker_model": .string("main-a"),
            "worker_effort": .string("high"), "distill_main_effort": .string("low"),
        ]
        let routed = try await f.router.dispatchPairedBotRemote(method: "bot.routing.set", params: params)
        let readback = try XCTUnwrap(routed.objectValue?["readback"]?.objectValue)
        let receiptID = try XCTUnwrap(routed.objectValue?["receipt_id"]?.stringValue)

        XCTAssertEqual(f.vm.deskRouting.model, "main-b", "the open Mac desk shows the paired route")
        XCTAssertEqual(f.vm.deskRouting.reasoningModel, "main-a")
        XCTAssertEqual(f.vm.deskRouting.distillReasoningEffortSelection, .fixed(.high))
        XCTAssertEqual(f.vm.deskRouting.distillMainEffortSelection, .fixed(.low))
        XCTAssertNotNil(try f.context.botStore.deskRoutingJSON(conversationID: conversation.id),
                        "the route is persisted per conversation in the DB")
        let events = EventBus.shared.recentEvents(since: before, maxBytes: nil).events
        XCTAssertTrue(events.contains { event in
            event.kind == "bot.conversation.updated"
                && event.payload.objectValue?["conversation_id"]?.stringValue == conversationID
                && event.payload.objectValue?["desk_routing"]?.objectValue?["worker_model"]?.stringValue == "main-a"
        }, "paired devices learn the conversation's new route")

        let listed = try await f.router.dispatchPairedBotRemote(
            method: "bot.conversation.list", params: ["bot_id": .string(botID)]
        )
        let row = listed.objectValue?["conversations"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(row?["desk_routing"]?.objectValue?["model"]?.stringValue, "main-b")

        params["client_request_id"] = .string("send")
        params["routing_receipt_id"] = .string(receiptID)
        params["text"] = .string("go")
        params["run_as_user"] = readback["run_as_user"]
        _ = try await f.router.dispatchPairedBotRemote(method: "bot.send", params: params)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.model, "main-b")
        XCTAssertEqual(request.reasoningModel, "main-a", "the paired send runs the Worker it chose")
        XCTAssertEqual(request.distillReasoningEffortSelection, .fixed(.high))
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_deskRouteSurvivesRestartFromTheDB_andTheDefaultsStoreMovesOnce() throws {
        // WHY: user choices must survive closing RemoteCode; the route now
        // lives in the DB and the old UserDefaults map is moved, then dropped.
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        let kept = try XCTUnwrap(f.vm.selectedConversation)
        f.vm.setDeskModel("main-b")
        XCTAssertTrue(f.vm.createDeskThread())
        let legacy = try XCTUnwrap(f.vm.selectedConversation)
        let legacyRoute: [String: Any] = [
            "provider": "distill", "providerInstanceID": "distill-acp", "model": "main-a",
            "routingMode": "manual", "permissionMode": "supervised", "reasoningModel": "main-b",
        ]
        UserDefaults.standard.set(
            try JSONSerialization.data(withJSONObject: [
                legacy.id.value.uuidString.lowercased(): legacyRoute,
                UUID().uuidString.lowercased(): legacyRoute,
            ]),
            forKey: "bots.deskThreadRouting"
        )

        let restarted = BotsViewModel(context: f.context, router: f.router)
        restarted.replaceProvidersForTests(f.vm.providers)
        restarted.openDesk(bot)
        restarted.selectDeskThread(kept.id)
        XCTAssertEqual(restarted.deskRouting.model, "main-b")
        restarted.selectDeskThread(legacy.id)
        XCTAssertEqual(restarted.deskRouting.reasoningModel, "main-b", "the old store is migrated")
        XCTAssertNil(UserDefaults.standard.data(forKey: "bots.deskThreadRouting"),
                     "the move happens once")
        XCTAssertEqual(try f.context.botStore.listDeskRoutingJSON().count, 2,
                       "only live conversations get a row")
    }
}
