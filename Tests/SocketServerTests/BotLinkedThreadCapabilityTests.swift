import XCTest
@testable import SocketServer

final class BotLinkedThreadCapabilityTests: XCTestCase {
    func test_authenticatedPayload_includesBotLinkedThreadV1() {
        // WHY: iOS Bot Chat fast-path binds started receipts to a linked
        // thread only when the authenticated host capabilities advertise
        // bot.linked_thread_v1. Missing the marker would force unsafe
        // latest-tail inference on a host that already implements it.
        let payload = DirectHTTPServer.capabilitiesProjection(loopbackOnly: false)
            .authenticatedPayload(serverID: "host-1", bootEpoch: 42)
        let capabilities = payload["capabilities"] as? [String: Any]
        let bot = capabilities?["bot"] as? [String: Any]
        XCTAssertEqual(
            bot?["linked_thread_v1"] as? Bool,
            true,
            "authenticated capabilities.bot.linked_thread_v1 must be true"
        )
        XCTAssertEqual(
            bot?["queue_controls"] as? [String],
            ["remove", "update", "reorder", "force_now"]
        )
    }

    func test_publicProjection_alsoAdvertisesLinkedThreadV1() {
        let bot = DirectHTTPServer.capabilitiesProjection(loopbackOnly: true)
            .publicPayload()["bot"] as? [String: Any]
        XCTAssertEqual(bot?["linked_thread_v1"] as? Bool, true)
    }
}
