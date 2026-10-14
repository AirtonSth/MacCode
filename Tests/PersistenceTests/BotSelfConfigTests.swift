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
        XCTAssertEqual(BotStandingInstructions.rememberFactTool, BotSelfConfigCatalog.writeHomeFile)
        XCTAssertEqual(BotStandingInstructions.changeJobTool, BotSelfConfigCatalog.setSettings)
        XCTAssertEqual(BotStandingInstructions.forgetFactTool, BotSelfConfigCatalog.writeHomeFile)
        XCTAssertEqual(BotStandingInstructions.correctFactTool, BotSelfConfigCatalog.writeHomeFile)
        XCTAssertEqual(BotStandingInstructions.setSkillTool, BotSelfConfigCatalog.setSkill)
        XCTAssertEqual(BotStandingInstructions.removeSkillTool, BotSelfConfigCatalog.removeSkill)
        XCTAssertEqual(BotStandingInstructions.saveRoutineTool, BotSelfConfigCatalog.saveRoutine)
        XCTAssertEqual(BotStandingInstructions.setRoutineEnabledTool, BotSelfConfigCatalog.setRoutineEnabled)
        XCTAssertEqual(BotStandingInstructions.listSecretsTool, BotSelfConfigCatalog.listSecrets)
        XCTAssertEqual(BotStandingInstructions.saveSecretTool, BotSelfConfigCatalog.saveSecret)
        XCTAssertEqual(BotStandingInstructions.deleteSecretTool, BotSelfConfigCatalog.deleteSecret)
        XCTAssertEqual(BotStandingInstructions.getSettingsTool, BotSelfConfigCatalog.getSettings)
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.writeHomeFile))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.setSettings))
        XCTAssertFalse(tools.contains(BotSelfConfigCatalog.putMemory))
        XCTAssertFalse(tools.contains(BotSelfConfigCatalog.forgetMemory))
        XCTAssertFalse(tools.contains(BotSelfConfigCatalog.correctMemory))
        XCTAssertFalse(tools.contains(BotSelfConfigCatalog.setSkill))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.removeSkill))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.saveRoutine))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.setRoutineEnabled))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.listSecrets))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.saveSecret))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.deleteSecret))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.skillView))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.recall))
        XCTAssertTrue(tools.contains(BotSelfConfigCatalog.askUser))
        XCTAssertFalse(tools.contains(BotSelfConfigCatalog.getSettings))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(BotSelfConfigCatalog.writeHomeFile),
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
            BotSelfConfigCatalog.listSecrets,
            BotSelfConfigCatalog.saveSecret,
            BotSelfConfigCatalog.deleteSecret,
            BotSelfConfigCatalog.writeHomeFile,
            BotSelfConfigCatalog.removeSkill,
            BotSelfConfigCatalog.saveRoutine,
            BotSelfConfigCatalog.setRoutineEnabled,
            BotSelfConfigCatalog.skillView,
            BotSelfConfigCatalog.recall,
            BotSelfConfigCatalog.askUser,
            BotSelfConfigCatalog.listPeers,
            BotSelfConfigCatalog.askPeer,
        ])

        let before = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(before.name, "Piper")
        XCTAssertEqual(before.soul, "Be brief.")
        XCTAssertEqual(before.handle, "piper")
        XCTAssertTrue(before.notificationsEnabled)

        let afterSet = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
            "soul": "Speak plainly.",
            "notifications_enabled": false,
        ])
        XCTAssertEqual(afterSet.name, "Piper Prime")
        XCTAssertEqual(afterSet.soul, "Speak plainly.")
        // leftover full_access is not live — Desk launches supervised
        XCTAssertEqual(afterSet.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(afterSet.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertFalse(afterSet.notificationsEnabled)
        XCTAssertEqual(try store.get(id: bot.id)?.name, "Piper Prime")
        XCTAssertEqual(try store.get(id: bot.id)?.notificationsEnabled, false)

        let withMemory = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers dark mode\n",
        ])
        XCTAssertTrue(withMemory.memory.contains(where: { $0.id == "MEMORY.md" && $0.content.contains("Prefers dark mode") }))

        let corrected = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers light mode\n",
        ])
        XCTAssertTrue(corrected.memory.contains(where: { $0.id == "MEMORY.md" && $0.content.contains("Prefers light mode") }))
        XCTAssertFalse(corrected.memory.contains(where: { $0.content.contains("Prefers dark mode") }))

        let withSkill = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "skills/weekly-invoice/SKILL.md",
            "contents": "Invoice the week.\n",
        ])
        XCTAssertEqual(withSkill.skills.map(\.skillID), ["weekly-invoice"])
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

        let forgotten = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "# Memory\n\n",
        ])
        XCTAssertTrue(forgotten.memory.contains(where: { $0.id == "MEMORY.md" }))
        XCTAssertFalse(forgotten.memory.contains(where: { $0.content.contains("Prefers light mode") }))

        let reread = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(reread.name, "Piper Prime")
        XCTAssertEqual(reread.soul, "Speak plainly.")
        XCTAssertFalse(reread.memory.contains(where: { $0.content.contains("Prefers light mode") }))
        XCTAssertEqual(reread.skills.map(\.skillID), ["weekly-invoice"])
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
        XCTAssertTrue(description.contains("name, Role, Instructions, description, notifications, or avatar"))
        XCTAssertFalse(description.contains("job, standing instructions"), "leftover job is not advertised")
        XCTAssertFalse(description.contains("permission"))
        XCTAssertFalse(description.contains("desktop"))
        let schema = BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNil(properties?["provider"], "provider belongs to the calling thread")
        XCTAssertNil(properties?["provider_instance_id"], "provider account belongs to the calling thread")
        XCTAssertNil(properties?["model"], "model belongs to the calling thread")
        XCTAssertNotNil(properties?["avatar_symbol"])
        XCTAssertNil(properties?["route"], "route is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["default_route"], "default_route is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["avatar"], "avatar is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["permission_mode"])
        XCTAssertNil(properties?["desktop_kind"])
        let title = properties?["title"] as? [String: Any]
        let soul = properties?["soul"] as? [String: Any]
        let notify = properties?["notifications_enabled"] as? [String: Any]
        let avatar = properties?["avatar_symbol"] as? [String: Any]
        XCTAssertEqual(title?["description"] as? String, "Role / job. Same field as Studio Role.")
        XCTAssertEqual(soul?["description"] as? String, "Instructions. Same field as Studio Instructions.")
        XCTAssertEqual(notify?["description"] as? String, "Notifications On/Off.")
        XCTAssertEqual(avatar?["description"] as? String, "Avatar. Same field as Studio Avatar.")
        XCTAssertNil(properties?["notifications"], "notifications is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["instructions"], "instructions is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["standing_instructions"], "standing_instructions is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["fallback"], "fallback is not a schema key")
        XCTAssertNil(properties?["fallback_order"], "fallback_order is not a schema key")
        XCTAssertNil(properties?["handle"], "handle is create-only, not a schema key")
        XCTAssertNil(properties?["id"], "id is leftover snapshot identity, not a schema write key")
        XCTAssertNil(properties?["identity"], "identity is advertised dest title, not a schema write key")
        XCTAssertNil(properties?["workspace"], "workspace is host-assigned, not a schema key")
        XCTAssertNil(properties?["working_space"], "working_space is not a schema key")
        XCTAssertNil(properties?["cwd"], "cwd is not a schema key")
        XCTAssertNil(properties?["approval"], "approval is not a schema key")
        XCTAssertNil(properties?["approval_mode"], "approval_mode is host-assigned, not a schema key")
        XCTAssertNil(properties?["permission"], "permission is dest title, not a schema key")
        XCTAssertNil(properties?["supervised"], "supervised is advertised Approval mode value, not a schema key")
        XCTAssertNil(properties?["ask_before_tool_actions"], "ask_before_tool_actions is advertised honesty, not a schema key")
        XCTAssertNil(properties?["ask_before"], "ask_before is advertised honesty, not a schema key")
        XCTAssertNil(properties?["tool_actions"], "tool_actions is advertised honesty, not a schema key")
        XCTAssertNil(properties?["desktop"], "desktop is host-assigned, not a schema key")
        XCTAssertNil(properties?["approvals"], "approvals is not a schema key")
        XCTAssertNil(properties?["allow_once"], "allow_once is not a schema key")
        XCTAssertNil(properties?["deny"], "deny is not a schema key")
        XCTAssertNil(properties?["host_brokered_writes"], "host_brokered_writes is not a schema key")
        XCTAssertNil(properties?["host_brokered"], "host_brokered is not a schema key")
        XCTAssertNil(properties?["effects"], "effects is not a schema key")
        XCTAssertNil(properties?["test_run"], "test_run is not a schema key")
        XCTAssertNil(properties?["test_run_requested"], "test_run_requested is not a schema key")
        XCTAssertNil(properties?["last_test_run_requested_at"], "last_test_run_requested_at is not a schema key")
        XCTAssertNil(properties?["memory"], "memory is not a schema key")
        XCTAssertNil(properties?["fact"], "fact is an advertised put_memory alias, not a set_settings key")
        XCTAssertNil(properties?["remember"], "remember is not a schema key")
        XCTAssertNil(properties?["remember_a_fact"], "remember_a_fact is not a schema key")
        XCTAssertNil(properties?["memory_id"], "memory_id is leftover snapshot identity, not a set_settings key")
        XCTAssertNil(properties?["content"], "content is leftover snapshot fact, not a set_settings key")
        XCTAssertNil(properties?["forget"], "forget is an advertised forget_memory alias, not a set_settings key")
        XCTAssertNil(properties?["forget_memory"], "forget_memory is not a set_settings key")
        XCTAssertNil(properties?["forgotten"], "forgotten is not a set_settings key")
        XCTAssertNil(properties?["correct"], "correct is an advertised correct_memory alias, not a set_settings key")
        XCTAssertNil(properties?["correct_memory"], "correct_memory is not a set_settings key")
        XCTAssertNil(properties?["correct_fact"], "correct_fact is not a set_settings key")
        XCTAssertNil(properties?["skills"], "skills is not a schema key")
        XCTAssertNil(properties?["skill"], "skill is an advertised set_skill alias, not a set_settings key")
        XCTAssertNil(properties?["skill_id"], "skill_id is a set_skill key, not a set_settings key")
        XCTAssertNil(properties?["add_skill"], "add_skill is not a schema key")
        XCTAssertNil(properties?["add"], "add is an advertised set_skill alias, not a set_settings key")
        XCTAssertNil(properties?["set_skill"], "set_skill is not a set_settings key")
        XCTAssertNil(properties?["remove"], "remove is an advertised remove_skill alias, not a set_settings key")
        XCTAssertNil(properties?["remove_skill"], "remove_skill is not a set_settings key")
        XCTAssertNil(properties?["unbind"], "unbind is not a set_settings key")
        XCTAssertNil(properties?["routines"], "routines is not a schema key")
        XCTAssertNil(properties?["routine"], "routine is an advertised save_routine alias, not a set_settings key")
        XCTAssertNil(properties?["routine_id"], "routine_id is a save_routine key, not a set_settings key")
        XCTAssertNil(properties?["save_routine"], "save_routine is not a schema key")
        XCTAssertNil(properties?["instruction"], "instruction is an advertised save_routine alias, not a set_settings key")
        XCTAssertNil(properties?["prompt"], "prompt is leftover snapshot Instruction, not a set_settings key")
        XCTAssertNil(properties?["when"], "when is an advertised save_routine alias, not a set_settings key")
        XCTAssertNil(properties?["active"], "active is an advertised set_routine_enabled alias, not a set_settings key")
        XCTAssertNil(properties?["enabled"], "enabled is a leftover set_routine_enabled key, not a set_settings key")
        XCTAssertNil(properties?["on"], "on is a leftover Active alias, not a set_settings key")
        XCTAssertNil(properties?["off"], "off is a leftover Active alias, not a set_settings key")
        XCTAssertNil(properties?["website"], "website is an advertised bot_browser_open alias, not a set_settings key")
        XCTAssertNil(properties?["url"], "url is a leftover bot_browser_open key, not a set_settings key")
        XCTAssertNil(properties?["last_website"], "last_website is an advertised compile name, not a set_settings key")
        XCTAssertNil(properties?["browser"], "browser is an advertised compile heading, not a set_settings key")
        XCTAssertNil(properties?["open"], "open is an advertised bot_browser_open verb, not a set_settings key")
        XCTAssertNil(properties?["open_website"], "open_website is an advertised bot_browser_open alias, not a set_settings key")
        XCTAssertNil(properties?["bot_browser_open"], "bot_browser_open is the catalog name, not a set_settings key")
        XCTAssertNil(properties?["logical_execution_space"], "logical_execution_space is an advertised compile title, not a set_settings key")
        XCTAssertNil(properties?["logical_space"], "logical_space is an advertised Desktop pill, not a set_settings key")
        XCTAssertNil(properties?["same_macos_account"], "same_macos_account is advertised Desktop honesty, not a schema key")
        XCTAssertNil(properties?["macos_account"], "macos_account is advertised Desktop honesty, not a schema key")
        XCTAssertNil(properties?["same_account"], "same_account is advertised Desktop honesty, not a schema key")
        XCTAssertNil(properties?["isolated"], "isolated is advertised Desktop honesty, not a schema key")
        XCTAssertNil(properties?["not_isolated"], "not_isolated is advertised Desktop honesty, not a schema key")
        XCTAssertNil(properties?["isolated_desktop"], "isolated_desktop is advertised Desktop honesty, not a schema key")
        XCTAssertNil(properties?["dedicated"], "dedicated is advertised Desktop honesty, not a schema key")
        XCTAssertNil(properties?["not_dedicated"], "not_dedicated is advertised Desktop honesty, not a schema key")
        XCTAssertNil(properties?["dedicated_desktop"], "dedicated_desktop is advertised Desktop honesty, not a schema key")
        XCTAssertNil(properties?["admitted_tools"], "admitted_tools is advertised dest title, not a schema write key")
        XCTAssertNil(properties?["tools"], "tools is leftover dest layer id, not a schema write key")
        XCTAssertNil(properties?["admitted"], "admitted is leftover dest title first word, not a schema write key")
        XCTAssertNil(properties?["user_request"], "user_request is advertised dest title, not a schema write key")
        XCTAssertNil(properties?["user_text"], "user_text is leftover compose name, not a schema write key")
        XCTAssertTrue(description.contains(BotSelfConfigCatalog.providerRoutingHonesty), "catalog says routing belongs to the caller thread")
        XCTAssertTrue(description.contains(BotBrainCompiler.handleCreateOnlyHonesty), "catalog names Handle create-only honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.workspaceHostAssignedHonesty), "catalog names Workspace host-assigned honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.approvalModeHostAssignedHonesty), "catalog names Approval mode host-assigned honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.approvalsHonesty), "catalog names Approvals honesty")
        XCTAssertTrue(description.contains(BotPermission.honestyLabel), "catalog names Host-brokered writes honesty")
        XCTAssertTrue(description.contains(BotDesktopKind.logicalExecutionSpaceHonestyLabel), "catalog names Desktop isolation honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.testRunHonesty), "catalog names Test run honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.memoryHonesty), "catalog names Memory honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.forgetHonesty), "catalog names Forget honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.correctHonesty), "catalog names Correct honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.skillsHonesty), "catalog names Skills honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.removeHonesty), "catalog names Remove honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.routinesHonesty), "catalog names Routines honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.instructionHonesty), "catalog names Instruction honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.whenHonesty), "catalog names When honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.activeHonesty), "catalog names Active honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.websiteHonesty), "catalog names Website honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.userRequestHonesty), "catalog names User request honesty")
    }

    func test_setSettingsRejectsProviderRouting_becauseRouteBelongsToCallingThread() throws {
        // WHY: provider, model, and fallback are thread choices. Accepting any
        // of them as Bot settings would silently recreate a callee-owned route.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief."
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "fallback_order": "Grok, Claude",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotSelfConfigCatalog.providerRoutingHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Fallback order": "Grok then Claude",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotSelfConfigCatalog.providerRoutingHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "provider": "Grok",
                "fallback": "Claude",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotSelfConfigCatalog.providerRoutingHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "default_route": "Grok",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotSelfConfigCatalog.providerRoutingHonesty))
        }
    }

    func test_setSettingsRejectsAdvertisedHandle_becauseStudioSaysItIsCreateOnly() throws {
        // WHY: Studio Handle is create-only after first save. Compile
        // already labels that honesty. set_settings still accepted
        // handle as an empty success, so first-chat "change your handle"
        // invented a persist. Reject the advertised name. Name still
        // persists. Schema does not grow a handle key.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        XCTAssertEqual(try store.get(id: bot.id)?.handle, "piper")

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "handle": "night-piper",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.handleCreateOnlyHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Handle": "night-piper",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.handleCreateOnlyHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "@handle": "night-piper",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.handleCreateOnlyHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.handle, "piper", "Handle reject must not persist a handle")
        XCTAssertEqual(still.name, "Piper", "Handle reject must not persist a name")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.handle, "piper", "Name persist must leave handle")
        XCTAssertEqual(try store.get(id: bot.id)?.handle, "piper")
    }

    func test_setSettingsRejectsAdvertisedWorkspace_becauseStudioSaysItIsHostAssigned() throws {
        // WHY: Studio already shows Workspace. Compile already labels
        // host-assigned honesty. set_settings still accepted workspace /
        // cwd as an empty success, so first-chat "use this Workspace"
        // invented a persist. Reject the advertised name. Name still
        // persists. Schema does not grow a workspace key.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "workspace": "macos-app",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Working space": "/tmp/macos-app",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "cwd": "/tmp/macos-app",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Workspace reject must not persist a name")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
    }

    func test_setSettingsRejectsAdvertisedApprovalMode_becauseStudioSaysItIsHostAssigned() throws {
        // WHY: Studio already says Approval mode. Compile already labels
        // host-assigned honesty. set_settings still accepted Approval mode
        // / approval as an empty success, so first-chat "set Approval mode
        // to full access" invented a persist. Reject the advertised name.
        // Name still persists. Leftover permission_mode now rejects.
        // Schema does not grow an approval_mode key.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "approval_mode": "full_access",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Approval mode": "full_access",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "permission": "full_access",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Approval mode reject must not persist a name")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
    }

    func test_setSettingsRejectsAdvertisedDesktop_becauseStudioSaysItIsNotASelfConfigWrite() throws {
        // WHY: Studio already says Desktop. Compile already labels
        // isolation honesty. set_settings still accepted Desktop /
        // desktop as an empty success, so first-chat "set Desktop to
        // Dedicated local VM" invented a persist. Reject the advertised
        // name. Name still persists. Leftover desktop_kind now rejects.
        // Schema does not grow a desktop key.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktop": "Dedicated local VM",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Desktop": BotDesktopKind.dedicatedLocalVM.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "desktop": "logicalExecutionSpace",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Desktop reject must not persist a name")
        XCTAssertEqual(still.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktop_kind": BotDesktopKind.dedicatedLocalVM.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertEqual(leftover.name, "Piper")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
    }

    func test_setSettingsRejectsAdvertisedApprovals_becauseStudioSaysTheyStayOff() throws {
        // WHY: Studio Security already says Approvals. Compile already
        // labels Allow once / Deny stay off. set_settings still accepted
        // Approvals / allow_once / deny as an empty success, so first-chat
        // "Allow once" invented a persist. Reject the advertised name.
        // Name still persists. Leftover permission_mode now rejects.
        // Schema does not grow an approvals key.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "approvals": "allow_once",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalsHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Approvals": "deny",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalsHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Allow once": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalsHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "deny": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalsHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Approvals reject must not persist a name")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
    }

    func test_setSettingsRejectsAdvertisedHostBrokeredWrites_becauseStudioSaysTheyStayOff() throws {
        // WHY: Studio Security already says Host-brokered writes. Compile
        // already labels they stay off. set_settings still accepted
        // Host-brokered writes / effects as an empty success, so
        // first-chat "enable Effects" invented a persist. Reject the
        // advertised name. Name still persists. Leftover permission_mode
        // now rejects. Schema does not grow a host_brokered_writes key.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "host_brokered_writes": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotPermission.honestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Host-brokered writes": "on",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotPermission.honestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Effects": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotPermission.honestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "host_brokered": "full_access",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotPermission.honestyLabel))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Host-brokered writes reject must not persist a name")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
    }

    func test_setSettingsRejectsAdvertisedTestRun_becauseStudioSaysDoTheInstructionNow() throws {
        // WHY: Studio Routines already says Test run. Compile already
        // labels when the Instruction runs. set_settings still accepted
        // Test run / test_run as an empty success, so first-chat
        // invented a persist. Reject the advertised name. Name still
        // persists. Leftover permission_mode now rejects. Schema
        // does not grow a test_run key. Dest title stays Routine.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "test_run": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.testRunHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Test run": "now",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.testRunHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "test_run_requested": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.testRunHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "last_test_run_requested_at": "now",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.testRunHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Test run reject must not persist a name")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
    }

    func test_setSettingsRejectsAdvertisedMemory_becauseStudioSaysRememberAFact() throws {
        // WHY: Studio already says Memory. Compile already labels Fact.
        // set_settings still accepted Memory / fact as an empty success,
        // so first-chat invented a persist. Reject the advertised name.
        // put_memory still persists Fact. Name still persists. Leftover
        // permission_mode now rejects. Schema does not grow a memory
        // key. Dest title stays Memory.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "memory": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "fact": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "remember": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Remember a fact": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Memory reject must not persist a name")
        XCTAssertFalse(
            still.memory.contains(where: { $0.content.contains("Prefers dark mode") }),
            "Memory reject must not persist a fact"
        )
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        let remembered = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers dark mode\n",
        ])
        XCTAssertTrue(remembered.memory.contains(where: { $0.content.contains("Prefers dark mode") }))

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")
        XCTAssertTrue(leftover.memory.contains(where: { $0.content.contains("Prefers dark mode") }))

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertTrue(renamed.memory.contains(where: { $0.content.contains("Prefers dark mode") }))
    }

    func test_setSettingsRejectsAdvertisedForget_becauseStudioSaysForgetMemory() throws {
        // WHY: Studio already says Forget. Compile already names
        // bot_forget_memory. leftover Memory / fact / memory_id already
        // reject. leftover forget still succeeded empty, so first-chat
        // invented a persist. Reject the advertised name with Forget
        // honesty, not put_memory honesty. forget_memory still persists
        // Forget. leftover Memory still rejects. Name still persists.
        // Schema does not grow a forget write key. Dest title stays
        // Memory.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let remembered = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers dark mode\n",
        ])
        let memoryID = try XCTUnwrap(remembered.memory.first?.id)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["forget"],
            "schema does not grow a forget write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "forget": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.forgetHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Forget": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.forgetHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "forget_memory": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.forgetHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "forgotten": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.forgetHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "fact": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Forget reject must not persist a name")
        XCTAssertEqual(still.memory.first?.id, memoryID)
        XCTAssertTrue(still.memory.contains(where: { $0.content.contains("Prefers dark mode") }))
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertTrue(owned.memory.contains(where: { $0.content.contains("Prefers dark mode") }))

        let forgotten = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "# Memory\n\n",
        ])
        XCTAssertFalse(
            forgotten.memory.contains(where: { $0.content.contains("Prefers dark mode") }),
            "writing MEMORY.md still owns Forget"
        )
    }

    func test_setSettingsRejectsAdvertisedCorrect_becauseStudioSaysCorrectMemory() throws {
        // WHY: Studio already says Correct. Compile already names
        // bot_correct_memory. leftover Memory / fact / memory_id / forget
        // already reject. leftover correct still succeeded empty, so
        // first-chat invented a persist. Reject the advertised name with
        // Correct honesty, not put_memory or forget_memory honesty.
        // correct_memory still persists Correct. leftover Memory / Forget
        // still reject. Name still persists. Schema does not grow a
        // correct write key. Dest title stays Memory.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let remembered = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers dark mode\n",
        ])
        let memoryID = try XCTUnwrap(remembered.memory.first?.id)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["correct"],
            "schema does not grow a correct write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "correct": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.correctHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Correct": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.correctHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "correct_memory": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.correctHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "correct_fact": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.correctHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "forget": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.forgetHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "fact": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Correct reject must not persist a name")
        XCTAssertEqual(still.memory.first?.id, memoryID)
        XCTAssertTrue(still.memory.contains(where: { $0.content.contains("Prefers dark mode") }))
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertTrue(owned.memory.contains(where: { $0.content.contains("Prefers dark mode") }))

        let corrected = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers light mode\n",
        ])
        XCTAssertEqual(corrected.memory.first?.id, memoryID, "same file path")
        XCTAssertTrue(
            corrected.memory.contains(where: { $0.content.contains("Prefers light mode") }),
            "writing MEMORY.md still owns Correct"
        )
    }

    func test_setSettingsRejectsAdvertisedSkills_becauseStudioSaysAdd() throws {
        // WHY: Studio already says Skills. Compile already labels Skills.
        // set_settings still accepted Skills / skill as an empty success,
        // so first-chat invented a persist. Reject the advertised name.
        // set_skill still persists Add. Name still persists. Leftover
        // permission_mode now rejects. Schema does not grow a skills
        // key. Dest title stays Skills.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "skills": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.skillsHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "skill": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.skillsHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "skill_id": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.skillsHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "add_skill": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.skillsHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Skills reject must not persist a name")
        XCTAssertEqual(still.skills.count, 0, "Skills reject must not persist a binding")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        let added = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "skills/weekly-account-health/SKILL.md",
            "contents": "Do the weekly health scan.\n",
        ])
        XCTAssertEqual(added.skills.first?.skillID, "weekly-account-health")
        XCTAssertEqual(added.skills.first?.enabled, true)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")
        XCTAssertEqual(leftover.skills.first?.skillID, "weekly-account-health")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(renamed.skills.first?.skillID, "weekly-account-health")
    }

    func test_setSettingsRejectsAdvertisedAdd_becauseStudioSaysAddSkill() throws {
        // WHY: Studio already says Add. Compile already names set_skill
        // / Studio Add. leftover Skills / skill / skill_id / add_skill
        // already reject. leftover add still succeeded empty, so
        // first-chat invented a persist. Reject the advertised name
        // with Skills honesty pointing at set_skill. set_skill still
        // persists Add. leftover Skills / Remove still reject. Name
        // still persists. Schema does not grow an add write key. Dest
        // title stays Skills.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["add"],
            "schema does not grow an add write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "add": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.skillsHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Add": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.skillsHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "set_skill": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.skillsHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "add_skill": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.skillsHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "remove": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.removeHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Add reject must not persist a name")
        XCTAssertEqual(still.skills.count, 0, "Add reject must not persist a binding")
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let added = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "skills/weekly-account-health/SKILL.md",
            "contents": "Do the weekly health scan.\n",
        ])
        XCTAssertEqual(added.skills.first?.skillID, "weekly-account-health", "write_home_file owns Add")
        XCTAssertEqual(added.skills.first?.enabled, true)

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.skills.first?.skillID, "weekly-account-health")
    }

    func test_setSettingsRejectsAdvertisedRemove_becauseStudioSaysRemoveSkill() throws {
        // WHY: Studio already says Remove. Compile already names
        // bot_remove_skill. leftover Skills / skill / skill_id / add_skill
        // already reject. leftover remove still succeeded empty, so
        // first-chat invented a persist. Reject the advertised name with
        // Remove honesty, not set_skill honesty. remove_skill still
        // persists Remove. leftover Skills still reject. Name still
        // persists. Schema does not grow a remove write key. Dest title
        // stays Skills.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let added = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "skills/weekly-account-health/SKILL.md",
            "contents": "Do the weekly health scan.\n",
        ])
        XCTAssertEqual(added.skills.first?.skillID, "weekly-account-health")
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["remove"],
            "schema does not grow a remove write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "remove": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.removeHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Remove": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.removeHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "remove_skill": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.removeHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "unbind": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.removeHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "skill_id": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.skillsHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Remove reject must not persist a name")
        XCTAssertEqual(still.skills.first?.skillID, "weekly-account-health")
        XCTAssertEqual(still.skills.first?.enabled, true)
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.skills.first?.skillID, "weekly-account-health")

        let removed = try service.call(name: BotSelfConfigCatalog.removeSkill, arguments: [
            "skill_id": "weekly-account-health",
        ])
        XCTAssertEqual(removed.skills.count, 0, "remove_skill still owns Remove")
    }

    func test_setSettingsRejectsAdvertisedRoutines_becauseStudioSaysSaveRoutine() throws {
        // WHY: Studio already says Routines. Compile already labels
        // Routines. set_settings still accepted Routines / routine as an
        // empty success, so first-chat invented a persist. Reject the
        // advertised name. save_routine still persists Instruction /
        // When. set_routine_enabled still persists Active. Name still
        // persists. Leftover permission_mode now rejects. Schema does
        // not grow a routines key. Dest title stays Routines.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "routines": "Morning",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.routinesHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "routine": "Morning",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.routinesHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "routine_id": "00000000-0000-0000-0000-000000000001",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.routinesHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "save_routine": "Morning",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.routinesHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Routines reject must not persist a name")
        XCTAssertEqual(still.routines.count, 0, "Routines reject must not persist a schedule")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        let saved = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "name": "Morning",
            "instruction": "Summarize overnight",
            "when": "Weekdays 9:00",
        ])
        XCTAssertEqual(saved.routines.first?.name, "Morning")
        XCTAssertEqual(saved.routines.first?.prompt, "Summarize overnight")
        XCTAssertEqual(saved.routines.first?.scheduleNote, "Weekdays 9:00")
        let routineID = try XCTUnwrap(saved.routines.first?.id)

        let activated = try service.call(name: BotSelfConfigCatalog.setRoutineEnabled, arguments: [
            "routine_id": routineID,
            "active": true,
        ])
        XCTAssertEqual(activated.routines.first?.enabled, true)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")
        XCTAssertEqual(leftover.routines.first?.name, "Morning")
        XCTAssertEqual(leftover.routines.first?.enabled, true)

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(renamed.routines.first?.name, "Morning")
        XCTAssertEqual(renamed.routines.first?.enabled, true)
    }

    func test_setSettingsRejectsAdvertisedInstruction_becauseStudioSaysSaveRoutine() throws {
        // WHY: Studio already says Instruction. Compile already labels
        // Instruction. set_settings still accepted instruction as an
        // empty success, so first-chat invented a persist. Reject the
        // advertised name. Plural Instructions still persist soul.
        // save_routine still persists Instruction / When.
        // set_routine_enabled still persists Active. Name still
        // persists. Leftover permission_mode now rejects. Schema does
        // not grow an instruction key. Dest title stays Routine.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "instruction": "Summarize overnight",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.instructionHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "instruction": "Summarize overnight",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.instructionHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Instruction reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "Instruction reject must not persist soul")
        XCTAssertEqual(still.routines.count, 0, "Instruction reject must not persist a schedule")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        let fromInstructions = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "instructions": "Own the inbox.",
        ])
        XCTAssertEqual(fromInstructions.soul, "Own the inbox.", "plural Instructions still persist")

        let saved = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "name": "Morning",
            "instruction": "Summarize overnight",
            "when": "Weekdays 9:00",
        ])
        XCTAssertEqual(saved.routines.first?.name, "Morning")
        XCTAssertEqual(saved.routines.first?.prompt, "Summarize overnight")
        XCTAssertEqual(saved.routines.first?.scheduleNote, "Weekdays 9:00")
        let routineID = try XCTUnwrap(saved.routines.first?.id)

        let activated = try service.call(name: BotSelfConfigCatalog.setRoutineEnabled, arguments: [
            "routine_id": routineID,
            "active": true,
        ])
        XCTAssertEqual(activated.routines.first?.enabled, true)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")
        XCTAssertEqual(leftover.soul, "Own the inbox.")
        XCTAssertEqual(leftover.routines.first?.name, "Morning")
        XCTAssertEqual(leftover.routines.first?.enabled, true)

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(renamed.soul, "Own the inbox.")
        XCTAssertEqual(renamed.routines.first?.name, "Morning")
        XCTAssertEqual(renamed.routines.first?.enabled, true)
    }

    func test_setSettingsRejectsAdvertisedWhen_becauseStudioSaysSaveRoutine() throws {
        // WHY: Studio already says When. Compile already labels When.
        // set_settings still accepted when as an empty success, so
        // first-chat invented a persist. Reject the advertised name.
        // save_routine still persists Instruction / When.
        // set_routine_enabled still persists Active. Name still
        // persists. Leftover permission_mode now rejects. Schema does
        // not grow a when key. Dest title stays Routine.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "when": "Weekdays 9:00",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.whenHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "when": "Weekdays 9:00",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.whenHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "When reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "When reject must not persist soul")
        XCTAssertEqual(still.routines.count, 0, "When reject must not persist a schedule")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        let fromInstructions = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "instructions": "Own the inbox.",
        ])
        XCTAssertEqual(fromInstructions.soul, "Own the inbox.", "plural Instructions still persist")

        let saved = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "name": "Morning",
            "instruction": "Summarize overnight",
            "when": "Weekdays 9:00",
        ])
        XCTAssertEqual(saved.routines.first?.name, "Morning")
        XCTAssertEqual(saved.routines.first?.prompt, "Summarize overnight")
        XCTAssertEqual(saved.routines.first?.scheduleNote, "Weekdays 9:00")
        let routineID = try XCTUnwrap(saved.routines.first?.id)

        let activated = try service.call(name: BotSelfConfigCatalog.setRoutineEnabled, arguments: [
            "routine_id": routineID,
            "active": true,
        ])
        XCTAssertEqual(activated.routines.first?.enabled, true)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")
        XCTAssertEqual(leftover.soul, "Own the inbox.")
        XCTAssertEqual(leftover.routines.first?.name, "Morning")
        XCTAssertEqual(leftover.routines.first?.scheduleNote, "Weekdays 9:00")
        XCTAssertEqual(leftover.routines.first?.enabled, true)

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(renamed.soul, "Own the inbox.")
        XCTAssertEqual(renamed.routines.first?.name, "Morning")
        XCTAssertEqual(renamed.routines.first?.scheduleNote, "Weekdays 9:00")
        XCTAssertEqual(renamed.routines.first?.enabled, true)
    }

    func test_setSettingsRejectsAdvertisedActive_becauseStudioSaysSetRoutineEnabled() throws {
        // WHY: Studio already says Active. Compile already labels Active.
        // set_settings still accepted active / enabled / on / off as an
        // empty success, so first-chat invented a persist. Reject the
        // advertised name and leftover aliases. save_routine still
        // persists Instruction / When. set_routine_enabled still
        // persists Active. Name still persists. Leftover
        // permission_mode now rejects. Schema does not grow an
        // active key. Dest title stays Routine.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "active": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.activeHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "enabled": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.activeHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "on": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.activeHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "off": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.activeHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Active reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "Active reject must not persist soul")
        XCTAssertEqual(still.routines.count, 0, "Active reject must not persist a schedule")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        let fromInstructions = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "instructions": "Own the inbox.",
        ])
        XCTAssertEqual(fromInstructions.soul, "Own the inbox.", "plural Instructions still persist")

        let saved = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "name": "Morning",
            "instruction": "Summarize overnight",
            "when": "Weekdays 9:00",
        ])
        XCTAssertEqual(saved.routines.first?.name, "Morning")
        XCTAssertEqual(saved.routines.first?.prompt, "Summarize overnight")
        XCTAssertEqual(saved.routines.first?.scheduleNote, "Weekdays 9:00")
        let routineID = try XCTUnwrap(saved.routines.first?.id)

        let activated = try service.call(name: BotSelfConfigCatalog.setRoutineEnabled, arguments: [
            "routine_id": routineID,
            "active": true,
        ])
        XCTAssertEqual(activated.routines.first?.enabled, true)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")
        XCTAssertEqual(leftover.soul, "Own the inbox.")
        XCTAssertEqual(leftover.routines.first?.name, "Morning")
        XCTAssertEqual(leftover.routines.first?.scheduleNote, "Weekdays 9:00")
        XCTAssertEqual(leftover.routines.first?.enabled, true)

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(renamed.soul, "Own the inbox.")
        XCTAssertEqual(renamed.routines.first?.name, "Morning")
        XCTAssertEqual(renamed.routines.first?.scheduleNote, "Weekdays 9:00")
        XCTAssertEqual(renamed.routines.first?.enabled, true)
    }

    func test_setSettingsRejectsAdvertisedWebsite_becauseStudioSaysBotBrowserOpen() throws {
        // WHY: Studio already says last website. Compile already labels
        // Browser. set_settings still accepted website / url /
        // last_website as an empty success, so first-chat invented a
        // persist. Reject the advertised name and leftover aliases.
        // bot_browser_open still persists Website. Name still persists.
        // Leftover permission_mode now rejects. Schema does not grow
        // a website key. Dest title stays Browser.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "website": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "url": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "last_website": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "website": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Website reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "Website reject must not persist soul")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        let fromInstructions = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "instructions": "Own the inbox.",
        ])
        XCTAssertEqual(fromInstructions.soul, "Own the inbox.", "plural Instructions still persist")

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")
        XCTAssertEqual(leftover.soul, "Own the inbox.")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(renamed.soul, "Own the inbox.")
    }

    func test_setSettingsRejectsAdvertisedBrowser_becauseStudioSaysBotBrowserOpen() throws {
        // WHY: Studio dest title already says Browser. Compile already
        // labels Browser. leftover website / url / last_website already
        // reject. leftover browser still succeeded empty, so first-chat
        // invented a persist from the compile heading. Reject the
        // advertised name with website honesty pointing at
        // bot_browser_open. bot_browser_open still persists Website.
        // leftover website still rejects. Name still persists. Schema
        // does not grow a browser write key. Dest title stays Browser.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["browser"],
            "schema does not grow a browser write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "browser": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Browser": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "website": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Browser reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "Browser reject must not persist soul")
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let fromInstructions = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "instructions": "Own the inbox.",
        ])
        XCTAssertEqual(fromInstructions.soul, "Own the inbox.", "plural Instructions still persist")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.soul, "Own the inbox.")
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID != beforeID, true)
    }

    func test_setSettingsRejectsAdvertisedOpen_becauseStudioSaysBotBrowserOpen() throws {
        // WHY: Admitted tools already say open a website via
        // bot_browser_open. leftover website / last_website / browser
        // already reject. leftover open still succeeded empty, so
        // first-chat invented a persist from the advertised open verb.
        // Reject the advertised name with website honesty pointing at
        // bot_browser_open. leftover website still rejects. leftover
        // browser still rejects. bot_browser_open still persists
        // Website. Name still persists. Schema does not grow an open
        // write key. Dest title stays Browser.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["open"],
            "schema does not grow an open write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "open": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "open website": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "bot_browser_open": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "website": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "browser": "https://example.com",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.websiteHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "open reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "open reject must not persist soul")
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let fromInstructions = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "instructions": "Own the inbox.",
        ])
        XCTAssertEqual(fromInstructions.soul, "Own the inbox.", "plural Instructions still persist")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.soul, "Own the inbox.")
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID != beforeID, true)
    }

    func test_setSettingsRejectsLeftoverPermissionMode_becauseStudioSaysItIsHostAssigned() throws {
        // WHY: Studio already says Approval mode. Compile already labels
        // host-assigned honesty. set_settings still coerced leftover
        // permission_mode to supervised and returned success, so
        // first-chat invented a persist. Reject the leftover key.
        // Name still persists. Leftover desktop_kind now rejects.
        // Snapshot camelCase permissionMode now rejects. Schema does
        // not grow a permission_mode key. Dest title stays Permission.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Permission mode": AgentPermissionMode.autoAcceptEdits.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "permission_mode reject must not persist a name")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktop_kind": BotDesktopKind.dedicatedLocalVM.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertEqual(leftover.name, "Piper")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
    }

    func test_setSettingsRejectsSnapshotPermissionMode_becauseStudioSaysItIsHostAssigned() throws {
        // WHY: Studio already says Approval mode. Compile already labels
        // host-assigned honesty. Leftover permission_mode already
        // rejects. Snapshot still encodes camelCase permissionMode, so
        // first-chat that reused the last get_settings key invented a
        // persist. Reject the snapshot key. Name still persists. Schema
        // does not grow a permissionMode key. Dest title stays
        // Permission.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        let json = try service.encodeSnapshot(try service.snapshot())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertNotNil(object["permissionMode"], "snapshot still encodes leftover camelCase")
        XCTAssertNil(object["permission_mode"], "schema does not grow a permission_mode key")

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permissionMode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "permissionMode": AgentPermissionMode.autoAcceptEdits.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "permissionMode reject must not persist a name")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
    }

    func test_setSettingsRejectsLeftoverDesktopKind_becauseStudioSaysItIsNotASelfConfigWrite() throws {
        // WHY: Studio already says Desktop. Compile already labels
        // isolation honesty. set_settings still coerced leftover
        // desktop_kind to logical and returned success, so first-chat
        // invented a persist. Reject the leftover key. Name still
        // persists. Snapshot camelCase desktopKind now rejects. Schema
        // does not grow a desktop_kind key. Dest title stays Desktop.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktop_kind": BotDesktopKind.dedicatedLocalVM.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Desktop kind": BotDesktopKind.managedRemoteMac.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "desktop_kind": BotDesktopKind.dedicatedLocalVM.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "desktop_kind reject must not persist a name")
        XCTAssertEqual(still.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktopKind": BotDesktopKind.dedicatedLocalVM.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        let leftover = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(leftover.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertEqual(leftover.name, "Piper")
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
    }

    func test_setSettingsRejectsSnapshotDesktopKind_becauseStudioSaysItIsNotASelfConfigWrite() throws {
        // WHY: Studio already says Desktop. Compile already labels
        // isolation honesty. Leftover desktop_kind already rejects.
        // Snapshot still encodes camelCase desktopKind, so first-chat
        // that reused the last get_settings key invented a persist.
        // Reject the snapshot key. Name still persists. Schema does
        // not grow a desktopKind key. Dest title stays Desktop.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        let json = try service.encodeSnapshot(try service.snapshot())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertNotNil(object["desktopKind"], "snapshot still encodes leftover camelCase")
        XCTAssertNil(object["desktop_kind"], "schema does not grow a desktop_kind key")

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktopKind": BotDesktopKind.dedicatedLocalVM.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "desktopKind": BotDesktopKind.managedRemoteMac.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "desktopKind reject must not persist a name")
        XCTAssertEqual(still.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktop_kind": BotDesktopKind.dedicatedLocalVM.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
    }

    func test_setSettingsRejectsAdvertisedLogicalExecutionSpace_becauseStudioSaysItIsNotASelfConfigWrite() throws {
        // WHY: Studio already says Logical execution space. Compile
        // already labels Desktop with that title. leftover desktop /
        // desktop_kind / desktopKind already reject. leftover
        // logical_execution_space still succeeded empty, so first-chat
        // invented a persist from the compile title. Reject the
        // advertised name with desktop honesty. leftover desktop still
        // rejects. Name still persists. Schema does not grow a
        // logical_execution_space write key. Dest title stays Desktop.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["logical_execution_space"],
            "schema does not grow a logical_execution_space write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "logical_execution_space": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Logical execution space": BotDesktopKind.logicalExecutionSpace.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "logical_space": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktop": BotDesktopKind.logicalExecutionSpace.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Logical execution space reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "Logical execution space reject must not persist soul")
        XCTAssertEqual(still.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let fromInstructions = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "instructions": "Own the inbox.",
        ])
        XCTAssertEqual(fromInstructions.soul, "Own the inbox.", "plural Instructions still persist")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.soul, "Own the inbox.")
        XCTAssertEqual(renamed.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID != beforeID, true)
    }

    func test_setSettingsRejectsSnapshotId_becauseStudioSaysIdentityIsHostAssigned() throws {
        // WHY: Studio Identity is host-assigned. Compile already labels
        // handle create-only. Snapshot still encodes leftover id, so
        // first-chat that reused the last get_settings key invented a
        // persist. Reject the snapshot key. bot_id still owns the
        // caller check. Name still persists. leftover permissionMode
        // and desktopKind still reject. Schema does not grow an id
        // write key. Dest title stays Identity.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        let json = try service.encodeSnapshot(try service.snapshot())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["id"] as? String, bot.id.value.uuidString.lowercased())
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["id"],
            "schema does not grow an id write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "id": bot.id.value.uuidString.lowercased(),
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "id": UUID().uuidString.lowercased(),
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "id reject must not persist a name")
        XCTAssertEqual(still.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.id, bot.id.value.uuidString.lowercased())

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permissionMode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktopKind": BotDesktopKind.dedicatedLocalVM.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
    }

    func test_setSettingsRejectsAdvertisedIdentity_becauseStudioSaysItIsHostAssigned() throws {
        // WHY: Studio already dests Identity. Compile dest title is
        // Identity. get_settings already says live identity. leftover
        // snapshot id already rejects. leftover identity still succeeded
        // empty, so first-chat invented a persist from the dest title.
        // Reject the advertised name with host-assigned honesty. leftover
        // id still rejects. bot_id still owns the caller check. Name
        // still persists. Schema does not grow an identity write key.
        // Dest title stays Identity.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["identity"],
            "schema does not grow an identity write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "identity": "Piper Prime",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Identity": "Piper Prime",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "id": bot.id.value.uuidString.lowercased(),
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Identity reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "Identity reject must not persist soul")
        XCTAssertEqual(still.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID != beforeID, true)
    }

    func test_setSettingsRejectsAdvertisedAdmittedTools_becauseStudioSaysTheyAreHostAssigned() throws {
        // WHY: Studio dest title already says Admitted tools. Compile
        // already labels Admitted tools. leftover identity already
        // rejects. leftover admitted_tools still succeeded empty, so
        // first-chat invented a persist from the dest title. Reject
        // the advertised name with host-assigned honesty. leftover
        // identity still rejects. bot_id still owns the caller check.
        // Name still persists. Schema does not grow an admitted_tools
        // write key. Dest title stays Admitted tools.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["admitted_tools"],
            "schema does not grow an admitted_tools write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "admitted_tools": "Invent a new tool.",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Admitted tools": "Invent a new tool.",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "tools": "Invent a new tool.",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "identity": "Piper Prime",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Admitted tools reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "Admitted tools reject must not persist soul")
        XCTAssertEqual(still.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID != beforeID, true)
    }

    func test_setSettingsRejectsAdvertisedUserRequest_becauseStudioSaysItIsThisTurn() throws {
        // WHY: Studio dest title already says User request. Compile
        // already labels User request. leftover admitted_tools already
        // rejects. leftover user_request still succeeded empty, so
        // first-chat invented a persist from the dest title. Reject
        // the advertised name with this-turn honesty. leftover
        // admitted_tools still rejects. bot_id still owns the caller
        // check. Name still persists. Schema does not grow a
        // user_request write key. Dest title stays User request.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["user_request"],
            "schema does not grow a user_request write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "user_request": "Remember this turn as a setting.",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.userRequestHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "User request": "Remember this turn as a setting.",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.userRequestHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "user_text": "Remember this turn as a setting.",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.userRequestHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "admitted_tools": "Invent a new tool.",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "User request reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "User request reject must not persist soul")
        XCTAssertEqual(still.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID != beforeID, true)
    }

    func test_setSettingsRejectsAdvertisedSupervised_becauseStudioSaysItIsHostAssigned() throws {
        // WHY: Studio Desk pill and summary already say Supervised.
        // Compile already labels Approval mode: Supervised. leftover
        // approval_mode / permission_mode already reject. leftover
        // supervised still succeeded empty, so first-chat invented a
        // persist from the advertised pill. Reject the advertised name
        // with host-assigned honesty. leftover permission_mode still
        // rejects. leftover user_request still rejects. bot_id still
        // owns the caller check. Name still persists. Schema does not
        // grow a supervised write key. Dest title stays Permission.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["supervised"],
            "schema does not grow a supervised write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "supervised": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Supervised": AgentPermissionMode.supervised.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "permission_mode": AgentPermissionMode.fullAccess.rawValue,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "user_request": "Remember this turn as a setting.",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.userRequestHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Supervised reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "Supervised reject must not persist soul")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(still.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID != beforeID, true)
    }

    func test_setSettingsRejectsAdvertisedAskBeforeToolActions_becauseStudioSaysAskBefore() throws {
        // WHY: Studio Desk and compile already say Ask before tool
        // actions. leftover supervised / host_brokered_writes already
        // reject. leftover ask_before_tool_actions still succeeded
        // empty, so first-chat invented a persist from the advertised
        // honesty phrase. Reject the advertised name with Permission
        // honesty. leftover supervised still rejects. leftover
        // host_brokered_writes still rejects. bot_id still owns the
        // caller check. Name still persists. Schema does not grow an
        // ask_before_tool_actions write key. Dest title stays Permission.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["ask_before_tool_actions"],
            "schema does not grow an ask_before_tool_actions write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "ask_before_tool_actions": false,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotPermission.honestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Ask before tool actions": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotPermission.honestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "ask_before": false,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotPermission.honestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "tool_actions": "unsupervised",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotPermission.honestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "supervised": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.approvalModeHostAssignedHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "host_brokered_writes": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotPermission.honestyLabel))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Ask before reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "Ask before reject must not persist soul")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(still.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID != beforeID, true)
    }

    func test_setSettingsRejectsAdvertisedSameMacOSAccount_becauseStudioSaysSameAccount() throws {
        // WHY: Studio Desk and compile already say Same macOS account.
        // leftover desktop / logical_execution_space already reject.
        // leftover same_macos_account still succeeded empty, so
        // first-chat invented a persist from the advertised honesty
        // phrase. Reject the advertised name with Desktop isolation
        // honesty. leftover desktop still rejects. leftover
        // logical_execution_space still rejects. bot_id still owns the
        // caller check. Name still persists. Schema does not grow a
        // same_macos_account write key. Dest title stays Desktop.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["same_macos_account"],
            "schema does not grow a same_macos_account write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "same_macos_account": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "Same macOS account": false,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "macos_account": "isolated",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "same_account": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktop": "logical",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "logical_execution_space": "isolated",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "Same macOS account reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "Same macOS account reject must not persist soul")
        XCTAssertEqual(still.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertEqual(still.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID != beforeID, true)
    }

    func test_setSettingsRejectsAdvertisedIsolated_becauseStudioSaysNotIsolated() throws {
        // WHY: Studio Desk and compile already say not isolated.
        // leftover desktop / same_macos_account already reject.
        // leftover isolated still succeeded empty, so first-chat
        // invented a persist from the advertised honesty phrase.
        // Reject the advertised name with Desktop isolation honesty.
        // leftover desktop still rejects. leftover same_macos_account
        // still rejects. bot_id still owns the caller check. Name
        // still persists. Schema does not grow an isolated write key.
        // Dest title stays Desktop.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["isolated"],
            "schema does not grow an isolated write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "isolated": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "not isolated": false,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "isolated_desktop": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktop": "logical",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "same_macos_account": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "isolated reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "isolated reject must not persist soul")
        XCTAssertEqual(still.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertEqual(still.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID != beforeID, true)
    }

    func test_setSettingsRejectsAdvertisedDedicated_becauseStudioSaysNotDedicated() throws {
        // WHY: Studio Desk and compile already say Not a dedicated Desktop.
        // leftover desktop / isolated already reject.
        // leftover dedicated still succeeded empty, so first-chat
        // invented a persist from the advertised honesty phrase.
        // Reject the advertised name with Desktop isolation honesty.
        // leftover desktop still rejects. leftover isolated still
        // rejects. bot_id still owns the caller check. Name still
        // persists. Schema does not grow a dedicated write key.
        // Dest title stays Desktop.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["dedicated"],
            "schema does not grow a dedicated write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "dedicated": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "not dedicated": false,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "dedicated_desktop": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "desktop": "logical",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "isolated": true,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "dedicated reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "dedicated reject must not persist soul")
        XCTAssertEqual(still.desktopKind, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertEqual(still.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.id, bot.id.value.uuidString.lowercased())
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID != beforeID, true)
    }

    func test_setSettingsRejectsSnapshotMemoryId_becauseStudioSaysRememberAFact() throws {
        // WHY: Studio already says Memory. Compile already labels Fact.
        // Snapshot still encodes leftover memory_id, so first-chat that
        // reused the last get_settings key invented a persist. Reject
        // the snapshot key. forget/correct still own memory_id.
        // put_memory still persists Fact. leftover Memory / fact still
        // reject. leftover snapshot id still rejects. Name still
        // persists. Schema does not grow a memory_id write key. Dest
        // title stays Memory.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let remembered = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers dark mode\n",
        ])
        let memoryID = try XCTUnwrap(remembered.memory.first?.id)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        let json = try service.encodeSnapshot(try service.snapshot())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let memory = try XCTUnwrap(object["memory"] as? [[String: Any]])
        XCTAssertEqual(memory.first?["path"] as? String, memoryID)
        XCTAssertNil(memory.first?["id"], "nested id omitted")
        XCTAssertNil(memory.first?["memory_id"], "store leftover memory_id omitted")
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["memory_id"],
            "schema does not grow a memory_id write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "memory_id": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "memory_id": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "fact": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "id": bot.id.value.uuidString.lowercased(),
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "memory_id reject must not persist a name")
        XCTAssertEqual(still.memory.first?.id, memoryID)
        XCTAssertTrue(still.memory.contains(where: { $0.content.contains("Prefers dark mode") }))
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertTrue(owned.memory.contains(where: { $0.content.contains("Prefers dark mode") }))

        let corrected = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers light mode\n",
        ])
        XCTAssertTrue(corrected.memory.contains(where: { $0.content.contains("Prefers light mode") }))

        let forgotten = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "# Memory\n\n",
        ])
        XCTAssertFalse(forgotten.memory.contains(where: { $0.content.contains("Prefers light mode") }))
    }

    func test_setSettingsRejectsSnapshotContent_becauseStudioSaysRememberAFact() throws {
        // WHY: Studio already says Memory. Compile already labels Fact.
        // Snapshot still encodes leftover content, so first-chat that
        // reused the last get_settings key invented a persist. Reject
        // the snapshot key. put_memory still persists Fact.
        // leftover Memory / fact / memory_id still reject. leftover
        // snapshot id still rejects. Name still persists. Schema does
        // not grow a content write key. Dest title stays Memory.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let remembered = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers dark mode\n",
        ])
        let memoryID = try XCTUnwrap(remembered.memory.first?.id)
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        let json = try service.encodeSnapshot(try service.snapshot())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let memory = try XCTUnwrap(object["memory"] as? [[String: Any]])
        XCTAssertTrue((memory.first?["content"] as? String)?.contains("Prefers dark mode") == true)
        XCTAssertEqual(memory.first?["path"] as? String, memoryID)
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["content"],
            "schema does not grow a content write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "content": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "content": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "fact": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "memory_id": memoryID,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "id": bot.id.value.uuidString.lowercased(),
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.workspaceHostAssignedHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "content reject must not persist a name")
        XCTAssertEqual(still.memory.first?.id, memoryID)
        XCTAssertTrue(still.memory.contains(where: { $0.content.contains("Prefers dark mode") }))
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertTrue(owned.memory.contains(where: { $0.content.contains("Prefers dark mode") }))

        let viaContent = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers light mode\n",
        ])
        XCTAssertTrue(viaContent.memory.contains(where: { $0.content.contains("Prefers light mode") }))
    }

    func test_setSettingsRejectsSnapshotPrompt_becauseStudioSaysSaveRoutine() throws {
        // WHY: Studio already says Instruction. Compile already labels
        // Instruction. leftover instruction already rejects. Snapshot
        // still encodes leftover prompt, so first-chat that reused the
        // last get_settings key invented a persist. Reject the snapshot
        // key. save_routine still persists Instruction. leftover
        // instruction still rejects. leftover Memory / content still
        // reject. Name still persists. Schema does not grow a prompt
        // write key. Dest title stays Routine.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let saved = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "name": "Morning",
            "instruction": "Summarize overnight",
            "when": "Weekdays 9:00",
        ])
        XCTAssertEqual(saved.routines.first?.prompt, "Summarize overnight")
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        let json = try service.encodeSnapshot(try service.snapshot())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let routines = try XCTUnwrap(object["routines"] as? [[String: Any]])
        XCTAssertEqual(routines.first?["prompt"] as? String, "Summarize overnight")
        XCTAssertEqual(routines.first?["schedule_note"] as? String, "Weekdays 9:00")
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["prompt"],
            "schema does not grow a prompt write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "prompt": "Summarize overnight",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.instructionHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "prompt": "Summarize overnight",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.instructionHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "instruction": "Summarize overnight",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.instructionHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "content": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "prompt reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "prompt reject must not persist soul")
        XCTAssertEqual(still.routines.first?.prompt, "Summarize overnight")
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.routines.first?.prompt, "Summarize overnight")

        let viaPrompt = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "routine_id": try XCTUnwrap(saved.routines.first?.id),
            "name": "Morning",
            "prompt": "Triage the inbox",
            "when": "Weekdays 9:00",
        ])
        XCTAssertEqual(viaPrompt.routines.first?.prompt, "Triage the inbox", "save_routine still owns prompt")
    }

    func test_setSettingsRejectsSnapshotScheduleNote_becauseStudioSaysSaveRoutine() throws {
        // WHY: Studio already says When. Compile already labels When.
        // leftover when already rejects. Snapshot still encodes leftover
        // schedule_note, so first-chat that reused the last get_settings
        // key invented a persist. Reject the snapshot key. save_routine
        // still persists When. leftover when still rejects. leftover
        // Instruction / prompt still reject. Name still persists.
        // Schema does not grow a schedule_note write key. Dest title
        // stays Routine.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let saved = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "name": "Morning",
            "instruction": "Summarize overnight",
            "when": "Weekdays 9:00",
        ])
        XCTAssertEqual(saved.routines.first?.scheduleNote, "Weekdays 9:00")
        let beforeID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        let json = try service.encodeSnapshot(try service.snapshot())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let routines = try XCTUnwrap(object["routines"] as? [[String: Any]])
        XCTAssertEqual(routines.first?["prompt"] as? String, "Summarize overnight")
        XCTAssertEqual(routines.first?["schedule_note"] as? String, "Weekdays 9:00")
        XCTAssertNil(
            BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)["properties"]
                .flatMap { $0 as? [String: Any] }?["schedule_note"],
            "schema does not grow a schedule_note write key"
        )

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "schedule_note": "Weekdays 9:00",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.whenHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "name": "Piper Prime",
                "schedule_note": "Weekdays 9:00",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.whenHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "when": "Weekdays 9:00",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.whenHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "prompt": "Summarize overnight",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.instructionHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.name, "Piper", "schedule_note reject must not persist a name")
        XCTAssertEqual(still.soul, "Be brief.", "schedule_note reject must not persist soul")
        XCTAssertEqual(still.routines.first?.scheduleNote, "Weekdays 9:00")
        XCTAssertEqual(try store.get(id: bot.id)?.currentRevisionID, beforeID)

        let owned = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "bot_id": bot.id.value.uuidString,
            "name": "Piper Prime",
        ])
        XCTAssertEqual(owned.name, "Piper Prime", "bot_id still owns the caller check")
        XCTAssertEqual(owned.routines.first?.scheduleNote, "Weekdays 9:00")

        let viaNote = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "routine_id": try XCTUnwrap(saved.routines.first?.id),
            "name": "Morning",
            "prompt": "Summarize overnight",
            "schedule_note": "Daily 8:00",
        ])
        XCTAssertEqual(viaNote.routines.first?.scheduleNote, "Daily 8:00", "save_routine still owns schedule_note")
    }

    func test_setSettingsAdvertisedAvatarPersists_becauseStudioSaysStarNotSFSymbol() throws {
        // WHY: Studio already picks Avatar and publish already writes
        // avatar_symbol. Tools never named that path, so first-chat
        // "change my avatar" invented a hop. Canonical avatar_symbol
        // still wins. Schema does not grow an avatar key.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude
        )
        XCTAssertEqual(bot.avatarSymbol, "person.crop.circle")
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        let fromName = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "avatar": "Star",
        ])
        XCTAssertEqual(fromName.avatarSymbol, "star.fill", "Star persists")
        XCTAssertEqual(try store.get(id: bot.id)?.avatarSymbol, "star.fill")

        let fromSymbol = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "avatar": "leaf.fill",
        ])
        XCTAssertEqual(fromSymbol.avatarSymbol, "leaf.fill")

        let symbolWins = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "avatar_symbol": "hammer.fill",
            "avatar": "Star",
        ])
        XCTAssertEqual(symbolWins.avatarSymbol, "hammer.fill", "avatar_symbol wins")
        XCTAssertEqual(try store.get(id: bot.id)?.avatarSymbol, "hammer.fill")

        let json = try service.encodeSnapshot(symbolWins)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["avatar_symbol"] as? String, "hammer.fill", "avatar_symbol persists")
        XCTAssertNil(object["avatar"], "avatar is an advertised alias, not a second schema key")
        XCTAssertNil(object["avatarSymbol"], "Swift avatarSymbol omitted")

        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "avatar": "Robot",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid("Unknown avatar: Robot"))
        }
        XCTAssertEqual(try store.get(id: bot.id)?.avatarSymbol, "hammer.fill")
    }

    func test_setSettingsAdvertisedNamesPersist_becauseToolsSayJobNotTitle() throws {
        // WHY: Tools invite Role / Instructions / notifications.
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

    func test_setSettingsAdvertisedInstructionsPersist_becauseStudioSaysInstructionsNotSoul() throws {
        // WHY: Studio already says Instructions. Parse only read soul /
        // standing_instructions, so first-chat "change your instructions"
        // invented a hop or left the leftover soul. Canonical soul still
        // wins. Schema does not grow an instructions key.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        let fromInstructions = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "instructions": "Own the inbox.",
        ])
        XCTAssertEqual(fromInstructions.soul, "Own the inbox.", "Instructions persist")
        XCTAssertEqual(try store.getRevision(id: try XCTUnwrap(store.get(id: bot.id)?.currentRevisionID))?.soul, "Own the inbox.")

        let standingWins = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "standing_instructions": "Ask when blocked.",
            "instructions": "Ignored instructions",
        ])
        XCTAssertEqual(standingWins.soul, "Ask when blocked.", "standing_instructions wins")

        let soulWins = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "soul": "Speak plainly.",
            "standing_instructions": "Ignored standing",
            "instructions": "Ignored instructions",
        ])
        XCTAssertEqual(soulWins.soul, "Speak plainly.", "soul wins")
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

    func test_setSettingsRejectsProviderKeys_becauseCallerThreadOwnsTheRoute() throws {
        // WHY: allowing a Bot to persist any route key can silently switch a
        // later Grok/Codex/Claude caller to the Bot's stale provider.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let revisionID = try XCTUnwrap(try store.get(id: bot.id)?.currentRevisionID)
        let cases: [[String: Any]] = [
            ["provider": "Grok"],
            ["provider_instance_id": "grok-work"],
            ["model": "grok-4.6"],
            ["route": "Claude"],
            ["default_route": "Codex"],
        ]

        for arguments in cases {
            XCTAssertThrowsError(
                try service.call(name: BotSelfConfigCatalog.setSettings, arguments: arguments)
            ) { error in
                XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotSelfConfigCatalog.providerRoutingHonesty))
            }
        }
        XCTAssertEqual(
            try store.get(id: bot.id)?.currentRevisionID,
            revisionID,
            "rejected route keys must publish nothing"
        )
    }

    func test_saveRoutinePersistsSpecFromWhenNote_becauseFleetEditMustNotDefaultDaily() throws {
        // WHY: bot_save_routine wrote schedule_note only. Fleet Edit then
        // hydrated BotScheduleSpec() (Daily / now) and Save wiped Weekdays 9:00.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let saved = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "name": "QA morning scan",
            "instruction": "Check overnight failures and reply with one short status.",
            "when": "Weekdays 9:00",
        ])
        XCTAssertEqual(saved.routines.first?.scheduleNote, "Weekdays 9:00")
        let created = try XCTUnwrap(try store.listRoutines(botID: bot.id).first)
        let spec = try XCTUnwrap(created.definition.scheduleSpec)
        XCTAssertFalse(created.definition.scheduleSpecJSON.isEmpty)
        XCTAssertEqual(spec.frequency, .weekdays)
        XCTAssertEqual(spec.localTimeHour, 9)
        XCTAssertEqual(spec.localTimeMinute, 0)

        _ = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "routine_id": saved.routines[0].id,
            "name": "QA morning scan",
            "prompt": "Check overnight failures and reply with one short status.",
            "schedule_note": "Daily",
        ])
        let updated = try XCTUnwrap(try store.listRoutines(botID: bot.id).first)
        let kept = try XCTUnwrap(updated.definition.scheduleSpec)
        XCTAssertEqual(updated.definition.scheduleNote, "Daily")
        XCTAssertEqual(kept.frequency, .weekdays)
        XCTAssertEqual(kept.localTimeHour, 9)
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

    func test_setRoutineEnabledAdvertisedActivePersists_becauseStudioSaysActiveNotEnabled() throws {
        // WHY: Studio already says Active. Parse only read enabled / on,
        // so first-chat "set this Active" invented a hop or left the leftover
        // switch. Advertised Active token persists. Canonical enabled still
        // wins. Schema does not grow a second key.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let created = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "name": "Morning",
            "prompt": "Summarize overnight",
        ])
        let routineID = try XCTUnwrap(created.routines.first?.id)
        XCTAssertEqual(created.routines.first?.enabled, false)

        let fromActive = try service.call(name: BotSelfConfigCatalog.setRoutineEnabled, arguments: [
            "routine_id": routineID,
            "active": true,
        ])
        XCTAssertEqual(fromActive.routines.first?.enabled, true, "Active persists")
        XCTAssertEqual(try store.listRoutines(botID: bot.id).first?.activation.isEnabled, true)

        let fromActiveToken = try service.call(name: BotSelfConfigCatalog.setRoutineEnabled, arguments: [
            "routine_id": routineID,
            "active": "Active",
        ])
        XCTAssertEqual(fromActiveToken.routines.first?.enabled, true, "advertised Active token persists")
        XCTAssertEqual(try store.listRoutines(botID: bot.id).first?.activation.isEnabled, true)

        let fromOff = try service.call(name: BotSelfConfigCatalog.setRoutineEnabled, arguments: [
            "routine_id": routineID,
            "active": "Off",
        ])
        XCTAssertEqual(fromOff.routines.first?.enabled, false, "Active Off persists")

        let enabledWins = try service.call(name: BotSelfConfigCatalog.setRoutineEnabled, arguments: [
            "routine_id": routineID,
            "enabled": true,
            "active": false,
        ])
        XCTAssertEqual(enabledWins.routines.first?.enabled, true, "enabled wins")
        XCTAssertEqual(try store.listRoutines(botID: bot.id).first?.activation.isEnabled, true)
    }

    func test_setRoutineEnabledCatalogDescribesActive_becauseThatIsTheStudioField() {
        // WHY: Schema key stays enabled. Description must name Active so
        // first-chat does not invent a hop.
        let description = BotSelfConfigCatalog.description(for: BotSelfConfigCatalog.setRoutineEnabled)
        XCTAssertEqual(description, "Set a routine Active or Off. Same path as Studio Active.")
        let schema = BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setRoutineEnabled)
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["enabled"])
        XCTAssertNil(properties?["active"], "active is an advertised alias, not a second schema key")
        let enabled = properties?["enabled"] as? [String: Any]
        XCTAssertEqual(enabled?["description"] as? String, "Active. Same field as Studio Active.")
    }

    func test_setSkillAdvertisedAddPersists_becauseStudioAddOnlySendsTheCatalogId() throws {
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let fromAdd = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "skills/weekly-account-health/SKILL.md",
            "contents": "Do the weekly health scan.\n",
        ])
        XCTAssertEqual(fromAdd.skills.map(\.skillID), ["weekly-account-health"], "Add persists")
        XCTAssertEqual(fromAdd.skills.first?.enabled, true, "Add persists")
    }

    func test_setSkillCatalogDescribesAdd_becauseThatIsTheStudioPath() {
        let description = BotSelfConfigCatalog.description(for: BotSelfConfigCatalog.skillView)
        XCTAssertTrue(description.contains("SKILL.md"))
        let schema = BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.skillView)
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["skill_id"])
        XCTAssertEqual(schema["required"] as? [String], ["skill_id"])
    }

    func test_writeHomeFilePersistsOwnedSkillMarkdown() throws {
        // WHY: Skills are the files. Catalog Add hid that path behind
        // store bindings. write_home_file must persist SKILL.md and
        // leftover set_skill must fail loud.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let written = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "skills/weekly-invoice/SKILL.md",
            "contents": "Invoice the week.\n",
        ])
        XCTAssertEqual(written.skills.map(\.skillID), ["weekly-invoice"])
        let home = BotHome(appSupportDirectory: service.appSupportDirectory, bot: bot)
        XCTAssertTrue(try home.listOwnedSkills().contains(where: { $0.slug == "weekly-invoice" }))
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSkill, arguments: [
                "skill_id": "weekly-account-health",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.skillsHonesty))
        }
        let removed = try service.call(name: BotSelfConfigCatalog.removeSkill, arguments: [
            "skill_id": "weekly-invoice",
        ])
        XCTAssertTrue(removed.skills.isEmpty)
        XCTAssertTrue(try home.listOwnedSkills().isEmpty)
    }

    func test_writeHomeFilePersistsMemoryMarkdown() throws {
        // WHY: Memory is the files. put/forget/correct hid that path
        // behind store IDs. write_home_file must persist MEMORY.md and
        // today's daily note, and leftover CRUD names must fail loud.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let durable = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers dark mode\n",
        ])
        XCTAssertTrue(durable.memory.contains(where: { $0.id == "MEMORY.md" && $0.content.contains("Prefers dark mode") }))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dailyPath = "memory/\(formatter.string(from: Date())).md"
        let daily = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": dailyPath,
            "contents": "Shipped the overnight brief.\n",
        ])
        XCTAssertTrue(daily.memory.contains(where: { $0.id == dailyPath }))
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
                "path": "IDENTITY.md",
                "contents": "stolen",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.putMemory, arguments: [
                "content": "Prefers dark mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.forgetMemory, arguments: [
                "memory_id": UUID().uuidString,
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.correctMemory, arguments: [
                "memory_id": UUID().uuidString,
                "content": "Prefers light mode",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotBrainCompiler.memoryHonesty))
        }
        XCTAssertFalse(BotSelfConfigCatalog.toolNames.contains(BotSelfConfigCatalog.putMemory))
        XCTAssertTrue(BotSelfConfigCatalog.toolNames.contains(BotSelfConfigCatalog.writeHomeFile))
        let description = BotSelfConfigCatalog.description(for: BotSelfConfigCatalog.writeHomeFile)
        XCTAssertTrue(description.contains("MEMORY.md"))
        XCTAssertTrue(description.contains("memory/YYYY-MM-DD.md"))
    }

    func test_removeSkillDropsBinding_becauseDisableIsNotUnbind() throws {
        // WHY: Studio Remove deletes the catalog row. Tools only named
        // enable/disable, so first-chat "remove this skill" invented
        // disable and left the id bound. Disable is not unbind.
        // Hermes agents unbind in place.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        _ = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "skills/keep-me/SKILL.md",
            "contents": "Keep.\n",
        ])
        _ = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "skills/drop-me/SKILL.md",
            "contents": "Drop.\n",
        ])
        let removed = try service.call(name: BotSelfConfigCatalog.removeSkill, arguments: [
            "skill_id": "drop-me",
        ])
        XCTAssertEqual(removed.skills.map(\.skillID), ["keep-me"])
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

    func test_encodeSnapshotUsesCatalogMutateKeys_becauseNestedIdCollidedWithTheBot() throws {
        // WHY: Forget/remove/toggle require memory_id / skill_id / routine_id.
        // Snapshot used Swift id / skillID / scheduleNote, so same-turn
        // "forget that" invented a hop or sent the bot id. Hermes agents
        // reuse the key the last write returned. Canonical Swift fields stay.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let remembered = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "MEMORY.md",
            "contents": "- Prefers dark mode\n",
        ])
        _ = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "skills/weekly-account-health/SKILL.md",
            "contents": "Do the weekly health scan.\n",
        ])
        _ = try service.call(name: BotSelfConfigCatalog.saveRoutine, arguments: [
            "name": "Morning",
            "prompt": "Summarize overnight",
            "schedule_note": "Weekdays 9:00",
        ])
        let json = try service.encodeSnapshot(try service.snapshot())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["id"] as? String, bot.id.value.uuidString.lowercased())
        let memory = try XCTUnwrap(object["memory"] as? [[String: Any]])
        XCTAssertEqual(memory.first?["path"] as? String, remembered.memory.first?.id, "path persists")
        XCTAssertNil(memory.first?["id"], "nested id omitted")
        XCTAssertTrue((memory.first?["content"] as? String)?.contains("Prefers dark mode") == true)
        let skills = try XCTUnwrap(object["skills"] as? [[String: Any]])
        XCTAssertEqual(skills.first?["skill_id"] as? String, "weekly-account-health", "skill_id persists")
        XCTAssertNil(skills.first?["skillID"])
        let routines = try XCTUnwrap(object["routines"] as? [[String: Any]])
        XCTAssertEqual(routines.first?["routine_id"] as? String, try service.snapshot().routines.first?.id, "routine_id persists")
        XCTAssertNil(routines.first?["id"], "nested id omitted")
        XCTAssertEqual(routines.first?["schedule_note"] as? String, "Weekdays 9:00")
        XCTAssertNil(routines.first?["scheduleNote"])
        XCTAssertEqual(remembered.memory.first?.id.isEmpty, false)
        XCTAssertEqual(try service.snapshot().skills.first?.skillID, "weekly-account-health")
        XCTAssertEqual(try service.snapshot().routines.first?.scheduleNote, "Weekdays 9:00")
    }

    func test_encodeSnapshotUsesCatalogSettingsKeysAndOmitsRoute_becauseRouteBelongsToThread() throws {
        // WHY: a self-config snapshot must not teach a Bot that provider/model
        // are durable Bot settings; notifications remains a real Bot setting.
        // Leftover permission/desktop stay camelCase — catalog omits those writes.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let after = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "notifications_enabled": false,
        ])
        XCTAssertFalse(after.notificationsEnabled)
        let json = try service.encodeSnapshot(try service.snapshot())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["notifications_enabled"] as? Bool, false, "notifications_enabled persists")
        XCTAssertNil(object["notificationsEnabled"], "Swift notificationsEnabled omitted")
        XCTAssertNil(object["provider"], "provider belongs to the calling thread")
        XCTAssertNil(object["provider_instance_id"], "provider account belongs to the calling thread")
        XCTAssertNil(object["providerInstanceID"])
        XCTAssertNil(object["model"], "model belongs to the calling thread")
        XCTAssertEqual(object["permissionMode"] as? String, AgentPermissionMode.supervised.rawValue)
        XCTAssertNil(object["permission_mode"], "leftover permission stays unnamed")
        XCTAssertEqual(object["desktopKind"] as? String, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertNil(object["desktop_kind"], "leftover desktop stays unnamed")
        XCTAssertEqual(try store.get(id: bot.id)?.notificationsEnabled, false)
        let revision = try XCTUnwrap(
            try store.getRevision(id: try XCTUnwrap(store.get(id: bot.id)?.currentRevisionID))
        )
        let revisionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(revision)) as? [String: Any]
        )
        XCTAssertNil(revisionObject["provider"])
        XCTAssertNil(revisionObject["providerInstanceID"])
        XCTAssertNil(revisionObject["model"])
    }

    func test_writeSoulFilePublishesRevision() throws {
        let bot = try store.create(name: "Piper", title: "Scout", description: "", soul: "Old soul.", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let after = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "SOUL.md",
            "contents": "Do the job better.\n",
        ])
        XCTAssertEqual(after.soul, "Do the job better.\n")
        XCTAssertEqual(
            try store.getRevision(id: try XCTUnwrap(store.get(id: bot.id)?.currentRevisionID))?.soul,
            "Do the job better.\n"
        )
    }

    func test_recallReturnsOnlyCallerHomeAndLinkedThread() throws {
        let piper = try store.create(name: "Piper", title: "Scout", description: "", soul: "Be brief.", provider: .claude)
        let quinn = try store.create(name: "Quinn", title: "Editor", description: "", soul: "Edit.", provider: .claude)
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-recall-\(UUID().uuidString)", isDirectory: true)
        let piperHome = BotHome(appSupportDirectory: appSupport, bot: piper)
        try piperHome.ensure(
            name: piper.name,
            handle: piper.handle,
            title: piper.title,
            description: "",
            soul: ""
        )
        try piperHome.writeFile(relativePath: "MEMORY.md", contents: "Piper remembers the indigo vault.\n")
        let quinnHome = BotHome(appSupportDirectory: appSupport, bot: quinn)
        try quinnHome.ensure(name: quinn.name, handle: quinn.handle, title: quinn.title, description: "", soul: "")
        try quinnHome.writeFile(relativePath: "MEMORY.md", contents: "Quinn remembers the indigo vault.\n")

        let piperThread = UUID()
        let quinnThread = UUID()
        try insertThread(id: piperThread, title: "Piper chat")
        try insertThread(id: quinnThread, title: "Quinn chat")
        try insertMessage(thread: piperThread, role: "user", content: "indigo vault from piper thread")
        try insertMessage(thread: quinnThread, role: "user", content: "indigo vault from quinn thread")
        try store.upsertConversation(
            BotConversation(
                botID: piper.id,
                title: "Desk",
                linkedAgentThreadID: AgentThreadID(piperThread)
            )
        )
        try store.upsertConversation(
            BotConversation(
                botID: quinn.id,
                title: "Desk",
                linkedAgentThreadID: AgentThreadID(quinnThread)
            )
        )

        let piperService = BotSelfConfigService(
            callerBotID: piper.id,
            store: store,
            appSupportDirectory: appSupport
        )
        let hits = try piperService.invoke(
            name: BotSelfConfigCatalog.recall,
            arguments: ["query": "indigo vault"]
        )
        let rows = try XCTUnwrap(hits["hits"] as? [[String: String]])
        XCTAssertTrue(rows.contains { $0["source"] == "MEMORY.md" })
        XCTAssertTrue(rows.contains { ($0["snippet"] ?? "").contains("piper thread") })
        XCTAssertFalse(rows.contains { ($0["snippet"] ?? "").contains("quinn thread") })
    }

    func test_askUserWritesQuestionAndReturns() throws {
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        try store.upsertConversation(BotConversation(botID: bot.id, title: "Desk"))
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let result = try service.invoke(
            name: BotSelfConfigCatalog.askUser,
            arguments: ["question": "Which repo?"]
        )
        XCTAssertEqual(result["asked"] as? Bool, true)
        XCTAssertEqual(result["question"] as? String, "Which repo?")
        XCTAssertNotNil(result["next"] as? String)
        let items = try store.listAttention()
        XCTAssertTrue(items.contains { $0.botID == bot.id && $0.detail == "Which repo?" && $0.kind == .question })
    }

    func test_skillViewReturnsCallerBodyOnly() throws {
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        _ = try service.call(name: BotSelfConfigCatalog.writeHomeFile, arguments: [
            "path": "skills/weekly-invoice/SKILL.md",
            "contents": "Invoice the week.\n",
        ])
        let viewed = try service.invoke(
            name: BotSelfConfigCatalog.skillView,
            arguments: ["skill_id": "weekly-invoice"]
        )
        XCTAssertEqual(viewed["body"] as? String, "Invoice the week.\n")
        XCTAssertThrowsError(
            try service.invoke(
                name: BotSelfConfigCatalog.skillView,
                arguments: ["bot_id": BotID().value.uuidString, "skill_id": "weekly-invoice"]
            )
        )
    }

    private func insertThread(id: UUID, title: String) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO agent_threads(
                    id, title, provider, model, status, created_at, updated_at
                ) VALUES(?, ?, 'claude', 'opus', 'idle', ?, ?);
                """)
            defer { statement.reset() }
            let now = ISO8601DateFormatter().string(from: Date())
            try statement.bind(1, id.uuidString.lowercased())
            try statement.bind(2, title)
            try statement.bind(3, now)
            try statement.bind(4, now)
            _ = try statement.step()
        }
    }

    private func insertMessage(thread: UUID, role: String, content: String) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO agent_messages(id, thread_id, role, content, created_at)
                VALUES(?, ?, ?, ?, ?);
                """)
            defer { statement.reset() }
            try statement.bind(1, UUID().uuidString.lowercased())
            try statement.bind(2, thread.uuidString.lowercased())
            try statement.bind(3, role)
            try statement.bind(4, content)
            try statement.bind(5, ISO8601DateFormatter().string(from: Date()))
            _ = try statement.step()
        }
    }
}
