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
        XCTAssertEqual(BotStandingInstructions.correctFactTool, BotSelfConfigCatalog.correctMemory)
        XCTAssertEqual(BotStandingInstructions.setSkillTool, BotSelfConfigCatalog.setSkill)
        XCTAssertEqual(BotStandingInstructions.removeSkillTool, BotSelfConfigCatalog.removeSkill)
        XCTAssertEqual(BotStandingInstructions.saveRoutineTool, BotSelfConfigCatalog.saveRoutine)
        XCTAssertEqual(BotStandingInstructions.setRoutineEnabledTool, BotSelfConfigCatalog.setRoutineEnabled)
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.putMemory))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.setSettings))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.forgetMemory))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.correctMemory))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.setSkill))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.removeSkill))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.saveRoutine))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.setRoutineEnabled))
        XCTAssertFalse(tools.contains(BotSelfConfigCatalog.getSettings))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(BotSelfConfigCatalog.putMemory),
            "tools layer owns self-config names"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(BotSelfConfigCatalog.correctMemory),
            "tools layer owns correct"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(BotSelfConfigCatalog.removeSkill),
            "tools layer owns remove"
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
            BotSelfConfigCatalog.correctMemory,
            BotSelfConfigCatalog.setSkill,
            BotSelfConfigCatalog.removeSkill,
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

        let corrected = try service.call(name: BotSelfConfigCatalog.correctMemory, arguments: [
            "memory_id": memoryID,
            "content": "Prefers light mode",
        ])
        XCTAssertEqual(corrected.memory.map(\.content), ["Prefers light mode"])
        XCTAssertEqual(corrected.memory.first?.id, memoryID)

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

    func test_setSettingsCatalogOmitsLeftoverPermissionAndDesktop_becauseThoseWritesAreNotLive() {
        // WHY: Compile tools already omit leftover permission/desktop.
        // The MCP schema still invited those writes, so first-chat
        // "set full access" invented live unsupervised power.
        let description = BotSelfConfigCatalog.description(for: BotSelfConfigCatalog.setSettings)
        XCTAssertTrue(description.contains("name, job, standing instructions, description, route, or notifications"))
        XCTAssertFalse(description.contains("permission"))
        XCTAssertFalse(description.contains("desktop"))
        let schema = BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["provider"])
        XCTAssertNotNil(properties?["model"])
        XCTAssertNil(properties?["route"], "route is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["permission_mode"])
        XCTAssertNil(properties?["desktop_kind"])
        let provider = properties?["provider"] as? [String: Any]
        XCTAssertEqual(provider?["description"] as? String, "Route. Claude, Codex, or Grok.")
        let title = properties?["title"] as? [String: Any]
        let soul = properties?["soul"] as? [String: Any]
        let notify = properties?["notifications_enabled"] as? [String: Any]
        XCTAssertEqual(title?["description"] as? String, "Role / job. Same field as Studio Role.")
        XCTAssertEqual(soul?["description"] as? String, "Standing instructions.")
        XCTAssertEqual(notify?["description"] as? String, "Notifications On/Off.")
        XCTAssertNil(properties?["notifications"], "notifications is an advertised alias, not a second schema key")
    }

    func test_setSettingsAdvertisedNamesPersist_becauseToolsSayJobNotTitle() throws {
        // WHY: Tools invite job / standing instructions / notifications.
        // Parse only read title / soul / notifications_enabled, so first-chat
        // "change your job" invented a hop or left Role untouched.
        // Studio Role is the same field. Canonical keys still win.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        let fromJob = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "job": "Night scout",
        ])
        XCTAssertEqual(fromJob.title, "Night scout", "job maps to title")
        XCTAssertEqual(try store.get(id: bot.id)?.title, "Night scout")

        let fromRole = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "role": "Reviewer",
        ])
        XCTAssertEqual(fromRole.title, "Reviewer")

        let titleWins = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "title": "Lead",
            "job": "Ignored job",
            "role": "Ignored role",
        ])
        XCTAssertEqual(titleWins.title, "Lead", "title wins")

        let fromStanding = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "standing_instructions": "Own the inbox.",
        ])
        XCTAssertEqual(fromStanding.soul, "Own the inbox.")

        let soulWins = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "soul": "Speak plainly.",
            "standing_instructions": "Ignored soul",
        ])
        XCTAssertEqual(soulWins.soul, "Speak plainly.", "soul wins")

        let fromNotify = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "notifications": false,
        ])
        XCTAssertFalse(fromNotify.notificationsEnabled)

        let notifyWins = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "notifications_enabled": true,
            "notifications": false,
        ])
        XCTAssertTrue(notifyWins.notificationsEnabled, "notifications_enabled wins")
        XCTAssertEqual(try store.get(id: bot.id)?.title, "Lead")
    }

    func test_setSettingsAdvertisedOnOffPersist_becauseStudioSaysOnNotTrue() throws {
        // WHY: Studio summary and the schema already say On/Off.
        // ParseBool only read true/1/yes, so first-chat "turn notifications
        // Off" invented a hop or left the leftover switch. Canonical bool
        // still wins. Schema does not grow a notifications key.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        let fromOff = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "notifications": "Off",
        ])
        XCTAssertFalse(fromOff.notificationsEnabled, "Off persists")
        XCTAssertEqual(try store.get(id: bot.id)?.notificationsEnabled, false)

        let fromOn = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "notifications": "On",
        ])
        XCTAssertTrue(fromOn.notificationsEnabled, "On persists")
        XCTAssertEqual(try store.get(id: bot.id)?.notificationsEnabled, true)

        let boolWins = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "notifications_enabled": false,
            "notifications": "On",
        ])
        XCTAssertFalse(boolWins.notificationsEnabled, "notifications_enabled wins")
    }

    func test_setSettingsProviderWithoutModelBindsAdvertisedRoute_becauseLeftoverModelIsNotLive() throws {
        // WHY: Desk-admitted bot_set_settings already publishes route.
        // A provider-only write kept opus on Grok and the leftover
        // Claude account id, so first-chat "switch to Grok" invented a hop
        // or ran the old route. Studio picker already binds the default.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", soul: "Be brief.", provider: .claude, model: "opus")
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let after = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "provider": AgentProvider.grok.rawValue,
        ])
        XCTAssertEqual(after.provider, AgentProvider.grok.rawValue)
        XCTAssertEqual(after.model, BotRoute.defaultModel(for: .grok))
        XCTAssertEqual(after.providerInstanceID, AgentProvider.grok.rawValue)
        XCTAssertNotEqual(after.model, "opus")
        XCTAssertNotEqual(after.providerInstanceID, AgentProvider.claude.rawValue)
        let explicit = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "provider": AgentProvider.claude.rawValue,
            "model": "sonnet",
            "provider_instance_id": "claude-work",
        ])
        XCTAssertEqual(explicit.provider, AgentProvider.claude.rawValue)
        XCTAssertEqual(explicit.model, "sonnet")
        XCTAssertEqual(explicit.providerInstanceID, "claude-work")
        let modelOnly = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "model": "opus",
        ])
        XCTAssertEqual(modelOnly.provider, AgentProvider.claude.rawValue)
        XCTAssertEqual(modelOnly.model, "opus")
        XCTAssertEqual(modelOnly.providerInstanceID, "claude-work")
    }

    func test_setSettingsAdvertisedRouteNamesPersist_becauseToolsSayGrokNotRawId() throws {
        // WHY: Tools invite route. Studio and compile say Claude / Codex /
        // Grok. Parse only read provider raw values, so first-chat
        // "switch to Grok" invented a hop or left opus. Canonical
        // provider still wins. Explicit model still wins.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        let fromTitle = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "provider": "Grok",
        ])
        XCTAssertEqual(fromTitle.provider, AgentProvider.grok.rawValue)
        XCTAssertEqual(fromTitle.model, BotRoute.defaultModel(for: .grok))

        let fromRoute = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "route": "Claude",
        ])
        XCTAssertEqual(fromRoute.provider, AgentProvider.claude.rawValue)
        XCTAssertEqual(fromRoute.model, BotRoute.defaultModel(for: .claude))

        let providerWins = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "provider": "codex",
            "route": "Grok",
        ])
        XCTAssertEqual(providerWins.provider, AgentProvider.codex.rawValue, "provider wins")
        XCTAssertEqual(providerWins.model, BotRoute.defaultModel(for: .codex))

        let fromCompiled = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "route": "Grok · grok-4.6",
        ])
        XCTAssertEqual(fromCompiled.provider, AgentProvider.grok.rawValue)
        XCTAssertEqual(fromCompiled.model, "grok-4.6")

        let modelWins = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "provider": "Claude",
            "model": "sonnet",
        ])
        XCTAssertEqual(modelWins.provider, AgentProvider.claude.rawValue)
        XCTAssertEqual(modelWins.model, "sonnet")

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "route": "ChatGPT",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid("Unknown provider: ChatGPT"))
        }
    }

    func test_saveRoutineAdvertisedNamesPersist_becauseStudioSaysInstructionAndWhen() throws {
        // WHY: Tools and Studio say Instruction / When. Parse only read
        // prompt / schedule_note, so first-chat "change the instruction"
        // invented a hop or left the leftover prompt. Canonical keys
        // still win. Schema does not grow a second pair of keys.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        let fromAdvertised = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "name": "Morning",
            "instruction": "Summarize overnight",
            "when": "Weekdays 9:00",
        ])
        XCTAssertEqual(fromAdvertised.routines.count, 1)
        XCTAssertEqual(fromAdvertised.routines[0].prompt, "Summarize overnight")
        XCTAssertEqual(fromAdvertised.routines[0].scheduleNote, "Weekdays 9:00")
        let stored = try store.listRoutines(botID: bot.id)
        XCTAssertEqual(stored.first?.definition.prompt, "Summarize overnight")
        XCTAssertEqual(stored.first?.definition.scheduleNote, "Weekdays 9:00")

        let promptWins = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "routine_id": fromAdvertised.routines[0].id,
            "name": "Morning",
            "prompt": "Scan PRs",
            "instruction": "Ignored instruction",
            "schedule_note": "Daily",
            "when": "Ignored when",
        ])
        XCTAssertEqual(promptWins.routines[0].prompt, "Scan PRs", "prompt wins")
        XCTAssertEqual(promptWins.routines[0].scheduleNote, "Daily", "schedule_note wins")
    }

    func test_saveRoutineCatalogDescribesInstructionAndWhen_becauseThoseAreTheStudioFields() {
        // WHY: Schema key stays prompt / schedule_note. Description must
        // name Instruction / When so first-chat does not invent a hop.
        let description = BotSelfConfigCatalog.description(for: BotSelfConfigCatalog.saveRoutine)
        XCTAssertTrue(description.contains("instruction"))
        XCTAssertTrue(description.contains("when"))
        XCTAssertTrue(description.contains("Studio Save routine"))
        let schema = BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.saveRoutine)
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["prompt"])
        XCTAssertNotNil(properties?["schedule_note"])
        XCTAssertNil(properties?["instruction"], "instruction is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["when"], "when is an advertised alias, not a second schema key")
        let prompt = properties?["prompt"] as? [String: Any]
        let when = properties?["schedule_note"] as? [String: Any]
        XCTAssertEqual(prompt?["description"] as? String, "Instruction. Same field as Studio Instruction.")
        XCTAssertEqual(when?["description"] as? String, "When. Same field as Studio When.")
    }

    func test_putMemoryAdvertisedFactPersists_becauseStudioSaysRememberAFact() throws {
        // WHY: Tools and Studio say Remember a fact. Parse only read
        // content, so first-chat "remember this fact" invented a hop or
        // dropped the row. Canonical content still wins. Schema does not
        // grow a second key.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        let fromFact = try service.call(name: BotSelfConfigCatalog.putMemory, arguments: [
            "fact": "Prefers dark mode",
        ])
        XCTAssertEqual(fromFact.memory.map(\.content), ["Prefers dark mode"])
        XCTAssertEqual(try store.listMemory(botID: bot.id).map(\.content), ["Prefers dark mode"])

        let contentWins = try service.call(name: BotSelfConfigCatalog.putMemory, arguments: [
            "content": "Prefers light mode",
            "fact": "Ignored fact",
        ])
        XCTAssertEqual(contentWins.memory.map(\.content), ["Prefers dark mode", "Prefers light mode"])
        XCTAssertEqual(contentWins.memory.last?.content, "Prefers light mode", "content wins")

        let memoryID = try XCTUnwrap(fromFact.memory.first?.id)
        let corrected = try service.call(name: BotSelfConfigCatalog.correctMemory, arguments: [
            "memory_id": memoryID,
            "fact": "Prefers dusk",
        ])
        XCTAssertEqual(corrected.memory.first(where: { $0.id == memoryID })?.content, "Prefers dusk")

        let correctContentWins = try service.call(name: BotSelfConfigCatalog.correctMemory, arguments: [
            "memory_id": memoryID,
            "content": "Prefers dawn",
            "fact": "Ignored correction",
        ])
        XCTAssertEqual(
            correctContentWins.memory.first(where: { $0.id == memoryID })?.content,
            "Prefers dawn",
            "content wins"
        )
    }

    func test_putMemoryCatalogDescribesFact_becauseThatIsTheStudioField() {
        // WHY: Schema key stays content. Description must name Fact so
        // first-chat does not invent a hop.
        let description = BotSelfConfigCatalog.description(for: BotSelfConfigCatalog.putMemory)
        XCTAssertTrue(description.contains("fact"))
        let putSchema = BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.putMemory)
        let putProperties = putSchema["properties"] as? [String: Any]
        XCTAssertNotNil(putProperties?["content"])
        XCTAssertNil(putProperties?["fact"], "fact is an advertised alias, not a second schema key")
        let putContent = putProperties?["content"] as? [String: Any]
        XCTAssertEqual(putContent?["description"] as? String, "Fact. Same field as Studio Remember a fact.")

        let correctSchema = BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.correctMemory)
        let properties = correctSchema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["content"])
        XCTAssertNil(properties?["fact"], "fact is an advertised alias, not a second schema key")
        let content = properties?["content"] as? [String: Any]
        XCTAssertEqual(content?["description"] as? String, "Fact. Same field as Studio Remember a fact.")
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

    func test_correctMemoryKeepsId_becauseStudioCorrectDoesNotMintANewFact() throws {
        // WHY: Studio Correct writes a revision on the same fact.
        // Tools never named that path, so first-chat "correct this"
        // invented forget+put and lost the id. Hermes agents update
        // memory in place.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let created = try service.call(name: BotSelfConfigCatalog.putMemory, arguments: [
            "content": "Prefers dark mode",
        ])
        let memoryID = try XCTUnwrap(created.memory.first?.id)
        let after = try service.call(name: BotSelfConfigCatalog.correctMemory, arguments: [
            "memory_id": memoryID,
            "content": "Prefers light mode",
        ])
        XCTAssertEqual(after.memory.count, 1)
        XCTAssertEqual(after.memory.first?.id, memoryID)
        XCTAssertEqual(after.memory.first?.content, "Prefers light mode")
        let itemID = BotMemoryItemID(try XCTUnwrap(UUID(uuidString: memoryID)))
        let revisions = try store.listMemoryRevisions(itemID: itemID)
        XCTAssertEqual(revisions.map(\.content), ["Prefers dark mode", "Prefers light mode"])
    }

    func test_correctMemoryRejectedWhenForgotten_becauseTombstonesAreNotRewritable() throws {
        // WHY: Studio Correct cannot rewrite a forgotten fact. The new
        // tool must fail the same way instead of minting a live row.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let created = try service.call(name: BotSelfConfigCatalog.putMemory, arguments: [
            "content": "Old secret",
        ])
        let memoryID = try XCTUnwrap(created.memory.first?.id)
        _ = try service.call(name: BotSelfConfigCatalog.forgetMemory, arguments: [
            "memory_id": memoryID,
        ])
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.correctMemory, arguments: [
                "memory_id": memoryID,
                "content": "Still secret",
            ])
        ) { error in
            XCTAssertEqual(
                error as? BotStoreError,
                .invalidRow("forgotten memory cannot be rewritten")
            )
        }
        XCTAssertTrue(try service.snapshot().memory.isEmpty)
    }

    func test_removeSkillDropsBinding_becauseDisableIsNotUnbind() throws {
        // WHY: Studio Remove deletes the catalog row. Tools only named
        // enable/disable, so first-chat "remove this skill" invented
        // disable and left the id bound. Disable is not unbind.
        // Hermes agents unbind in place.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        _ = try service.call(name: BotSelfConfigCatalog.setSkill, arguments: [
            "skill_id": "keep-me",
            "enabled": true,
        ])
        _ = try service.call(name: BotSelfConfigCatalog.setSkill, arguments: [
            "skill_id": "drop-me",
            "enabled": true,
        ])
        let disabled = try service.call(name: BotSelfConfigCatalog.setSkill, arguments: [
            "skill_id": "drop-me",
            "enabled": false,
        ])
        XCTAssertEqual(Set(disabled.skills.map(\.skillID)), ["keep-me", "drop-me"])
        XCTAssertEqual(disabled.skills.first(where: { $0.skillID == "drop-me" })?.enabled, false)
        let removed = try service.call(name: BotSelfConfigCatalog.removeSkill, arguments: [
            "skill_id": "drop-me",
        ])
        XCTAssertEqual(removed.skills.map(\.skillID), ["keep-me"])
        XCTAssertEqual(try store.listSkillBindings(botID: bot.id).map(\.skillID), ["keep-me"])
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.removeSkill, arguments: [
                "skill_id": "drop-me",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .notFound)
        }
    }

    func test_removeSkillRejectedWhenPath_becauseCatalogIdsAreNotFilesystemPaths() throws {
        // WHY: Studio Add already rejects paths. Unbind must fail the same
        // way instead of pretending a path is a live catalog id.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.removeSkill, arguments: [
                "skill_id": "/tmp/skill.md",
            ])
        ) { error in
            XCTAssertEqual(
                error as? BotStoreError,
                .invalidRow("skill id must be a catalog id, not a path")
            )
        }
        XCTAssertTrue(try service.snapshot().skills.isEmpty)
    }
}
