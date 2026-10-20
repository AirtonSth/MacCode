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
        spec.distillUltracode = true
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
            "schedule_spec_json": .string(spec.encodedJSON()),
            "execution_destination": .string(BotExecutionDestination.virtualMachine(machine.id).storageValue),
        ]
        _ = try await router.saveScheduledTaskRemote(params: params)
        _ = try await router.saveScheduledTaskRemote(params: params)
        let routines = try context.botStore.listRoutines(botID: bot.id)
        XCTAssertEqual(routines.count, 1)
        let saved = try XCTUnwrap(routines.first?.definition.scheduleSpec)
        XCTAssertEqual(saved.executionDestination, .virtualMachine(machine.id))
        XCTAssertEqual(BotsViewModel.routineRouting(saved, base: BotDeskRouting()).executionDestination, saved.executionDestination)
    }
}
