import XCTest
import CoreModel

final class BotDesktopRuntimeAdmissionTests: XCTestCase {
    func test_threeOwnerPhrasesAndPerKindAdmission() throws {
        // WHY: Studio must offer the three owner-facing runtimes, and
        // publish must change what the next send may drive.
        XCTAssertEqual(
            BotDesktopKind.advertisedKinds.map(\.displayTitle),
            [
                "macOS with the default macOS browser",
                "macOS with the bot's own browser",
                "Docker with GUI",
            ]
        )

        let host = BotDesktopAdmission.forPublished(.logicalExecutionSpace)
        XCTAssertTrue(host.allowsHostDefaultBrowser)
        XCTAssertTrue(host.allowsMacOSHarness)
        XCTAssertFalse(host.allowsGuestComputer)

        let owned = BotDesktopAdmission.forPublished(.botOwnedBrowser)
        XCTAssertTrue(owned.allowsBotOwnedBrowser)
        XCTAssertFalse(owned.allowsMacOSHarness)
        XCTAssertFalse(owned.allowsHostDefaultBrowser)

        let docker = BotDesktopAdmission.forPublished(.dockerDesktop)
        XCTAssertTrue(docker.allowsGuestComputer)
        XCTAssertFalse(docker.allowsMacOSHarness)
        XCTAssertFalse(docker.allowsBotOwnedBrowser)

        XCTAssertThrowsError(
            try BotDesktopAdmission.requireSend(kind: .dockerDesktop, guestReady: false)
        )
        XCTAssertEqual(
            try BotDesktopAdmission.requireSend(kind: .dockerDesktop, guestReady: true).kind,
            .dockerDesktop
        )
        XCTAssertEqual(
            try BotDesktopAdmission.requireSend(kind: .logicalExecutionSpace, guestReady: false).kind,
            .logicalExecutionSpace
        )
        XCTAssertEqual(
            try BotDesktopAdmission.requireSend(kind: .botOwnedBrowser, guestReady: false).kind,
            .botOwnedBrowser
        )

        let leftover = BotDesktopAdmission.forPublished(.dedicatedLocalVM)
        XCTAssertEqual(leftover.kind, .logicalExecutionSpace)
        XCTAssertFalse(
            BotDesktopKind.dedicatedLocalVM.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: true),
                guestReady: true
            ),
            "a ready guest must not turn leftover Dedicated local VM into Docker"
        )
    }

    func test_compileFollowsAdmission_becauseSendMustSeeTheSameTools() {
        let host = BotStandingInstructions.admittedToolsText(for: .logicalExecutionSpace)
        XCTAssertTrue(host.contains(BotStandingInstructions.macosHarnessTool))
        XCTAssertTrue(host.contains(BotStandingInstructions.openBrowserTool))
        XCTAssertFalse(host.contains(BotStandingInstructions.computerObserveTool))

        let owned = BotStandingInstructions.admittedToolsText(for: .botOwnedBrowser)
        XCTAssertFalse(owned.contains(BotStandingInstructions.generatedMacOSHarnessLine))
        XCTAssertTrue(owned.contains(BotStandingInstructions.openBrowserTool))

        let docker = BotStandingInstructions.admittedToolsText(for: .dockerDesktop)
        XCTAssertTrue(docker.contains(BotStandingInstructions.computerObserveTool))
        XCTAssertTrue(docker.contains(BotStandingInstructions.computerExecTool))
        XCTAssertTrue(docker.contains(BotStandingInstructions.computerRebuildTool))
        XCTAssertFalse(docker.contains(BotStandingInstructions.generatedMacOSHarnessLine))
        XCTAssertFalse(docker.contains(BotStandingInstructions.generatedBrowserLine))
    }
}
