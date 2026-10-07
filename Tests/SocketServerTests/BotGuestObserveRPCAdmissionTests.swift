import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// WHY: the iPhone's live viewer polls `bot.guest.state` (a read a read-only
/// device may call and batch) and toggles control with `bot.guest.control`,
/// a write that must go through the receipt ledger. It shows the viewer only
/// on hosts that advertise `bot.guest_observe_v1`.
final class BotGuestObserveRPCAdmissionTests: XCTestCase {
    func test_stateIsAReadAndControlIsALedgerMutation() {
        XCTAssertTrue(JSONRPCDispatcher.isReadOnlyBatchMethod("bot.guest.state"))
        XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: "bot.guest.state"), "read")
        XCTAssertFalse(JSONRPCDispatcher.isReadOnlyBatchMethod("bot.guest.control"))
        XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: "bot.guest.control"), "write")
        XCTAssertTrue(JSONRPCDispatcher.hostMutationMethods.contains("bot.guest.control"))
    }

    func test_controlPreflightNeedsABotAndTakeOrRelease() {
        let bot = UUID().uuidString
        for action in ["take", "release"] {
            XCTAssertNoThrow(try HostMutationContract.preflight(method: "bot.guest.control", params: [
                "bot_id": .string(bot), "action": .string(action),
            ]), action)
        }
        XCTAssertThrowsError(try HostMutationContract.preflight(method: "bot.guest.control", params: [
            "bot_id": .string(bot), "action": .string("steal"),
        ]))
        XCTAssertThrowsError(try HostMutationContract.preflight(method: "bot.guest.control", params: [
            "action": .string("take"),
        ]))
    }

    func test_authenticatedCapabilitiesAdvertiseTheLiveViewer() throws {
        let payload = DirectHTTPServer.capabilitiesProjection(loopbackOnly: false)
            .authenticatedPayload(serverID: "host-1", bootEpoch: 42)
        let capabilities = try XCTUnwrap(payload["capabilities"] as? [String: Any])
        let bot = try XCTUnwrap(capabilities["bot"] as? [String: Any])
        XCTAssertEqual(bot["guest_observe_v1"] as? Bool, true)
        let data = try JSONSerialization.data(withJSONObject: bot)
        XCTAssertTrue(try JSONDecoder().decode(HostCapabilities.Bot.self, from: data).guestObserveV1)
    }
}
