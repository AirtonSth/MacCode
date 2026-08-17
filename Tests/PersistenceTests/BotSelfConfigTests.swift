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
        XCTAssertTrue(description.contains("name, Role, Instructions, description, Default route, Model, notifications, or avatar"))
        XCTAssertFalse(description.contains("job, standing instructions"), "leftover job is not advertised")
        XCTAssertFalse(description.contains("permission"))
        XCTAssertFalse(description.contains("desktop"))
        let schema = BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSettings)
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["provider"])
        XCTAssertNotNil(properties?["model"])
        XCTAssertNotNil(properties?["avatar_symbol"])
        XCTAssertNil(properties?["route"], "route is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["default_route"], "default_route is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["avatar"], "avatar is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["permission_mode"])
        XCTAssertNil(properties?["desktop_kind"])
        let provider = properties?["provider"] as? [String: Any]
        XCTAssertEqual(provider?["description"] as? String, "Default route. Claude, Codex, or Grok. Same field as Studio Default route.")
        let title = properties?["title"] as? [String: Any]
        let soul = properties?["soul"] as? [String: Any]
        let model = properties?["model"] as? [String: Any]
        let notify = properties?["notifications_enabled"] as? [String: Any]
        let avatar = properties?["avatar_symbol"] as? [String: Any]
        XCTAssertEqual(title?["description"] as? String, "Role / job. Same field as Studio Role.")
        XCTAssertEqual(soul?["description"] as? String, "Instructions. Same field as Studio Instructions.")
        XCTAssertEqual(model?["description"] as? String, "Model. Same field as Studio Model.")
        XCTAssertEqual(notify?["description"] as? String, "Notifications On/Off.")
        XCTAssertEqual(avatar?["description"] as? String, "Avatar. Same field as Studio Avatar.")
        XCTAssertNil(properties?["notifications"], "notifications is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["instructions"], "instructions is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["standing_instructions"], "standing_instructions is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["fallback"], "fallback is not a schema key")
        XCTAssertNil(properties?["fallback_order"], "fallback_order is not a schema key")
        XCTAssertNil(properties?["handle"], "handle is create-only, not a schema key")
        XCTAssertNil(properties?["workspace"], "workspace is host-assigned, not a schema key")
        XCTAssertNil(properties?["working_space"], "working_space is not a schema key")
        XCTAssertNil(properties?["cwd"], "cwd is not a schema key")
        XCTAssertNil(properties?["approval"], "approval is not a schema key")
        XCTAssertNil(properties?["approval_mode"], "approval_mode is host-assigned, not a schema key")
        XCTAssertNil(properties?["permission"], "permission is dest title, not a schema key")
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
        XCTAssertTrue(description.contains(BotRoute.fallbackOrderHonesty), "catalog names Fallback order honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.handleCreateOnlyHonesty), "catalog names Handle create-only honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.workspaceHostAssignedHonesty), "catalog names Workspace host-assigned honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.approvalModeHostAssignedHonesty), "catalog names Approval mode host-assigned honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.approvalsHonesty), "catalog names Approvals honesty")
        XCTAssertTrue(description.contains(BotPermission.honestyLabel), "catalog names Host-brokered writes honesty")
        XCTAssertTrue(description.contains(BotDesktopKind.logicalExecutionSpaceHonestyLabel), "catalog names Desktop isolation honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.testRunHonesty), "catalog names Test run honesty")
        XCTAssertTrue(description.contains(BotBrainCompiler.memoryHonesty), "catalog names Memory honesty")
    }

    func test_setSettingsRejectsAdvertisedFallbackOrder_becauseStudioSaysItIsNotShipped() throws {
        // WHY: Studio already says Fallback order is not shipped. Compile
        // already labels that honesty. set_settings still accepted
        // fallback_order as an empty success, so first-chat "if Claude is
        // down use Grok" invented a persist. Reject the advertised name.
        // Default route still persists. Schema does not grow a fallback key.
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
                "fallback_order": "Grok, Claude",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotRoute.fallbackOrderHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "Fallback order": "Grok then Claude",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotRoute.fallbackOrderHonesty))
        }
        XCTAssertThrowsError(
            try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
                "provider": "Grok",
                "fallback": "Claude",
            ])
        ) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .invalid(BotRoute.fallbackOrderHonesty))
        }
        let still = try service.call(name: BotSelfConfigCatalog.getSettings)
        XCTAssertEqual(still.provider, AgentProvider.claude.rawValue, "Fallback reject must not persist a route")
        XCTAssertEqual(still.model, "opus", "Fallback reject must not persist a model")

        let route = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "default_route": "Grok",
        ])
        XCTAssertEqual(route.provider, AgentProvider.grok.rawValue)
        XCTAssertEqual(route.model, BotRoute.defaultModel(for: .grok))
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
        XCTAssertEqual(still.provider, AgentProvider.claude.rawValue)

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
        // Name still persists. Leftover permission_mode still coerces.
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

        let leftover = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "permission_mode": AgentPermissionMode.fullAccess.rawValue,
        ])
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
        // name. Name still persists. Leftover desktop_kind still coerces.
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

        let leftover = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "desktop_kind": BotDesktopKind.dedicatedLocalVM.rawValue,
        ])
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
        // Name still persists. Leftover permission_mode still coerces.
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

        let leftover = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "permission_mode": AgentPermissionMode.fullAccess.rawValue,
        ])
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
        // still coerces. Schema does not grow a host_brokered_writes key.
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

        let leftover = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "permission_mode": AgentPermissionMode.fullAccess.rawValue,
        ])
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
        // labels do the Instruction now. set_settings still accepted
        // Test run / test_run as an empty success, so first-chat
        // invented a persist. Reject the advertised name. Name still
        // persists. Leftover permission_mode still coerces. Schema
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

        let leftover = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "permission_mode": AgentPermissionMode.fullAccess.rawValue,
        ])
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
        // permission_mode still coerces. Schema does not grow a memory
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
        XCTAssertEqual(still.memory.count, 0, "Memory reject must not persist a fact")
        XCTAssertEqual(still.permissionMode, AgentPermissionMode.supervised.rawValue)

        let remembered = try service.call(name: BotSelfConfigCatalog.putMemory, arguments: [
            "fact": "Prefers dark mode",
        ])
        XCTAssertEqual(remembered.memory.first?.content, "Prefers dark mode")

        let leftover = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "permission_mode": AgentPermissionMode.fullAccess.rawValue,
        ])
        XCTAssertEqual(leftover.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(leftover.name, "Piper")
        XCTAssertEqual(leftover.memory.first?.content, "Prefers dark mode")

        let renamed = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "name": "Piper Prime",
        ])
        XCTAssertEqual(renamed.name, "Piper Prime")
        XCTAssertEqual(renamed.permissionMode, AgentPermissionMode.supervised.rawValue)
        XCTAssertEqual(renamed.memory.first?.content, "Prefers dark mode")
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
        // WHY: Studio already says Default route. Tools named route, so
        // first-chat "change your Default route" invented a hop or left
        // opus. Canonical provider still wins. Explicit model still wins.
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

        let fromDefaultRoute = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "default_route": "Grok",
        ])
        XCTAssertEqual(fromDefaultRoute.provider, AgentProvider.grok.rawValue)
        XCTAssertEqual(fromDefaultRoute.model, BotRoute.defaultModel(for: .grok))

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
        // WHY: Studio Add already binds via setSkillBinding(enabled: true).
        // Tools required enabled, so first-chat "add this skill" invented a
        // hop or a fake add tool. Omit enabled to Add it Enabled. Advertised
        // Enabled token persists. Explicit Off still disables. Canonical
        // enabled still wins.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)

        let fromAdd = try service.call(name: BotSelfConfigCatalog.setSkill, arguments: [
            "skill_id": "weekly-account-health",
        ])
        XCTAssertEqual(fromAdd.skills.map(\.skillID), ["weekly-account-health"], "Add persists")
        XCTAssertEqual(fromAdd.skills.first?.enabled, true, "Add persists")
        XCTAssertEqual(try store.listSkillBindings(botID: bot.id).first?.enabled, true)

        let fromEnabledToken = try service.call(name: BotSelfConfigCatalog.setSkill, arguments: [
            "skill_id": "weekly-account-health",
            "enabled": "Enabled",
        ])
        XCTAssertEqual(fromEnabledToken.skills.first?.enabled, true, "advertised Enabled token persists")
        XCTAssertEqual(try store.listSkillBindings(botID: bot.id).first?.enabled, true)

        let fromOff = try service.call(name: BotSelfConfigCatalog.setSkill, arguments: [
            "skill_id": "weekly-account-health",
            "enabled": "Off",
        ])
        XCTAssertEqual(fromOff.skills.first?.enabled, false, "Off persists")
        XCTAssertEqual(try store.listSkillBindings(botID: bot.id).first?.enabled, false)

        let enabledWins = try service.call(name: BotSelfConfigCatalog.setSkill, arguments: [
            "skill_id": "weekly-account-health",
            "enabled": true,
        ])
        XCTAssertEqual(enabledWins.skills.first?.enabled, true, "enabled wins")
        XCTAssertEqual(try store.listSkillBindings(botID: bot.id).first?.enabled, true)
    }

    func test_setSkillCatalogDescribesAdd_becauseThatIsTheStudioPath() {
        // WHY: Schema does not grow an add tool. Description must name Add
        // so first-chat does not invent a hop. enabled stays optional.
        let description = BotSelfConfigCatalog.description(for: BotSelfConfigCatalog.setSkill)
        XCTAssertTrue(description.contains("Add"), "Same path as Studio Add")
        let schema = BotSelfConfigCatalog.schema(for: BotSelfConfigCatalog.setSkill)
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["skill_id"])
        XCTAssertNotNil(properties?["enabled"])
        XCTAssertNil(properties?["add"], "add is advertised on set_skill, not a second schema key")
        XCTAssertEqual(schema["required"] as? [String], ["skill_id"])
        let enabled = properties?["enabled"] as? [String: Any]
        XCTAssertEqual(enabled?["description"] as? String, "Enabled. Omit to Add. Same field as Studio Skills.")
        let skillID = properties?["skill_id"] as? [String: Any]
        XCTAssertEqual(skillID?["description"] as? String, "Catalog id. Same field as Studio Add.")
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

    func test_encodeSnapshotUsesCatalogMutateKeys_becauseNestedIdCollidedWithTheBot() throws {
        // WHY: Forget/remove/toggle require memory_id / skill_id / routine_id.
        // Snapshot used Swift id / skillID / scheduleNote, so same-turn
        // "forget that" invented a hop or sent the bot id. Hermes agents
        // reuse the key the last write returned. Canonical Swift fields stay.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let remembered = try service.call(name: BotSelfConfigCatalog.putMemory, arguments: [
            "content": "Prefers dark mode",
        ])
        _ = try service.call(name: BotSelfConfigCatalog.setSkill, arguments: [
            "skill_id": "weekly-account-health",
            "enabled": true,
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
        XCTAssertEqual(memory.first?["memory_id"] as? String, remembered.memory.first?.id, "memory_id persists")
        XCTAssertNil(memory.first?["id"], "nested id omitted")
        XCTAssertEqual(memory.first?["content"] as? String, "Prefers dark mode")
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

    func test_encodeSnapshotUsesCatalogSettingsKeys_becauseSwiftNamesInventedAHop() throws {
        // WHY: set_settings requires notifications_enabled / provider_instance_id.
        // Snapshot used Swift notificationsEnabled / providerInstanceID, so
        // same-turn "turn notifications off" invented a hop. Hermes agents
        // reuse the key the last write returned. Canonical Swift fields stay.
        // Leftover permission/desktop stay camelCase — catalog omits those writes.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let service = BotSelfConfigService(callerBotID: bot.id, store: store)
        let after = try service.call(name: BotSelfConfigCatalog.setSettings, arguments: [
            "notifications_enabled": false,
            "provider_instance_id": "claude-work",
        ])
        XCTAssertFalse(after.notificationsEnabled)
        XCTAssertEqual(after.providerInstanceID, "claude-work")
        let json = try service.encodeSnapshot(try service.snapshot())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["notifications_enabled"] as? Bool, false, "notifications_enabled persists")
        XCTAssertNil(object["notificationsEnabled"], "Swift notificationsEnabled omitted")
        XCTAssertEqual(object["provider_instance_id"] as? String, "claude-work", "provider_instance_id persists")
        XCTAssertNil(object["providerInstanceID"], "Swift providerInstanceID omitted")
        XCTAssertEqual(object["permissionMode"] as? String, AgentPermissionMode.supervised.rawValue)
        XCTAssertNil(object["permission_mode"], "leftover permission stays unnamed")
        XCTAssertEqual(object["desktopKind"] as? String, BotDesktopKind.logicalExecutionSpace.rawValue)
        XCTAssertNil(object["desktop_kind"], "leftover desktop stays unnamed")
        XCTAssertEqual(try store.get(id: bot.id)?.notificationsEnabled, false)
        XCTAssertEqual(try store.getRevision(id: try XCTUnwrap(store.get(id: bot.id)?.currentRevisionID))?.providerInstanceID, "claude-work")
    }
}
