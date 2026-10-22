import XCTest
import CoreModel
@testable import AppShell

final class ScheduleTaskWorkspaceGroupTests: XCTestCase {
    func test_tasksAndBotSchedulesShareTheirWorkspaceGroup_andLooseOnesGoLast() {
        // WHY: Schedule Tasks must read like Activity: one header per workspace,
        // with that workspace's tasks and Bot schedules together under it.
        let elephant = Workspace(name: "elephant", cwd: "/tmp", layout: .pane(PaneNode(surfaces: [])))
        let blog = Workspace(name: "blog", cwd: "/tmp", layout: .pane(PaneNode(surfaces: [])))
        let missing = WorkspaceID()
        func task(_ ws: WorkspaceID) -> ScheduledTask { ScheduledTask(
            title: "t", prompt: "p", workspaceID: ws, workspacePathSnapshot: "/tmp", runAsUser: "u", runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "m", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1), timeZoneIdentifier: "UTC") }
        func bot(_ ws: WorkspaceID?) -> BotScheduleTaskItem {
            var definition = BotDefinition(handle: "dev", name: "Developer", title: "", description: "")
            definition.workspaceID = ws
            let routine = BotRoutine(
                definition: BotRoutineDefinition(botID: definition.id, name: "r", prompt: "p", scheduleNote: "Daily"),
                activation: BotRoutineActivation(routineID: BotRoutineID(), botID: definition.id, isEnabled: true))
            return BotScheduleTaskItem(routine: routine, bot: definition)
        }
        let groups = ScheduleTaskWorkspaceGroup.groups(
            tasks: [task(elephant.id), task(blog.id), task(missing)],
            botItems: [bot(elephant.id), bot(nil)],
            workspaces: [elephant, blog]
        )
        XCTAssertEqual(groups.map(\.name), ["elephant", "blog", "No workspace"])
        XCTAssertEqual(groups.map(\.entries.count), [2, 1, 2], "deleted workspace and Bot without one fall to No workspace")
    }
}
