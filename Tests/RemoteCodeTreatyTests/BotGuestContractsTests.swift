import XCTest
@testable import RemoteCodeTreaty

/// WHY: the iPhone builds its live viewer from these shapes; they must decode
/// exactly what the host sends and default the feature off for older hosts.
final class BotGuestContractsTests: XCTestCase {
    private let decoder = JSONDecoder()

    func test_olderHostsDoNotAdvertiseTheLiveViewer() throws {
        let old = try decoder.decode(HostCapabilities.Bot.self, from: Data(#"{"queue_controls":[]}"#.utf8))
        XCTAssertFalse(old.guestObserveV1, "no observe or Take/Release on an older host")
        let current = try decoder.decode(
            HostCapabilities.Bot.self,
            from: Data(#"{"queue_controls":[],"guest_observe_v1":true}"#.utf8)
        )
        XCTAssertTrue(current.guestObserveV1)
    }

    func test_controlParamsAndReceiptMatchTheHostWire() throws {
        let params = BotGuestControl.Params(botID: "b1", action: "take", clientRequestID: "r1")
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any]
        )
        XCTAssertEqual(encoded["bot_id"] as? String, "b1")
        XCTAssertEqual(encoded["action"] as? String, "take")
        XCTAssertEqual(encoded["client_request_id"] as? String, "r1")
        XCTAssertEqual(BotGuestControl.method, "bot.guest.control")

        let result = try decoder.decode(BotGuestControl.Result.self, from: Data(#"""
        {"request_id":"r1","receipt_id":"rc1","status":"completed","bot_id":"b1",
         "readback":{"host_id":"h1","bot_id":"b1","status":"running","controlled_by_user":true,
                     "control_action":"take","viewer_path":"/vnc.html","grant_generation":2}}
        """#.utf8))
        XCTAssertEqual(result.readback.controlledByUser, true)
        XCTAssertEqual(result.readback.controlAction, "take")
        XCTAssertEqual(result.readback.status, "running")
    }

    func test_observeBlockAndAgentStepEventDecode() throws {
        let block = try decoder.decode(BotGuestObserveBlock.self, from: Data(
            #"{"outcome":"capture_failed","min_interval_ms":500,"error":"observeFailed"}"#.utf8
        ))
        XCTAssertEqual(block, BotGuestObserveBlock(outcome: "capture_failed", minIntervalMS: 500, error: "observeFailed"))

        let event = try decoder.decode(BotGuestAgentStepEvent.self, from: Data(#"""
        {"bot_id":"b1","reason":"agent_step","step":"exec","frame_stale":true,"controlled_by_user":false}
        """#.utf8))
        XCTAssertNil(event.hostID, "host_id is absent until a client read the bot's guest state")
        XCTAssertEqual(event.reason, BotGuestAgentStepEvent.reason)
        XCTAssertEqual(event.step, "exec")
    }
}
