import XCTest
import CoreModel

final class BotComputerGuestSpecTests: XCTestCase {
    func test_createOptionsForceLoopbackAndRejectForeignHome() throws {
        // WHY: HostIp 0.0.0.0 would publish noVNC on the LAN. A bind of
        // $HOME or BotHome would leak this Mac into the guest.
        let botID = BotID()
        let support = URL(fileURLWithPath: "/tmp/rc-app-support-spec")
        let home = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID).path
        let viewerToken = String(repeating: "a", count: 32)
        let options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: home,
            appSupport: support,
            viewerToken: viewerToken
        )
        XCTAssertEqual(options.hostIP, "127.0.0.1")
        XCTAssertEqual(options.hostPort, 0)
        XCTAssertEqual(options.image, BotComputerGuestSpec.imageTag)
        XCTAssertEqual(options.labels["remotecode.managed"], "1")
        XCTAssertTrue(options.binds.first?.hasPrefix(home) == true)
        XCTAssertEqual(options.network, BotComputerGuestSpec.networkName(botID: botID))
        XCTAssertEqual(
            options.environment["REMOTECODE_VIEWER_TOKEN"],
            viewerToken
        )
        XCTAssertGreaterThanOrEqual(options.shmSize, BotComputerGuestSpec.minimumShmBytes)
        let recipe = BotComputerGuestSpec.recipeURL(appSupport: support, botID: botID).path
        XCTAssertEqual(recipe, home,
            "each bot's editable Dockerfile must live directly in that bot's persisted guest home")
        XCTAssertNotEqual(
            recipe,
            BotComputerGuestSpec.recipeURL(appSupport: support, botID: BotID()).path,
            "Docker build contexts must remain isolated per bot"
        )
        XCTAssertTrue(BotComputerGuestSpec.execUsesRoot("apt-get install -y sl"))
        XCTAssertFalse(BotComputerGuestSpec.execUsesRoot("ls"))

        XCTAssertThrowsError(
            try BotComputerGuestSpec.containerCreateOptions(
                botID: botID,
                guestHome: "/tmp/evil",
                appSupport: support,
                viewerToken: viewerToken
            )
        )
        XCTAssertThrowsError(
            try BotComputerGuestSpec.containerCreateOptions(
                botID: botID,
                guestHome: NSHomeDirectory(),
                appSupport: support,
                viewerToken: viewerToken
            )
        )
        let url = try BotComputerGuestSpec.screenURL(hostPort: 49152, token: viewerToken)
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/vnc.html")
        XCTAssertTrue(url.query?.contains("autoconnect=1") == true)
        XCTAssertTrue(url.query?.contains("view_only=0") == true)
        // WHY: noVNC plays bell.oga whenever the guest xterm rings; the
        // viewer must stay silent (ui.js only plays when bell == "on").
        XCTAssertTrue(url.query?.contains("bell=off") == true)
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "path" })?.value,
            "websockify?token=\(viewerToken)"
        )
        XCTAssertThrowsError(try BotComputerGuestSpec.screenURL(hostPort: 49152, token: "guessable"))
        XCTAssertThrowsError(try BotComputerGuestSpec.validateScreenURL(URL(string: "http://0.0.0.0:6080/")!))
        XCTAssertThrowsError(try BotComputerGuestSpec.viewerURL(URL(string: "http://0.0.0.0:6080/")!))
        let loopback = try BotComputerGuestSpec.viewerURL(url)
        XCTAssertEqual(loopback.host, "127.0.0.1")
    }

    func test_ensureNetworkCreatesABridgeNotAnInternalNetwork() throws {
        // WHY: --internal would block apt-get and Chromium on the guest.
        var seen: [[String]] = []
        let cli = BotComputerDockerCLI(run: { args in
            seen.append(args)
            return Data()
        })
        try cli.ensureNetwork(name: "remotecode-bot-example")
        XCTAssertEqual(seen.first, ["network", "create", "remotecode-bot-example"])
        XCTAssertFalse(seen.contains(where: { $0.contains("--internal") }))
    }

    func test_inspectFormatSurvivesAStoppedContainer() throws {
        // WHY: Docker clears published ports on stop. The old Go template
        // crashed inspect, so Start after Stop treated the guest as missing
        // and docker create failed on the leftover name.
        var formats: [String] = []
        let cli = BotComputerDockerCLI(run: { args in
            if args.first == "inspect" {
                if let idx = args.firstIndex(of: "-f"), args.index(after: idx) < args.endIndex {
                    formats.append(args[args.index(after: idx)])
                }
                return Data("false sha256:img 0\n".utf8)
            }
            return Data()
        })
        let inspect = try cli.inspect(name: "remotecode-bot-example")
        XCTAssertFalse(inspect.running)
        XCTAssertEqual(inspect.hostPort, 0)
        XCTAssertFalse(
            formats.contains(where: { $0.contains("index (index .NetworkSettings.Ports") }),
            "inspect must not index Ports[0] on a stopped container"
        )
        XCTAssertTrue(formats.contains(where: { $0.contains("{{else}}0{{end}}") }))
    }

    func test_notReadyErrorCopyIsHuman_becauseSaveBotMustNotAlertCaseName() {
        // WHY: Save Bot presented String(describing:) of the enum case, so
        // the owner saw an alert titled Bots with the body "notReady".
        XCTAssertEqual(BotComputerGuestError.notReady.description, "Docker desktop is not ready.")
        XCTAssertEqual(BotComputerGuestError.notReady.errorDescription, "Docker desktop is not ready.")
        XCTAssertEqual(String(describing: BotComputerGuestError.notReady), "Docker desktop is not ready.")
        XCTAssertNotEqual(String(describing: BotComputerGuestError.notReady), "notReady")
    }

    func test_playwrightMCPCommandDrivesGuestChromiumHeadedOnXvfb() {
        // WHY: the host bridge builds `docker exec -i <container>` around this
        // exact argv; a drifted flag silently breaks bot browsing. It must run
        // headed on DISPLAY=:1 so the user can watch/log in via the guest
        // screen, and use /usr/bin/chromium so Playwright never downloads
        // browsers in the guest.
        XCTAssertEqual(BotComputerGuestSpec.playwrightMCPCommand(), [
            "env", "DISPLAY=:1",
            "npx", "--yes", "@playwright/mcp@latest",
            "--executable-path", "/usr/bin/chromium",
            "--no-sandbox",
            "--user-data-dir", "/home/remotecode/.browser-profiles/playwright",
        ])
        XCTAssertEqual(
            Array(BotComputerGuestSpec.playwrightMCPCommand(userDataDir: "/home/remotecode/custom").suffix(2)),
            ["--user-data-dir", "/home/remotecode/custom"]
        )
        XCTAssertTrue(
            BotComputerGuestSpec.playwrightGuestUserDataDir.hasPrefix(BotComputerGuestSpec.guestUserHome + "/"),
            "the profile must live in the bind-mounted guest home so logins persist"
        )
    }

    func test_recipeRevision4ShipsNodeForGuestPlaywrightMCP() throws {
        // WHY: playwrightMCPCommand needs npx inside the guest, and only the
        // revision bump makes existing guests rebuild (a stale label rebuilds
        // the image) — Dockerfile content and revision must move together.
        XCTAssertEqual(BotComputerGuestSpec.recipeRevision, "4")
        let dockerfile = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/Resources/ComputerGuest/Dockerfile"),
            encoding: .utf8
        )
        XCTAssertTrue(dockerfile.contains("nodejs"))
        XCTAssertTrue(dockerfile.contains("npm"))
    }
}
