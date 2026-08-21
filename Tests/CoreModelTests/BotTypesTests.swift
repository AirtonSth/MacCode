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

    func test_slugFollowsNameUntilOwnerDefinesIt() {
        // WHY: Studio Slug tracks the name (CEO -> ceo) until the owner
        // types a custom slug. Unique New Agent suffixes must still follow.
        XCTAssertEqual(BotHandle.derive(from: "CEO"), "ceo")
        XCTAssertEqual(BotHandle.derive(from: "@Piper"), "piper")
        XCTAssertTrue(BotHandle.shouldFollowName(handle: "ceo", name: "CEO"))
        XCTAssertTrue(BotHandle.shouldFollowName(handle: "new-agent-19", name: "New Agent"))
        XCTAssertFalse(BotHandle.shouldFollowName(handle: "boss", name: "CEO"))
        XCTAssertFalse(BotHandle.shouldFollowName(handle: "piper", name: "Scout"))
    }

    func test_revisionEncodingAndDigestExcludeProviderRouting_becauseRouteBelongsToCallingThread() throws {
        // WHY: selecting Claude, Codex, or Grok is a user choice on a thread.
        // Publishing the same Bot from different callers must neither persist
        // that route nor create a fake identity revision.
        let botID = BotID(UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!)
        let first = BotRevision.digest(
            botID: botID,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace
        )
        let changedSoul = BotRevision.digest(
            botID: botID,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be verbose.",
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace
        )
        let revision = BotRevision(
            botID: botID,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: first
        )
        let encoded = try JSONEncoder().encode(revision)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, changedSoul, "soul is published identity; a change must produce a new digest")
        XCTAssertNil(object["provider"])
        XCTAssertNil(object["providerInstanceID"])
        XCTAssertNil(object["provider_instance_id"])
        XCTAssertNil(object["model"])
        XCTAssertNil(object["reasoningEffort"])
        XCTAssertNil(object["compatibleRouteSet"])
    }

    func test_desktopLabel_statesSharedAccount_becauseUsersMustNotThinkP1aIsAnIsolatedVM() throws {
        XCTAssertEqual(
            BotDesktopKind.logicalExecutionSpace.honestyLabel,
            "This Mac · default browser. Same macOS account; not isolated."
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
        XCTAssertEqual(
            BotDesktopKind.logicalExecutionSpace.displayTitle,
            "macOS with the default macOS browser"
        )
        XCTAssertEqual(
            BotDesktopKind.botOwnedBrowser.displayTitle,
            "macOS with the bot's own browser"
        )
        XCTAssertEqual(
            BotDesktopKind.dockerDesktop.displayTitle,
            "Docker with GUI"
        )
        XCTAssertEqual(
            BotDesktopKind.advertisedKinds,
            [.logicalExecutionSpace, .botOwnedBrowser, .dockerDesktop]
        )
        XCTAssertFalse(BotDesktopKind.dedicatedLocalVM.isAdvertised)
        XCTAssertFalse(BotDesktopKind.managedRemoteMac.isAdvertised)
        XCTAssertTrue(
            BotDesktopKind.botOwnedBrowser.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: true)
            )
        )
        XCTAssertFalse(
            BotDesktopKind.dockerDesktop.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: true),
                guestReady: false
            )
        )
        XCTAssertTrue(
            BotDesktopKind.dockerDesktop.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: true),
                guestReady: true
            )
        )
        let leftover = try JSONDecoder().decode(
            BotDesktopKind.self,
            from: Data(#""dedicatedLocalVM""#.utf8)
        )
        XCTAssertEqual(leftover, .dedicatedLocalVM, "stored leftover kinds must still decode")
        XCTAssertEqual(leftover.advertisedOrLogical, .logicalExecutionSpace)
    }

    func test_standingToolsNameWriteSkillFiles() {
        // WHY: First-chat "add a skill" used to call bot_set_skill and
        // hide the files. The tools layer must name skills/<slug>/SKILL.md.
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertTrue(tools.contains("skills/<slug>/SKILL.md"))
        XCTAssertTrue(tools.contains(BotStandingInstructions.writeMemoryFileTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.removeSkillTool))
        XCTAssertFalse(tools.contains("bot_set_skill"))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains("SKILL.md"),
            "tools layer owns skill file names"
        )
    }

    func test_standingToolsNameWriteMemoryFiles() {
        // WHY: First-chat "remember this" used to call bot_put_memory and
        // hide the files. The tools layer must name the markdown paths.
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertEqual(
            BotStandingInstructions.rememberFactTool,
            BotStandingInstructions.writeMemoryFileTool
        )
        XCTAssertTrue(tools.contains("bot_write_home_file"))
        XCTAssertTrue(tools.contains("MEMORY.md"))
        XCTAssertTrue(tools.contains("memory/YYYY-MM-DD.md"))
        XCTAssertFalse(tools.contains("bot_put_memory"))
        XCTAssertFalse(tools.contains("bot_forget_memory"))
        XCTAssertFalse(tools.contains("bot_correct_memory"))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains("MEMORY.md"),
            "tools layer owns memory file names"
        )
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
        XCTAssertFalse(starter.contains("Approval mode"), "compiler layer owns Approval mode")
        XCTAssertFalse(starter.contains("Desktop"), "compiler layer owns Desktop")
        XCTAssertFalse(starter.contains("Test run:"), "compiler layer owns Test run")
        XCTAssertFalse(starter.contains("Routines (not while"), "compiler layer owns Routines")
        XCTAssertFalse(starter.contains(BotStandingInstructions.rememberFactTool), "tools layer owns remember")
        XCTAssertFalse(starter.contains(BotStandingInstructions.correctFactTool), "tools layer owns correct")
        XCTAssertFalse(starter.contains(BotStandingInstructions.removeSkillTool), "tools layer owns remove")
        XCTAssertFalse(starter.contains(BotStandingInstructions.openBrowserTool), "tools layer owns browser")
        XCTAssertFalse(starter.contains("bot_get_settings"), "compile already injects live settings")
        XCTAssertTrue(tools.contains(BotStandingInstructions.writeMemoryFileTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.rememberFactTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.changeJobTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.forgetFactTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.correctFactTool))
        XCTAssertFalse(tools.contains(BotStandingInstructions.setSkillTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.removeSkillTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.saveRoutineTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.setRoutineEnabledTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.openBrowserTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.getBrowserTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.waitLoginTool))
        XCTAssertTrue(tools.contains("teammate's"))
        XCTAssertTrue(tools.contains(BotStandingInstructions.macosHarnessTool))
        XCTAssertTrue(tools.contains(BotStandingInstructions.generatedMacOSHarnessLine))
        XCTAssertFalse(tools.contains("desktop"), "leftover desktop is not a live write")
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

    func test_avatarParseAcceptsBlobatarToken_becauseStudioComposerPersistsTheToken() {
        // WHY: Studio Avatar is a blobatar composer. Tools must persist
        // Cloud / Auto on the same publish path, not invent an SF hop.
        XCTAssertEqual(BotAvatar.parse("cloud"), "blobatar:v1:cloud:idle:none:auto")
        XCTAssertEqual(
            BotAvatar.parse("blobatar:v1:sun:happy:circle:pink"),
            "blobatar:v1:sun:happy:circle:pink"
        )
        XCTAssertEqual(BotAvatar.advertisedName(for: "blobatar:v1:cloud:idle:none:auto"), "Cloud")
        XCTAssertFalse(BotAvatar.advertisedName(for: "blobatar:v1:auto:idle:none:auto").contains("."))
        XCTAssertNil(BotAvatar.parse("blobatar:v1:nope:idle:none:auto"))
    }

    func test_admittedToolsNameDescriptionRouteAndNotifications_becauseSetSettingsAlreadyPublishesThem() {
        // WHY: Studio already says Default route and Model. Tools named
        // route only, so first-chat "change your Default route" invented
        // a hop. Hermes agents persist the advertised name.
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertTrue(tools.contains(BotStandingInstructions.changeJobTool))
        XCTAssertTrue(tools.contains("name, Role, Instructions, description, notifications, or avatar"))
        XCTAssertFalse(tools.contains("Default route"), "Studio no longer publishes a route")
        XCTAssertFalse(tools.contains("job, standing instructions"), "leftover job is not advertised")
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains("notifications, or avatar"),
            "tools layer owns the remaining set_settings writes"
        )
        XCTAssertFalse(tools.contains("handle,"), "handle is create-only")
        XCTAssertFalse(tools.contains("or handle"), "handle is create-only")
        XCTAssertFalse(tools.contains("permission"), "leftover permission is not a live write")
        XCTAssertFalse(tools.contains("desktop"), "leftover desktop is not a live write")
    }

    func test_admittedToolsNameMacOSHarness() {
        // WHY: bots must drive the Mac through macos-harness on every
        // provider. Naming remotecode-computer-use would send them back
        // to the retired MCP.
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertTrue(tools.contains(BotStandingInstructions.macosHarnessTool))
        XCTAssertTrue(tools.contains("mac.see"))
        XCTAssertTrue(tools.contains("Do not call remotecode-computer-use"))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains(BotStandingInstructions.macosHarnessTool),
            "tools layer owns macos-harness"
        )
    }

    func test_admittedToolsNameAddSkill_becauseSetSkillAlreadyBindsTheCatalogId() {
        // WHY: Studio already has Add and set_skill already writes the
        // binding. Tools only said enable or disable, so first-chat
        // "add this skill" invented a hop. Hermes agents add in place.
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertTrue(tools.contains("skills/<slug>/SKILL.md"))
        XCTAssertFalse(tools.contains(BotStandingInstructions.setSkillTool))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("SKILL.md"),
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
