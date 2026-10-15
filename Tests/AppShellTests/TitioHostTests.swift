import XCTest
import Carbon.HIToolbox
import Surfaces
@testable import AgentRuntime
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// Titio is the pet turned into a chat Bot. These drive the real host
/// handlers its catalog tools reach, against a seeded store.
@MainActor
final class TitioHostTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        AgentProvider.selectableForTesting = nil
        directory = NSTemporaryDirectory() + "rc-titio-\(UUID().uuidString)"
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
        let callerThread: AgentThread
        let callerRun: AgentRun
    }

    private func makeFixture() throws -> Fixture {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [AgentModelDescriptor(id: "main-a", label: "Main A", provider: .distill)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp"
        )
        router.rememberProviderSnapshotsForSend([snapshot])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        vm.replaceProvidersForTests([snapshot])
        let callerThread = AgentThread(
            title: "Titio chat", provider: .distill, model: "main-a", status: .running, permissionMode: .fullAccess
        )
        let callerRun = AgentRun(threadId: callerThread.id, provider: .distill, model: "main-a", status: .running)
        try context.threadRepo.upsert(callerThread)
        try context.runRepo.upsert(callerRun)
        return Fixture(context: context, router: router, runner: runner, vm: vm, callerThread: callerThread, callerRun: callerRun)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private func seedScheduledTask(_ f: Fixture, workspace: Workspace, title: String, nextRunAt: Date) throws -> ScheduledTask {
        let task = ScheduledTask(
            title: title,
            prompt: "Run the nightly report",
            workspaceID: workspace.id,
            workspacePathSnapshot: workspace.cwd,
            runAsUser: NSUserName(),
            runAsUID: getuid(),
            provider: .distill,
            providerInstanceID: "distill-acp",
            model: "main-a",
            reasoningEffort: .medium,
            recurrence: .daily(at: ScheduledLocalTime(hour: 3, minute: 0)!),
            timeZoneIdentifier: TimeZone.current.identifier,
            isEnabled: true,
            nextRunAt: nextRunAt
        )
        try ScheduledTaskStore(db: f.context.db).save(task)
        return task
    }

    func test_delegateResolvesBotByNameAndEnqueuesOnItsConversation() async throws {
        // WHY: "peça para o bot developer ..." must reach that Bot's desk,
        // not a guess or a silent no-op.
        let f = try makeFixture()
        let developer = try f.vm.create(name: "Developer", title: "Builds things")
        _ = try f.vm.create(name: "Writer", title: "Docs")

        let result = try await f.router.delegateHostBot(
            bot: "developer",
            text: "crie o jogo da cobrinha na pasta /tmp/snake",
            conversationID: nil,
            callerThread: f.callerThread.id,
            callerRun: f.callerRun.id
        )

        XCTAssertEqual(result.objectValue?["bot_id"]?.stringValue, developer.id.value.uuidString.lowercased())
        let conversations = try f.context.botStore.listConversations(botID: developer.id)
        XCTAssertEqual(conversations.count, 1)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.threadId, conversations.first?.linkedAgentThreadID)
        XCTAssertTrue(request.prompt.contains("jogo da cobrinha"), request.prompt)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_unknownBotOrWorkspaceIsAnExplicitError() async throws {
        let f = try makeFixture()
        do {
            _ = try await f.router.delegateHostBot(
                bot: "nobody", text: "hi", conversationID: nil,
                callerThread: f.callerThread.id, callerRun: f.callerRun.id
            )
            XCTFail("unknown Bot must fail")
        } catch {
            XCTAssertEqual((error as? JSONRPCError)?.code, -32044)
        }
        XCTAssertThrowsError(try f.router.runNextHostScheduledTask(workspace: "nowhere", taskID: nil)) {
            XCTAssertEqual(($0 as? JSONRPCError)?.code, -32044)
        }
        XCTAssertTrue(f.runner.requests.isEmpty)
    }

    func test_runNextClaimsTheWorkspacesNextScheduledTaskThroughTheScheduler() throws {
        // WHY: "dispare agora a próxima schedule task do workspace elephant"
        // must use the real manual run-now claim on the earliest task there.
        let f = try makeFixture()
        let elephant = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let other = try f.router.createWorkspace(name: "zebra", cwd: NSTemporaryDirectory())
        let later = try seedScheduledTask(f, workspace: elephant, title: "Weekly", nextRunAt: Date().addingTimeInterval(7 * 86_400))
        let next = try seedScheduledTask(f, workspace: elephant, title: "Nightly", nextRunAt: Date().addingTimeInterval(3_600))
        _ = try seedScheduledTask(f, workspace: other, title: "Zebra", nextRunAt: Date().addingTimeInterval(60))
        let scheduler = ScheduledTaskScheduler(context: f.context, router: f.router)
        f.router.scheduledTaskScheduler = scheduler

        let result = try f.router.runNextHostScheduledTask(workspace: "Elephant", taskID: nil)

        XCTAssertEqual(result.objectValue?["task_id"]?.stringValue, next.id.uuidString.lowercased())
        let store = ScheduledTaskStore(db: f.context.db)
        let runs = try store.listRuns(taskID: next.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.trigger, .manual)
        XCTAssertEqual(result.objectValue?["run_id"]?.stringValue, runs.first?.id.uuidString.lowercased())
        XCTAssertTrue(try store.listRuns(taskID: later.id).isEmpty)
    }

    func test_activityListReportsRunningThreadsBotsAndScheduledTasks() async throws {
        // WHY: "Titio, quais tarefas estão sendo feitas?" is answered from this.
        let f = try makeFixture()
        let elephant = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let task = try seedScheduledTask(f, workspace: elephant, title: "Nightly report", nextRunAt: Date().addingTimeInterval(3_600))
        let developer = try f.vm.create(name: "Developer", title: "Builds things")
        _ = try await f.router.delegateHostBot(
            bot: "Developer", text: "build the snake game", conversationID: nil,
            callerThread: f.callerThread.id, callerRun: f.callerRun.id
        )
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)

        let snapshot = try await f.router.listHostActivity()

        let object = try XCTUnwrap(snapshot.objectValue)
        let threads = object["threads"]?.arrayValue ?? []
        let running = threads.first { $0.objectValue?["id"]?.stringValue == request.threadId.value.uuidString.lowercased() }
        XCTAssertEqual(running?.objectValue?["status"]?.stringValue, "running")
        let tasks = object["scheduled_tasks"]?.arrayValue ?? []
        let seeded = try XCTUnwrap(tasks.first { $0.objectValue?["id"]?.stringValue == task.id.uuidString.lowercased() })
        XCTAssertEqual(seeded.objectValue?["title"]?.stringValue, "Nightly report")
        XCTAssertEqual(seeded.objectValue?["workspace"]?.stringValue, "elephant")
        XCTAssertNotEqual(seeded.objectValue?["next_run_at"], .null)
        XCTAssertTrue((object["bots"]?.arrayValue ?? []).contains {
            $0.objectValue?["id"]?.stringValue == developer.id.value.uuidString.lowercased()
        })
        XCTAssertTrue((object["workspaces"]?.arrayValue ?? []).contains { $0.objectValue?["name"]?.stringValue == "elephant" })
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_catalogMutationWithoutOperationIDIsRejectedBeforeTheHost() throws {
        let mcp = ManagedBotSelfConfigMCP(environment: [:])
        for tool in [RemoteCodeHostCatalog.botDelegate, RemoteCodeHostCatalog.scheduledTaskRunNext] {
            let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool)","arguments":{"bot":"developer","workspace":"elephant","text":"go"}}}"#
            let reply = try XCTUnwrap(mcp.handle(line))
            XCTAssertTrue(reply.contains("\"isError\":true"), reply)
            XCTAssertTrue(reply.contains("operation_id is required"), reply)
        }
        XCTAssertTrue(RemoteCodeHostCatalog.rpcMutationMethods.contains(RemoteCodeHostCatalog.botDelegateRPC))
        XCTAssertTrue(RemoteCodeHostCatalog.rpcMutationMethods.contains(RemoteCodeHostCatalog.scheduledTaskRunNextRPC))
        XCTAssertFalse(RemoteCodeHostCatalog.rpcMutationMethods.contains(RemoteCodeHostCatalog.activityListRPC))
    }

    func test_titioIsOnePersistedBotWhoseConversationSurvivesReopen() async throws {
        // WHY: the user's Titio chat must survive closing and reopening RemoteCode.
        let f = try makeFixture()
        let first = try f.router.openTitio()
        XCTAssertEqual(try f.router.openTitio(), first, "opening the pet again reuses Titio")
        let titio = try XCTUnwrap(try f.context.botStore.get(id: first))
        XCTAssertEqual(titio.handle, TitioBot.handle)
        XCTAssertEqual(titio.name, "Titio")

        _ = try f.vm.enqueueHostMessage(botID: first, text: "Titio, quais tarefas estão sendo feitas?", conversationID: nil)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        // Titio runs fullAccess so host catalog mutations are admitted, and
        // as a Bot so the managed MCP (with the Titio tools) is attached.
        XCTAssertEqual(request.permissionMode, .fullAccess)
        XCTAssertEqual(request.environment[BotSelfConfigCatalog.callerEnvironmentKey], first.value.uuidString.lowercased())
        f.runner.finish(runID: request.runId, status: .completed, reply: "Nightly report is running.")
        let conversation = try XCTUnwrap(try f.context.botStore.listConversations(botID: first).first)

        let reopened = try AppContext(channel: .debug, appSupportOverride: directory)
        let again = try TitioBot.ensure(store: reopened.botStore, appSupportDirectory: reopened.appSupportDirectory)
        XCTAssertEqual(again.id, first)
        XCTAssertEqual(try reopened.botStore.list(includeHidden: true).filter { $0.handle == TitioBot.handle }.count, 1)
        let reopenedConversations = try reopened.botStore.listConversations(botID: first)
        XCTAssertEqual(reopenedConversations.map(\.id), [conversation.id])
        let threadID = try XCTUnwrap(reopenedConversations.first?.linkedAgentThreadID)
        let messages = try reopened.messageRepo.list(threadId: threadID)
        XCTAssertTrue(messages.contains { $0.content.contains("quais tarefas") })
    }

    func test_titioRunToolsIncludeTitioCatalogAndKeepProviderTools() {
        // WHY: Titio needs the RemoteCode tools and must keep the normal
        // provider tools (shell, files, web) for requests outside RemoteCode.
        let advertised = Set(RemoteCodeHostCatalog.toolNames)
        for tool in [RemoteCodeHostCatalog.activityList, RemoteCodeHostCatalog.botDelegate, RemoteCodeHostCatalog.scheduledTaskRunNext,
                     RemoteCodeHostCatalog.botSend, RemoteCodeHostCatalog.workspaceCreate] {
            XCTAssertTrue(advertised.contains(tool), tool)
        }
        let env = [BotSelfConfigCatalog.callerEnvironmentKey: UUID().uuidString]
        let allowed = ClaudeRunner.automaticallyAllowedTools(environment: env)
        XCTAssertTrue(allowed.contains("mcp__\(BotSelfConfigMCPAdmit.serverName)__\(RemoteCodeHostCatalog.activityList)"))
        XCTAssertTrue(allowed.contains("mcp__\(BotSelfConfigMCPAdmit.serverName)__\(RemoteCodeHostCatalog.botDelegate)"))
        // An allowlist only auto-approves; Titio adds no tool restriction.
        XCTAssertFalse(allowed.contains { $0.hasPrefix("--disallowedTools") || $0 == "--tools" })
        XCTAssertTrue(TitioBot.soul.contains(RemoteCodeHostCatalog.activityList))
        XCTAssertTrue(TitioBot.soul.contains("normal tools"))
    }

    func test_titioIsPinnedAndAlwaysFirstInTheRosterWithThePetAvatar() throws {
        // WHY: Titio holds the top roster slot like the CEO, with the pet's face.
        let f = try makeFixture()
        let ceo = try f.vm.create(name: "Ceo", title: "Chief of all bots")
        f.vm.setPinned(id: ceo.id, pinned: true)
        _ = try f.vm.create(name: "Developer", title: "Builds things")
        let titio = try TitioBot.ensure(store: f.context.botStore, appSupportDirectory: f.context.appSupportDirectory)
        try f.context.botStore.setPinned(id: titio.id, pinned: false)
        try f.context.botStore.setHidden(id: titio.id, hidden: true)

        let again = try TitioBot.ensure(store: f.context.botStore, appSupportDirectory: f.context.appSupportDirectory)
        XCTAssertTrue(again.pinned, "ensure re-pins Titio")
        XCTAssertFalse(again.hidden, "ensure un-hides Titio")
        f.vm.reload()
        XCTAssertEqual(f.vm.fleet.first?.handle, TitioBot.handle)

        XCTAssertNotNil(TitioBot.avatarImage, "pet avatar ships in the AppShell bundle")
        TitioBot.installAvatar()
        XCTAssertNotNil(BotsAvatarView.imageOverride(TitioBot.handle))
        XCTAssertNil(BotsAvatarView.imageOverride("ceo"))
    }

    func test_quickChatSendsToANewTitioConversation() async throws {
        let f = try makeFixture()
        let conversation = try XCTUnwrap(f.router.sendTitioQuickMessage("Titio, quais tarefas estão sendo feitas?"))
        let titio = try XCTUnwrap(try f.context.botStore.list().first { $0.handle == TitioBot.handle })
        XCTAssertEqual(try f.context.botStore.conversation(id: conversation)?.botID, titio.id)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertTrue(request.prompt.contains("quais tarefas"))
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_quickChatRegistersOptionSpaceAndSubmitsTrimmedText() {
        let controller = TitioQuickChatController()
        var sent: [String] = []
        controller.install { sent.append($0) }
        XCTAssertEqual(TitioQuickChatController.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(TitioQuickChatController.modifiers, UInt32(optionKey))
        XCTAssertEqual(controller.registrationStatus, noErr)
        controller.submit("   ")
        controller.submit("  oi titio ")
        XCTAssertEqual(sent, ["oi titio"])
    }
}
