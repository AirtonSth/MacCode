import XCTest
import CoreModel
@testable import Persistence

final class BotSelfConfigTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: BotStore!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
    }

    override func tearDown() {
        store = nil
        db = nil
    }

    func test_standingStarterNamesLiveSelfConfigTools_becauseDeskAlreadyAdmitsThem() {
        // WHY: Generated soul must name the same tools the MCP catalog
        // exposes. A drift here means first-chat "remember this" calls a
        // name the server does not have.
        XCTAssertEqual(BotStandingInstructions.rememberFactTool, BotSelfConfigCatalog.putMemory)
        XCTAssertEqual(BotStandingInstructions.changeJobTool, BotSelfConfigCatalog.setSettings)
        XCTAssertEqual(BotStandingInstructions.forgetFactTool, BotSelfConfigCatalog.forgetMemory)
        XCTAssertEqual(BotStandingInstructions.setSkillTool, BotSelfConfigCatalog.setSkill)
        XCTAssertEqual(BotStandingInstructions.saveRoutineTool, BotSelfConfigCatalog.saveRoutine)
        XCTAssertEqual(BotStandingInstructions.setRoutineEnabledTool, BotSelfConfigCatalog.setRoutineEnabled)
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.putMemory))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.setSettings))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.forgetMemory))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.setSkill))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.saveRoutine))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.setRoutineEnabled))
        XCTAssertFalse(tools.contains(BotSelfConfigCatalog.getSettings))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(BotSelfConfigCatalog.putMemory),
            "tools layer owns self-config names"
        )
    }

    func test_callUsesLiveCatalogAndPersistsThroughPublish() throws {
        // WHY: Studio Save and the bot self-config surface must share one persist path.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        XCTAssertEqual(Set(BotSelfConfigCatalog.toolNames), [
            BotSelfConfigCatalog.getSettings,
            BotSelfConfigCatalog.setSettings,
            BotSelfConfigCatalog.putMemory,
            BotSelfConfigCatalog.forgetMemory,
            BotSelfConfigCatalog.setSkill,
            BotSelfConfigCatalog.saveRoutine,
            BotSelfConfigCatalog.setRoutineEnabled,
        ])

        let before = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(before.name, "Piper")
        XCTAssertEqual(before.soul, "Be brief.")
        XCTAssertEqual(before.provider, AgentProvider.claude.rawValue)
        XCTAssertEqual(before.handle, "piper")
        XCTAssertTrue(before.notificationsEnabled)

        let afterSet = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
            "soul": "Speak plainly.",
            "provider": AgentProvider.grok.rawValue,
            "model": "grok-4",
            "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            "desktop_kind": BotDesktopKind.logicalExecutionSpace.rawValue,
            "notifications_enabled": false,
        ])
        XCTAssertEqual(afterSet.name, "Piper Prime")
        XCTAssertEqual(afterSet.soul, "Speak plainly.")
        XCTAssertEqual(afterSet.provider, AgentProvider.grok.rawValue)
        XCTAssertEqual(afterSet.model, "grok-4")
        // leftover full_access is not live — Desk launches supervised
        XCTAssertEqual(afterSet.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(afterSet.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertFalse(afterSet.notificationsEnabled)
        XCTAssertEqual(try store.get(id: bot.id)?.name, "Piper Prime")
        XCTAssertEqual(try store.get(id: bot.id)?.notificationsEnabled, false)

        let withMemory = try service.call(name: BotSelfConfigCatalog.putMemory, arguments: [
            "content": "Prefers dark mode",
        ])
        XCTAssertEqual(withMemory.memory.map(\.content), ["Prefers dark mode"])
        let memoryID = try XCTUnwrap(withMemory.memory.first?.id)

        let withSkill = try service.call(name: BotSelfConfigCatalog.setSkill, arguments: [
            "skill_id": "weekly-account-health",
            "enabled": true,
        ])
        XCTAssertEqual(withSkill.skills.map(\.skillID), ["weekly-account-health"])
        XCTAssertEqual(withSkill.skills.first?.enabled, true)

        let withRoutine = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "name": "Morning",
            "prompt": "Summarize overnight",
            "schedule_note": "daily",
        ])
        XCTAssertEqual(withRoutine.routines.count, 1)
        XCTAssertEqual(withRoutine.routines[0].name, "Morning")
        XCTAssertEqual(withRoutine.routines[0].prompt, "Summarize overnight")
        let routineID = withRoutine.routines[0].id

        let enabled = try service.call(name: BotSelfConfigCatalog.setRoutineEnabled, arguments: [
            "routine_id": routineID,
            "enabled": true,
        ])
        XCTAssertEqual(enabled.routines.first?.enabled, true)

        let forgotten = try service.call(name: BotSelfConfigCatalog.forgetMemory, arguments: [
            "memory_id": memoryID,
        ])
        XCTAssertTrue(forgotten.memory.isEmpty)

        let reread = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(reread.name, "Piper Prime")
        XCTAssertEqual(reread.soul, "Speak plainly.")
        XCTAssertEqual(reread.provider, AgentProvider.grok.rawValue)
        XCTAssertTrue(reread.memory.isEmpty)
        XCTAssertEqual(reread.skills.first?.enabled, true)
        XCTAssertEqual(reread.routines.first?.enabled, true)
    }

    func test_callRejectsAnotherBotId() throws {
        // WHY: a bot must not rewrite a sibling bot's Studio state.
        let caller = try store.create(name: "Alpha", title: "", description: "", provider: .claude)
        let other = try store.create(name: "Beta", title: "", description: "", provider: .codex)
        let service = BotSelfConfigService(callerBotID: caller.id, store: store)
        XCTAssertThrowsError(
            try service.call(
                name: BotSelfConfigCatalog.getSettings,
                arguments: ["bot_id": other.id.value.uuidString]
            )
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .crossBot)
        }
        XCTAssertThrowsError(
            try service.call(
                name: BotSelfConfigCatalog.setSettings,
                arguments: ["bot_id": other.id.value.uuidString, "name": "Hijacked"]
            )
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .crossBot)
        }
        XCTAssertEqual(try store.get(id: other.id)?.name, "Beta")
    }

    func test_makeRequiresCallerEnvironment() throws {
        let bot = try store.create(name: "Piper", title: "", description: "", provider: .claude)
        XCTAssertThrowsError(try BotSelfConfigService.make(environment: [:], store: store)) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .callerMissing)
        }
        let service = try BotSelfConfigService.make(
            environment: [BotSelfConfigCatalog.callerEnvironmentKey: bot.id.value.uuidString],
            store: store
        )
        XCTAssertEqual(try service.snapshot().id, bot.id.value.uuidString.lowercased())
    }

    func test_leftoverPermissionSnapshotStaysSupervised_becauseFullAccessIsNotLive() throws {
        // WHY: Brain compile already treats leftover full_access as
        // supervised. get_settings still returned the raw leftover, so
        // first-chat "just write the file" via bot_get_settings invented
        // unsupervised access. Hermes agents see advertised permission.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", soul: "Own the inbox.", provider: .claude)
        let currentID = try XCTUnwrap(bot.currentRevisionID)
        _ = try store.publish(
            botID: bot.id,
            expectedCurrentRevisionID: currentID,
            draft: BotRevisionDraft(
                name: "Piper",
                title: "Scout",
                description: "",
                soul: "Own the inbox.",
                provider: .claude,
                providerInstanceID: "claude",
                model: "opus",
                permissionMode: .fullAccess
            )
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let snapshot = try service.snapshot()
        XCTAssertEqual(snapshot.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertNotEqual(snapshot.permissionMode, AgentPermissionMode.fullAccess.rawValue)
        let stored = try XCTUnwrap(try store.getRevision(id: try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)))
        XCTAssertEqual(stored.permissionMode, .fullAccess)
    }

    func test_setSettingsLeftoverPermissionDoesNotAdvertiseFullAccess() throws {
        // WHY: Desk-admitted bot_set_settings used to persist leftover
        // full_access and echo it back. The model then believed it had
        // unsupervised writes. Apply must coerce like desktopKind.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let after = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "permission_mode": AgentPermissionMode.fullAccess.rawValue,
        ])
        XCTAssertEqual(after.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertFalse(after.permissionMode.contains("full_access"))
        let stored = try XCTUnwrap(try store.getRevision(id: try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)))
        XCTAssertEqual(stored.permissionMode, .supervised)
        let auto = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "permission_mode": AgentPermissionMode.autoAcceptEdits.rawValue,
        ])
        XCTAssertEqual(auto.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertFalse(auto.permissionMode.contains("auto_accept_edits"))
    }
}
