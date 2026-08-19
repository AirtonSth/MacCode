import XCTest
import CoreModel

final class BotComputerGuestSpecTests: XCTestCase {
    func test_createOptionsForceLoopbackAndRejectForeignHome() throws {
        // WHY: HostIp 0.0.0.0 would publish noVNC on the LAN. A bind of
        // $HOME or BotHome would leak this Mac into the guest.
        let botID = BotID()
        let support = URL(fileURLWithPath: "/tmp/rc-app-support-spec")
        let home = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID).path
        let options = try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: home,
            appSupport: support
        )
        XCTAssertEqual(options.hostIP, "127.0.0.1")
        XCTAssertEqual(options.hostPort, 0)
        XCTAssertEqual(options.image, BotComputerGuestSpec.imageTag)
        XCTAssertEqual(options.labels["remotecode.managed"], "1")
        XCTAssertTrue(options.binds.first?.hasPrefix(home) == true)
        XCTAssertEqual(options.network, BotComputerGuestSpec.networkName(botID: botID))
        XCTAssertGreaterThanOrEqual(options.shmSize, BotComputerGuestSpec.minimumShmBytes)
        let recipe = BotComputerGuestSpec.recipeURL(appSupport: support, botID: botID).path
        XCTAssertTrue(recipe.hasPrefix(home))
        XCTAssertTrue(recipe.hasSuffix("/computer"))
        XCTAssertTrue(BotComputerGuestSpec.execUsesRoot("apt-get install -y sl"))
        XCTAssertFalse(BotComputerGuestSpec.execUsesRoot("ls"))

        XCTAssertThrowsError(
            try BotComputerGuestSpec.containerCreateOptions(
                botID: botID,
                guestHome: "/tmp/evil",
                appSupport: support
            )
        )
        XCTAssertThrowsError(
            try BotComputerGuestSpec.containerCreateOptions(
                botID: botID,
                guestHome: NSHomeDirectory(),
                appSupport: support
            )
        )
        let url = try BotComputerGuestSpec.screenURL(hostPort: 49152, token: "abc")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/vnc.html")
        XCTAssertTrue(url.query?.contains("autoconnect=1") == true)
        XCTAssertTrue(url.query?.contains("view_only=0") == true)
        // WHY: noVNC plays bell.oga whenever the guest xterm rings; the
        // viewer must stay silent (ui.js only plays when bell == "on").
        XCTAssertTrue(url.query?.contains("bell=off") == true)
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
}
