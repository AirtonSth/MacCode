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

    func test_desktopLabel_statesSharedAccount_becauseUsersMustNotThinkP1aIsAnIsolatedVM() {
        XCTAssertEqual(
            BotDesktopKind.logicalExecutionSpace.honestyLabel,
            "Same macOS account; not isolated. Not a dedicated Desktop."
        )
        XCTAssertFalse(
            BotDesktopKind.logicalExecutionSpace.honestyLabel.localizedCaseInsensitiveContains("virtual machine")
        )
        XCTAssertEqual(
            BotDesktopKind.dedicatedLocalVM.honestyLabel,
            BotDesktopKind.dedicatedLocalVMHonestyLabel
        )
        XCTAssertTrue(
            BotDesktopKind.dedicatedLocalVM.honestyLabel.localizedCaseInsensitiveContains("not running")
        )
        XCTAssertTrue(
            BotDesktopKind.dedicatedLocalVM.honestyLabel.localizedCaseInsensitiveContains("not isolated")
        )
        XCTAssertFalse(
            BotDesktopKind.dedicatedLocalVM.honestyLabel.localizedCaseInsensitiveContains("active now")
        )
        XCTAssertEqual(BotDesktopKind.dedicatedLocalVM.displayTitle, "Dedicated local VM")
        XCTAssertEqual(BotDesktopKind.dedicatedLocalVM.statusPill, "Local VM · not running")
        XCTAssertFalse(
            BotDesktopKind.logicalExecutionSpace.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: false)
            ),
            "even the shared-account desktop is unavailable when the control plane is off"
        )
        XCTAssertTrue(
            BotDesktopKind.dedicatedLocalVM.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: true, botsDesktopVMEnabled: false)
            ),
            "select/persist the VM kind without requiring a guest runtime flag"
        )
        XCTAssertFalse(
            BotDesktopKind.dedicatedLocalVM.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: false, botsDesktopVMEnabled: true)
            ),
            "a later-phase flag cannot enable VM desktop when the control plane is off"
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
        XCTAssertEqual(BotDesktopKind.advertisedKinds, [.logicalExecutionSpace, .dedicatedLocalVM])
        XCTAssertFalse(BotDesktopKind.managedRemoteMac.isAdvertised)
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

    func test_desktopVMHonesty_neverClaimsARunningGuestWithoutAnImage() {
        let identity = BotDesktopVMIdentity(
            botID: BotID(),
            bundlePath: "/tmp/bot-desktop",
            state: .stopped,
            lastError: BotDesktopVMIdentity.noGuestImageCode,
            virtualizationSupported: true
        )
        XCTAssertTrue(identity.honestyLabel.localizedCaseInsensitiveContains("no guest image"))
        XCTAssertTrue(identity.honestyLabel.localizedCaseInsensitiveContains("not isolated"))
        XCTAssertFalse(identity.honestyLabel.localizedCaseInsensitiveContains("active now"))
        XCTAssertEqual(identity.statusPill, "Local VM · stopped")

        let failed = BotDesktopVMIdentity(
            botID: BotID(),
            bundlePath: "/tmp/bot-desktop",
            state: .failed,
            lastError: BotDesktopVMIdentity.bootFailedCode,
            lastErrorDetail: "The disk image is not a valid virtual disk.",
            virtualizationSupported: true
        )
        XCTAssertTrue(failed.honestyLabel.localizedCaseInsensitiveContains("boot failed"))
        XCTAssertTrue(failed.honestyLabel.localizedCaseInsensitiveContains("not isolated"))
        XCTAssertFalse(failed.honestyLabel.localizedCaseInsensitiveContains("active now"))
        XCTAssertFalse(
            failed.honestyLabel.localizedCaseInsensitiveContains("not a valid virtual disk"),
            "honesty must not dump Virtualization.framework's raw failure"
        )
        XCTAssertEqual(failed.statusPill, "Local VM · failed")

        let starting = BotDesktopVMIdentity(
            botID: BotID(),
            bundlePath: "/tmp/bot-desktop",
            state: .starting,
            virtualizationSupported: true
        )
        XCTAssertTrue(starting.honestyLabel.localizedCaseInsensitiveContains("starting"))
        XCTAssertTrue(starting.honestyLabel.localizedCaseInsensitiveContains("not isolated"))
        XCTAssertFalse(starting.honestyLabel.localizedCaseInsensitiveContains("boot failed"))
        XCTAssertEqual(starting.statusPill, "Local VM · starting")

        let installing = BotDesktopVMIdentity(
            botID: BotID(),
            bundlePath: "/tmp/bot-desktop",
            state: .installing,
            virtualizationSupported: true
        )
        XCTAssertTrue(installing.honestyLabel.localizedCaseInsensitiveContains("installing"))
        XCTAssertTrue(installing.honestyLabel.localizedCaseInsensitiveContains("restore image"))
        XCTAssertTrue(installing.honestyLabel.localizedCaseInsensitiveContains("not isolated"))
        XCTAssertFalse(installing.honestyLabel.localizedCaseInsensitiveContains("active now"))
        XCTAssertEqual(installing.statusPill, "Local VM · installing")

        let invalidRestore = BotDesktopVMIdentity(
            botID: BotID(),
            bundlePath: "/tmp/bot-desktop",
            state: .failed,
            lastError: BotDesktopVMIdentity.invalidRestoreImageCode,
            lastErrorDetail: "The file is not a valid restore image.",
            virtualizationSupported: true
        )
        XCTAssertTrue(invalidRestore.honestyLabel.localizedCaseInsensitiveContains("not a valid macOS"))
        XCTAssertTrue(invalidRestore.honestyLabel.localizedCaseInsensitiveContains("not isolated"))
        XCTAssertFalse(invalidRestore.honestyLabel.localizedCaseInsensitiveContains("virtual disk"))
        XCTAssertFalse(
            invalidRestore.honestyLabel.localizedCaseInsensitiveContains("failed to load"),
            "Studio/Desk must not paint the raw restore-image dump"
        )
        XCTAssertFalse(invalidRestore.honestyLabel.localizedCaseInsensitiveContains("unable to load"))
    }

    func test_routineCopy_doesNotClaimAppClosedExecution() {
        XCTAssertTrue(BotRoutineCopy.testRunHonestyCaption.contains("Test runs are real work"))
        XCTAssertTrue(BotRoutineCopy.testRunHonestyCaption.contains("App-closed schedules stay off"))
    }
}
