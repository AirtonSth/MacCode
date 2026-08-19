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
        XCTAssertThrowsError(try BotComputerGuestSpec.validateScreenURL(URL(string: "http://0.0.0.0:6080/")!))
        XCTAssertThrowsError(try BotComputerGuestSpec.viewerURL(URL(string: "http://0.0.0.0:6080/")!))
        let loopback = try BotComputerGuestSpec.viewerURL(url)
        XCTAssertEqual(loopback.host, "127.0.0.1")
    }
}
