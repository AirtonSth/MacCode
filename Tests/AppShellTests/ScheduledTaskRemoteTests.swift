import XCTest
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import SocketServer

/// WHY: the iPhone edits the same Schedule Tasks as the Mac (owner, 2026-10-19).
/// Frequencies and efforts must survive the wire exactly, and the list must
/// carry Bot schedules too so one screen shows both kinds.
final class ScheduledTaskRemoteTests: XCTestCase {
    func test_frequencyAndEffortRoundTripTheWire() throws {
        let rule = ScheduledFrequencyRule(frequency: .weekly, scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
                                          intervalHours: 3, localTimeHour: 7, localTimeMinute: 45,
                                          weekdays: [.monday, .friday], monthlyDay: 12)
        XCTAssertEqual(try ScheduledTaskRemoteWire.decodeRule(ScheduledTaskRemoteWire.encodeRule(rule)), rule)
        XCTAssertEqual(ScheduledTaskRemoteWire.effort(ScheduledTaskRemoteWire.effort(.automatic)), .automatic)
        XCTAssertEqual(ScheduledTaskRemoteWire.effort(ScheduledTaskRemoteWire.effort(.fixed(.high))), .fixed(.high))
        XCTAssertThrowsError(try ScheduledTaskRemoteWire.decodeRule(.object(["frequency": .string("yearly")])))
    }

    @MainActor
    func test_listCarriesWorkspaceAndBotSchedules() throws {
        let directory = NSTemporaryDirectory() + "RC2SchedRemote-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let bot = try context.botStore.create(name: "Writer", title: "", description: "", handle: "writer")
        var spec = BotScheduleSpec(provider: .distill, providerInstanceID: "distill", model: "auto")
        spec.distillExecutionMode = .ultracode
        try context.botStore.saveRoutine(BotRoutineDefinition(botID: bot.id, name: "Digest", prompt: "Summarize",
                                                               scheduleNote: spec.displayNote(), scheduleSpecJSON: spec.encodedJSON()))
        let list = try router.listScheduledTasksRemote()
        let botTask = try XCTUnwrap(list.objectValue?["bot_tasks"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(botTask["title"], .string("Digest"))
        XCTAssertEqual(botTask["bot_handle"], .string("writer"))
        XCTAssertEqual(botTask["ultracode"], .bool(true))
        XCTAssertEqual(list.objectValue?["tasks"]?.arrayValue?.count, 0)
    }

    func test_scheduledTaskMutationsEnterTheHostMutationGate() {
        for method in ScheduledTaskRemoteWire.methods {
            XCTAssertTrue(JSONRPCDispatcher.hostMutationMethods.contains(method), method)
            XCTAssertFalse(JSONRPCDispatcher.isReadOnlyBatchMethod(method), method)
        }
        XCTAssertTrue(JSONRPCDispatcher.isReadOnlyBatchMethod("scheduled_task.list"))
        XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: "scheduled_task.list"), "read")
        XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: "scheduled_task.save"), "write")
    }

    @MainActor
    func test_saveBotSchedulePinsTheRequestedDestinationAndReplaysWithoutDuplication() async throws {
        let directory = NSTemporaryDirectory() + "RC2SharedVMSchedule-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = true }
        let bot = try context.botStore.create(name: "Writer", title: "", description: "")
        let machine = try context.botStore.saveVirtualMachine(name: "Research")
        let spec = BotScheduleSpec(model: "auto")
        let params: [String: JSONValue] = [
            "client_request_id": .string(UUID().uuidString),
            "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "title": .string("Research"), "prompt": .string("Summarize"),
            "enabled": .bool(true),
            "schedule_spec_json": .string(spec.encodedJSON()),
            "execution_destination": .string(BotExecutionDestination.virtualMachine(machine.id).storageValue),
        ]
        let dispatcher = JSONRPCDispatcher(router: router)
        let mutation = MutationRequestContext(ownerFingerprint: "titio-schedule-test", hostId: context.liveActivityHostIdentity.serverId, bootEpoch: 0)
        func save(_ values: [String: JSONValue]) async throws {
            let response = await dispatcher.dispatch(.init(jsonrpc: "2.0", id: .number(1), method: "scheduled_task.save", params: values), mutationContext: mutation)
            XCTAssertNil(response.error, "\(String(describing: response.error))")
        }
        try await save(params)
        try await save(params)
        let routines = try context.botStore.listRoutines(botID: bot.id)
        XCTAssertEqual(routines.count, 1)
        XCTAssertTrue(try XCTUnwrap(routines.first).activation.isEnabled)
        let saved = try XCTUnwrap(routines.first?.definition.scheduleSpec)
        XCTAssertEqual(saved.executionDestination, .virtualMachine(machine.id))
        XCTAssertEqual(BotsViewModel.routineRouting(saved, base: BotDeskRouting()).executionDestination, saved.executionDestination)

        var edit = params
        edit["client_request_id"] = .string(UUID().uuidString)
        edit["task_id"] = .string(try XCTUnwrap(routines.first).definition.id.value.uuidString.lowercased())
        edit["enabled"] = .bool(false)
        try await save(edit)
        XCTAssertFalse(try XCTUnwrap(context.botStore.listRoutines(botID: bot.id).first).activation.isEnabled)
        edit["client_request_id"] = .string(UUID().uuidString)
        edit.removeValue(forKey: "enabled")
        try await save(edit)
        XCTAssertFalse(try XCTUnwrap(context.botStore.listRoutines(botID: bot.id).first).activation.isEnabled)
    }

    @MainActor
    func test_invalidBotScheduleDoesNotCreateAnUnrunnableTask() async throws {
        let directory = NSTemporaryDirectory() + "RC2InvalidBotSchedule-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = true }
        let bot = try context.botStore.create(name: "Writer", title: "", description: "")
        var spec = BotScheduleSpec(model: "auto")
        spec.timeZoneIdentifier = "invalid"
        let params: [String: JSONValue] = [
            "client_request_id": .string(UUID().uuidString),
            "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "title": .string("Digest"), "prompt": .string("Summarize"),
            "schedule_spec_json": .string(spec.encodedJSON()), "enabled": .bool(true)
        ]
        let result = try await router.saveScheduledTaskRemote(params: params)
        XCTAssertEqual(result.objectValue?["status"], .string("failed"))
        XCTAssertEqual(result.objectValue?["readback"]?.objectValue?["error_code"], .number(-32602))
        XCTAssertTrue(result.objectValue?["readback"]?.objectValue?["error"]?.stringValue?.contains("time zone") == true)
        let replay = try await router.saveScheduledTaskRemote(params: params)
        XCTAssertEqual(replay, result)
        XCTAssertTrue(try context.botStore.listRoutines(botID: bot.id).isEmpty)
    }

    @MainActor
    func test_invalidSystemUserCannotSilentlyBecomeTheCurrentAccount() async throws {
        let directory = NSTemporaryDirectory() + "RC2ScheduleUser-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Schedule", cwd: directory)
        do {
            _ = try await router.saveScheduledTaskRemote(params: [
                "workspace_id": .string(workspace.id.value.uuidString),
                "title": .string("Task"), "prompt": .string("Build"),
                "run_as_user": .string("missing-user-" + UUID().uuidString)
            ])
            XCTFail("an unavailable account must not be substituted")
        } catch {
            XCTAssertTrue(String(describing: error).contains("eligible system user"), "\(error)")
        }
        XCTAssertTrue(try ScheduledTaskStore(db: context.db).list().isEmpty)
    }
}
