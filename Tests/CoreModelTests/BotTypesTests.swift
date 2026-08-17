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
        XCTAssertTrue(starter.contains("New Agent"))
        XCTAssertTrue(starter.contains(BotStandingInstructions.generatedSignature))
        XCTAssertTrue(BotStandingInstructions.looksGenerated(""))
        XCTAssertTrue(BotStandingInstructions.looksGenerated(starter))
        XCTAssertFalse(BotStandingInstructions.looksGenerated("Own the inbox."))
        XCTAssertEqual(
            BotStandingInstructions.resolved(name: "Piper", title: "Scout", soul: ""),
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
        )
        XCTAssertTrue(
            BotStandingInstructions.resolved(name: "Piper", title: "Scout", soul: starter)
                .contains("Your job is: Scout.")
        )
        XCTAssertEqual(
            BotStandingInstructions.resolved(name: "Piper", title: "Scout", soul: "Own the inbox."),
            "Own the inbox."
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
}
