import CoreModel
import XCTest
@testable import AppShell

final class BotScheduleScopeTests: XCTestCase {
    // WHY: Bot Studio's Schedule Tasks tab must never show or count another bot's tasks.
    func test_scopedItemsExcludeOtherBots() {
        let piper = BotID()
        let scout = BotID()
        let items = [
            makeItem(botID: piper, name: "Morning scan", enabled: true),
            makeItem(botID: scout, name: "Other bot", enabled: true),
            makeItem(botID: piper, name: "Nightly", enabled: false),
        ]
        XCTAssertEqual(BotScheduleScope.items(items, botID: piper).map(\.name), ["Morning scan", "Nightly"])
    }

    // WHY: chip counts must match the search-filtered scope so the badges agree with the visible list.
    func test_scopedCountsHonorSearchAndStatus() {
        let piper = BotID()
        let items = [
            makeItem(botID: piper, name: "Morning scan", enabled: true),
            makeItem(botID: piper, name: "Nightly sweep", enabled: false),
            makeItem(botID: piper, name: "Weekly report", enabled: true),
        ]
        let all = BotScheduleScope.counts(BotScheduleScope.items(items, botID: piper), query: "")
        XCTAssertEqual(all.all, 3)
        XCTAssertEqual(all.active, 2)
        XCTAssertEqual(all.paused, 1)

        let searched = BotScheduleScope.counts(items, query: "  sweep ")
        XCTAssertEqual(searched.all, 1)
        XCTAssertEqual(searched.paused, 1)
        XCTAssertEqual(BotScheduleScope.footerLine(all: searched.all, active: searched.active), "1 task · 0 active")
    }

    // WHY: the list once rendered empty while chips said "All 2"; list and counts must read the same scoped set.
    func test_visibleListAgreesWithCounts() {
        let piper = BotID()
        let items = [
            makeItem(botID: piper, name: "Morning scan", enabled: true),
            makeItem(botID: piper, name: "Nightly sweep", enabled: false),
        ]
        let counts = BotScheduleScope.counts(items, query: "")
        XCTAssertEqual(BotScheduleScope.visible(items, query: "", filter: .all).count, counts.all)
        XCTAssertEqual(BotScheduleScope.visible(items, query: "", filter: .active).map(\.name), ["Morning scan"])
        XCTAssertEqual(BotScheduleScope.visible(items, query: "", filter: .paused).map(\.name), ["Nightly sweep"])
        XCTAssertEqual(BotScheduleScope.visible(items, query: "morning", filter: .paused).count, 0)
    }

    private func makeItem(botID: BotID, name: String, enabled: Bool) -> BotScheduleTaskItem {
        let bot = BotDefinition(id: botID, handle: "piper", name: "Piper", title: "Scout", description: "")
        let definition = BotRoutineDefinition(botID: botID, name: name, prompt: "Check failures")
        let activation = BotRoutineActivation(routineID: definition.id, botID: botID, isEnabled: enabled, updatedAt: Date())
        return BotScheduleTaskItem(routine: BotRoutine(definition: definition, activation: activation), bot: bot)
    }
}
