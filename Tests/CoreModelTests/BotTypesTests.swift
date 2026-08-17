import XCTest
@testable import CoreModel

final class BotTypesTests: XCTestCase {
    func test_handleNormalize_stripsAtAndRejectsIllegalForms_becauseStoredIdentityMustBeUnambiguous() {
        XCTAssertEqual(BotHandle.normalize(" Piper "), "piper")
        XCTAssertEqual(BotHandle.normalize("@Piper"), "piper")
        XCTAssertEqual(BotHandle.normalize("piper_2"), "piper_2")
        XCTAssertEqual(BotHandle.normalize("p-1"), "p-1")
        XCTAssertEqual(BotHandle.normalize(String(repeating: "a", count: 32)), String(repeating: "a", count: 32))

        XCTAssertNil(BotHandle.normalize(""), "empty handle would collide with 'no handle'")
        XCTAssertNil(BotHandle.normalize("@"), "a lone @ is not a stored handle")
        XCTAssertNil(BotHandle.normalize("Piper!"), "punctuation would make uniqueness checks locale-dependent")
        XCTAssertNil(BotHandle.normalize("has space"), "spaces are not part of the stored handle alphabet")
        XCTAssertNil(BotHandle.normalize(String(repeating: "a", count: 33)), "handles longer than 32 break directory labels")
    }

    func test_revisionDigest_isStableAcrossRouteOrder_becauseRepublishMustNotDriftWithoutContentChange() {
        let botID = BotID(UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!)
        let first = BotRevision.digest(
            botID: botID,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["chat", "plan"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace
        )
        let reordered = BotRevision.digest(
            botID: botID,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["plan", "chat"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace
        )
        let changedSoul = BotRevision.digest(
            botID: botID,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be verbose.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["chat", "plan"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace
        )

        XCTAssertEqual(first, reordered, "route-set order is not identity — users would see a fake revision")
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, changedSoul, "soul is published identity; a change must produce a new digest")
    }

    func test_desktopLabel_statesSharedAccount_becauseUsersMustNotThinkP1aIsAnIsolatedVM() throws {
        XCTAssertEqual(
            BotDesktopKind.logicalExecutionSpace.honestyLabel,
            "Same macOS account; not isolated. Not a dedicated Desktop."
        )
        XCTAssertFalse(
            BotDesktopKind.logicalExecutionSpace.honestyLabel.localizedCaseInsensitiveContains("virtual machine")
        )
        XCTAssertEqual(
            BotDesktopKind.dedicatedLocalVM.advertisedOrLogical,
            .logicalExecutionSpace,
            "leftover Dedicated local VM must display and publish as Logical execution space"
        )
        XCTAssertFalse(
            BotDesktopKind.logicalExecutionSpace.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: false)
            ),
            "even the shared-account desktop is unavailable when the control plane is off"
        )
        XCTAssertFalse(
            BotDesktopKind.dedicatedLocalVM.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: true, botsDesktopVMEnabled: true)
            ),
            "Dedicated local VM must not be selectable even if a leftover persist flag is on"
        )
        XCTAssertFalse(
            BotDesktopKind.managedRemoteMac.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: true, botsDesktopRemoteEnabled: false)
            )
        )
        XCTAssertFalse(
            BotDesktopKind.managedRemoteMac.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: true, botsDesktopRemoteEnabled: true)
            ),
            "Managed remote Mac must not be selectable even if a leftover persist flag is on"
        )
        XCTAssertEqual(BotDesktopKind.advertisedKinds, [.logicalExecutionSpace])
        XCTAssertFalse(BotDesktopKind.dedicatedLocalVM.isAdvertised)
        XCTAssertFalse(BotDesktopKind.managedRemoteMac.isAdvertised)
        let leftover = try JSONDecoder().decode(
            BotDesktopKind.self,
            from: Data(#""dedicatedLocalVM""#.utf8)
        )
        XCTAssertEqual(leftover, .dedicatedLocalVM, "stored leftover kinds must still decode")
        XCTAssertEqual(leftover.advertisedOrLogical, .logicalExecutionSpace)
    }

    func test_standingInstructionsFallback_keepsCustomSoulAsEscapeHatch() {
        // WHY: Hermes never overwrites a user SOUL.md. Role auto-config may
        // refresh the starter, but a written soul must stay untouched.
        let starter = BotStandingInstructions.fallback(name: "New Agent", title: "", description: "")
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertFalse(starter.contains("You are"), "identity layer owns the name")
        XCTAssertFalse(starter.contains("@"), "identity layer owns the handle")
        XCTAssertFalse(starter.contains("Route:"), "route layer owns the provider/model")
        XCTAssertFalse(starter.contains("Default route:"), "route layer owns Default route")
        XCTAssertFalse(starter.contains("Model:"), "route layer owns Model")
        XCTAssertFalse(starter.contains("Fallback order"), "compiler layer owns Fallback order")
        XCTAssertFalse(starter.contains("Workspace"), "compiler layer owns Workspace")
        XCTAssertFalse(starter.contains("Test run:"), "compiler layer owns Test run")
        XCTAssertFalse(starter.contains("Routines (not while"), "compiler layer owns Routines")
        XCTAssertFalse(starter.contains(BotStandingInstructions.rememberFactTool), "tools layer owns remember")
        XCTAssertFalse(starter.contains(BotStandingInstructions.correctFactTool), "tools layer owns correct")
        XCTAssertFalse(starter.contains(BotStandingInstructions.removeSkillTool), "tools layer owns remove")
        XCTAssertFalse(starter.contains(BotStandingInstructions.openBrowserTool), "tools layer owns browser")
        XCTAssertFalse(starter.contains("bot_get_settings"), "compile already injects live settings")
        XCTAssertTrue(tools.contains(BotStandingInstructions.rememberFactTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.changeJobTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.forgetFactTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.correctFactTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.setSkillTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.removeSkillTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.saveRoutineTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.setRoutineEnabledTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.openBrowserTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.getBrowserTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.waitLoginTool))
        XCTAssertTrue(tools.contains("teammate's"))
        XCTAssertTrue(starter.contains(BotStandingInstructions.generatedSignature))
        XCTAssertTrue(BotStandingInstructions.looksGenerated(""))
        XCTAssertTrue(BotStandingInstructions.looksGenerated(starter))
        XCTAssertFalse(BotStandingInstructions.looksGenerated("Own the inbox."))
        XCTAssertEqual(
            BotStandingInstructions.resolved(name: "Piper", title: "Scout", soul: ""),
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
        )
        XCTAssertEqual(
            BotStandingInstructions.resolved(name: "Piper", title: "Scout", soul: starter),
            starter
        )
        XCTAssertEqual(
            BotStandingInstructions.resolved(name: "Piper", title: "Scout", soul: "Own the inbox."),
            "Own the inbox."
        )
    }

    func test_routeDefaultModelMatchesStudioPicker_becauseProviderOnlyWritesMustNotKeepLeftover() {
        // WHY: Studio already binds opus / gpt-5.6-sol / grok-4.6 when the
        // owner switches provider. A provider-only set_settings write used
        // to keep the leftover model, so first-chat "switch to Grok" still
        // ran opus. Hermes agents land on the advertised model for that route.
        XCTAssertEqual(BotRoute.defaultModel(for: .claude), "opus")
        XCTAssertEqual(BotRoute.defaultModel(for: .codex), AgentDefaultModelSelection.codexBuiltInDefault)
        XCTAssertEqual(BotRoute.defaultModel(for: .grok), "grok-4.6")
        XCTAssertEqual(BotRoute.advertisedTitle(for: .claude), "Claude")
        XCTAssertEqual(BotRoute.advertisedTitle(for: .codex), "Codex")
        XCTAssertEqual(BotRoute.advertisedTitle(for: .grok), "Grok")
        XCTAssertEqual(BotRoute.parse("Grok")?.provider, .grok)
        XCTAssertEqual(BotRoute.parse("claude")?.provider, .claude)
        XCTAssertEqual(BotRoute.parse("Grok · grok-4.6")?.provider, .grok)
        XCTAssertEqual(BotRoute.parse("Grok · grok-4.6")?.model, "grok-4.6")
        XCTAssertNil(BotRoute.parse("ChatGPT"))
    }

    func test_avatarParseAcceptsStudioNames_becauseToolsMustPersistTheChipLabel() {
        // WHY: Studio Avatar chips announce Person / Star. Tools must
        // persist those names on the same publish path, not invent a
        // second picker.
        XCTAssertEqual(BotAvatar.parse("Star"), "star.fill")
        XCTAssertEqual(BotAvatar.parse("person.crop.circle"), "person.crop.circle")
        XCTAssertEqual(BotAvatar.advertisedName(for: "star.fill"), "Star")
        XCTAssertNil(BotAvatar.parse("Robot"))
        XCTAssertTrue(BotAvatar.advertisedSymbols.contains("person.crop.circle"))
        XCTAssertEqual(Set(BotAvatar.advertisedSymbols).count, BotAvatar.advertisedSymbols.count)
    }

    func test_admittedToolsNameDescriptionRouteAndNotifications_becauseSetSettingsAlreadyPublishesThem() {
        // WHY: Studio already says Default route and Model. Tools named
        // route only, so first-chat "change your Default route" invented
        // a hop. Hermes agents persist the advertised name.
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertTrue(tools.contains(BotStandingInstructions.changeJobTool))
        XCTAssertTrue(tools.contains("name, Role, Instructions, description, Default route, Model, notifications, or avatar"))
        XCTAssertFalse(tools.contains("job, standing instructions"), "leftover job is not advertised")
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains("notifications, or avatar"),
            "tools layer owns the remaining set_settings writes"
        )
        XCTAssertFalse(tools.contains("handle"), "handle is create-only")
        XCTAssertFalse(tools.contains("permission"), "leftover permission is not a live write")
        XCTAssertFalse(tools.contains("desktop"), "leftover desktop is not a live write")
    }

    func test_admittedToolsNameAddSkill_becauseSetSkillAlreadyBindsTheCatalogId() {
        // WHY: Studio already has Add and set_skill already writes the
        // binding. Tools only said enable or disable, so first-chat
        // "add this skill" invented a hop. Hermes agents add in place.
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertTrue(tools.contains("add a skill"))
        XCTAssertTrue(tools.contains(BotStandingInstructions.setSkillTool))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("add a skill"),
            "tools layer owns add"
        )
    }

    func test_admittedToolsNameRoutineActive_becauseStudioSaysActiveNotOnOrOff() {
        // WHY: Studio already says Active and set_routine_enabled already
        // persists that key. Tools said on or off, so first-chat "set this
        // Active" invented a hop. Hermes agents persist the advertised
        // toggle name. Schema key stays enabled.
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertTrue(tools.contains("set a routine Active or Off"))
        XCTAssertTrue(tools.contains(BotStandingInstructions.setRoutineEnabledTool))
        XCTAssertFalse(tools.contains("on or off"), "advertised Active replaces leftover on/off")
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Active or Off"),
            "tools layer owns Active"
        )
    }

    func test_controlPlaneFlags_failClosed_becauseLaterPhasesMustNotRunWithoutTheShippedSlice() {
        let defaults = BotControlPlaneFlags()
        XCTAssertTrue(defaults.isBotControlPlaneActive, "P1a ships the control plane on")
        XCTAssertTrue(defaults.isBotMemoryActive, "P1a includes memory CRUD")
        XCTAssertFalse(defaults.isBotEffectsActive)
        XCTAssertFalse(defaults.isBotAutonomyActive)
        XCTAssertFalse(defaults.isBotDesktopVMActive)
        XCTAssertFalse(defaults.isBotDesktopRemoteActive)
        XCTAssertFalse(defaults.isBotChannelsActive)

        let planeOff = BotControlPlaneFlags(
            botsControlPlaneEnabled: false,
            botsMemoryEnabled: true,
            botsEffectsEnabled: true,
            botsAutonomyEnabled: true,
            botsDesktopVMEnabled: true,
            botsDesktopRemoteEnabled: true,
            botsChannelsEnabled: true
        )
        XCTAssertFalse(planeOff.isBotControlPlaneActive)
        XCTAssertFalse(planeOff.isBotMemoryActive)
        XCTAssertFalse(planeOff.isBotEffectsActive)
        XCTAssertFalse(planeOff.isBotAutonomyActive)
        XCTAssertFalse(planeOff.isBotDesktopVMActive)
        XCTAssertFalse(planeOff.isBotDesktopRemoteActive)
        XCTAssertFalse(planeOff.isBotChannelsActive)
    }

    func test_routineCopy_doesNotClaimAppClosedExecution() {
        XCTAssertTrue(BotRoutineCopy.testRunHonestyCaption.contains("Test runs are real work"))
        XCTAssertTrue(BotRoutineCopy.testRunHonestyCaption.contains("App-closed schedules stay off"))
    }

    func test_permissionAdvertisedOrSupervised_becauseLeftoverFullAccessIsNotLivePower() {
        XCTAssertEqual(BotPermission.advertisedModes, [.supervised])
        XCTAssertEqual(BotPermission.advertisedOrSupervised(.supervised), .supervised)
        XCTAssertEqual(BotPermission.advertisedOrSupervised(.fullAccess), .supervised)
        XCTAssertEqual(BotPermission.advertisedOrSupervised(.autoAcceptEdits), .supervised)
        XCTAssertTrue(BotPermission.honestyLabel.contains("Supervised"))
        XCTAssertTrue(BotPermission.honestyLabel.contains("Host-brokered writes stay off"))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(BotPermission.honestyLabel),
            "permission honesty is a compiler layer, not starter soul"
        )
    }
}
