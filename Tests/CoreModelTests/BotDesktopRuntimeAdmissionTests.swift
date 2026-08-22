import XCTest
import CoreModel

final class BotDesktopRuntimeAdmissionTests: XCTestCase {
    func test_threeOwnerPhrasesAndPerKindAdmission() throws {
        // WHY: Studio must offer the three owner-facing runtimes, and
        // publish must change what the next send may drive.
        XCTAssertEqual(
            BotDesktopKind.advertisedKinds.map(\.displayTitle),
            [
                "macOS with the owner's Google Chrome",
                "macOS with the bot's own browser",
                "Docker with GUI",
            ]
        )

        let host = BotDesktopAdmission.forPublished(.logicalExecutionSpace)
        XCTAssertTrue(host.allowsHostDefaultBrowser)
        XCTAssertTrue(host.allowsNativeHostComputerUse)
        XCTAssertFalse(host.allowsGuestComputer)
        XCTAssertFalse(
            host.allowsBotOwnedBrowser,
            "this-Mac bots browse with the owner's Google Chrome, never bot_browser_*"
        )

        let owned = BotDesktopAdmission.forPublished(.botOwnedBrowser)
        XCTAssertTrue(owned.allowsBotOwnedBrowser)
        XCTAssertFalse(owned.allowsNativeHostComputerUse)
        XCTAssertFalse(owned.allowsHostDefaultBrowser)

        let docker = BotDesktopAdmission.forPublished(.dockerDesktop)
        XCTAssertTrue(docker.allowsGuestComputer)
        XCTAssertFalse(docker.allowsNativeHostComputerUse)
        XCTAssertTrue(
            docker.allowsBotOwnedBrowser,
            "a docker bot's own browser is Playwright inside its guest"
        )

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
        XCTAssertEqual(leftover.kind, .dedicatedLocalVM)
        XCTAssertFalse(leftover.allowsNativeHostComputerUse)
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
        XCTAssertTrue(host.contains(BotStandingInstructions.computerUseObservationTool))
        XCTAssertTrue(host.contains("Google Chrome"), "this-Mac bots must be told to browse in the owner's Chrome")
        XCTAssertFalse(
            host.contains(BotStandingInstructions.openBrowserTool),
            "naming bot_browser_* on an owner's-Chrome desktop would advertise a refused tool"
        )
        XCTAssertFalse(host.contains(BotStandingInstructions.computerObserveTool))

        let owned = BotStandingInstructions.admittedToolsText(for: .botOwnedBrowser)
        XCTAssertFalse(owned.contains(BotStandingInstructions.generatedNativeHostComputerLine))
        XCTAssertTrue(owned.contains(BotStandingInstructions.openBrowserTool))
        XCTAssertTrue(owned.contains("Playwright"), "the bot's own browser must be named as Playwright, not a RemoteCode tab")

        let docker = BotStandingInstructions.admittedToolsText(for: .dockerDesktop)
        XCTAssertTrue(docker.contains(BotStandingInstructions.computerObserveTool))
        XCTAssertTrue(docker.contains(BotStandingInstructions.computerExecTool))
        XCTAssertTrue(docker.contains(BotStandingInstructions.computerRebuildTool))
        XCTAssertFalse(docker.contains(BotStandingInstructions.generatedNativeHostComputerLine))
        XCTAssertTrue(
            docker.contains(BotStandingInstructions.openBrowserTool),
            "docker bots browse via bot_browser_* backed by Playwright inside the guest"
        )
        XCTAssertTrue(docker.contains("Playwright"))
        XCTAssertTrue(
            docker.contains("If those browser tools fail"),
            "docker fallback is the guest's Chrome-engine browser driven by computer-use, not the host"
        )
    }

    func test_browserRouteFollowsPublishedDesktopKind_becauseBotsNeverGetTheInAppBrowser() {
        // WHY: bot_browser_* must run Playwright locally for a bot-owned
        // browser and Playwright inside the guest for Docker. Owner's-Chrome
        // desktops (and leftover VM kinds) must refuse with copy that points
        // at native host browser bridge — never at a RemoteCode in-app browser tab.
        XCTAssertEqual(BotBrowserRoute.forPublished(.botOwnedBrowser), .playwrightLocal)
        XCTAssertEqual(BotBrowserRoute.forPublished(.dockerDesktop), .playwrightGuest)
        for kind: BotDesktopKind in [.logicalExecutionSpace, .dedicatedLocalVM, .managedRemoteMac] {
            guard case let .refused(message) = BotBrowserRoute.forPublished(kind) else {
                XCTFail("\(kind) must refuse bot_browser_*")
                continue
            }
            XCTAssertTrue(message.contains("Google Chrome"), "refusal must name the browser the bot really gets")
            XCTAssertTrue(message.contains("never"), "refusal must forbid the in-app browser, not merely omit it")
            XCTAssertTrue(message.contains("RemoteCode"), "refusal must name the banned in-app browser")
        }
    }
}
