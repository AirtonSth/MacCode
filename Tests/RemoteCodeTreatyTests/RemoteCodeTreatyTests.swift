import XCTest
@testable import RemoteCodeTreaty

final class RemoteCodeTreatyTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testCompatibilityUsesStableSnakeCaseWireKeys() throws {
        let value = TreatyCompatibility(
            current: TreatyVersion(major: 1, minor: 0),
            supportedMajors: [0, 1]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any]
        )
        XCTAssertEqual((object["current"] as? [String: Any])?["major"] as? Int, 1)
        XCTAssertEqual((object["current"] as? [String: Any])?["minor"] as? Int, 0)
        XCTAssertEqual(object["supported_majors"] as? [Int], [0, 1])
    }

    func testBotSendParamsPreserveExistingWireShape() throws {
        let params = BotSend.Params(
            botID: "bot-1",
            conversationID: "conversation-1",
            text: "hello",
            submitKey: "return",
            attachmentIDs: ["grant-1"]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(params)) as? [String: Any]
        )
        XCTAssertEqual(object["bot_id"] as? String, "bot-1")
        XCTAssertEqual(object["conversation_id"] as? String, "conversation-1")
        XCTAssertEqual(object["submit_key"] as? String, "return")
        XCTAssertEqual(object["attachment_ids"] as? [String], ["grant-1"])
        XCTAssertNil(object["client_request_id"])
    }

    func testBotSendResultDecodesCurrentStartedReceipt() throws {
        let data = Data(#"""
        {
          "request_id":"request-1","client_request_id":"request-1",
          "receipt_id":"receipt-1","status":"completed","host_id":"host-1","bot_id":"bot-1",
          "readback":{"host_id":"host-1","bot_id":"bot-1","request_id":"request-1",
            "client_request_id":"request-1","conversation_id":"conversation-1","run_id":"run-1",
            "enqueued":false,"run":{"thread_id":"thread-1"}}
        }
        """#.utf8)

        let result = try decoder.decode(BotSend.Result.self, from: data)
        XCTAssertEqual(result.requestID, "request-1")
        XCTAssertEqual(result.receiptID, "receipt-1")
        XCTAssertEqual(result.hostID, "host-1")
        XCTAssertEqual(result.botID, "bot-1")
        XCTAssertEqual(result.conversationID, "conversation-1")
        XCTAssertEqual(result.runID, "run-1")
        XCTAssertEqual(result.disposition, .started(threadID: "thread-1"))
    }

    func testAuthenticatedCapabilitiesDecodeTreatyAndIdentity() throws {
        let data = Data(#"""
        {
          "authenticated":true,"server_id":"host-1","boot_epoch":42,
          "treaty":{"current":{"major":1,"minor":0},"supported_majors":[0,1]},
          "capabilities":{"surface_types":["terminal","agentApp"],
            "agent":{"providers":["codex"],"supports_stream_events":true,"supports_resume":true},
            "git":{"read_only":false},"feature_flags":{"remote_access_enabled":true}}
        }
        """#.utf8)

        let envelope = try decoder.decode(AuthenticatedCapabilities.self, from: data)
        XCTAssertTrue(envelope.authenticated)
        XCTAssertEqual(envelope.serverID, "host-1")
        XCTAssertEqual(envelope.bootEpoch, 42)
        XCTAssertEqual(envelope.treaty?.current, TreatyVersion(major: 1, minor: 0))
        XCTAssertEqual(envelope.capabilities.surfaceTypes, ["terminal", "agentApp"])
        XCTAssertEqual(envelope.capabilities.agent.providers, ["codex"])
    }

    func testEventEnvelopePreservesKnownAndUnknownKinds() throws {
        let known = try decoder.decode(
            RemoteCodeEventEnvelope.self,
            from: Data(#"{"seq":7,"kind":"agent.run.started","payload":{"run_id":"run-1"},"ts":1.5}"#.utf8)
        )
        XCTAssertEqual(known.kind, .agentRunStarted)
        XCTAssertFalse(known.isUnknown)

        let unknown = try decoder.decode(
            RemoteCodeEventEnvelope.self,
            from: Data(#"{"seq":8,"kind":"future.kind","payload":{"value":1},"ts":2}"#.utf8)
        )
        XCTAssertEqual(unknown.rawKind, "future.kind")
        XCTAssertTrue(unknown.isUnknown)
    }

    func testRemoteCodeErrorPreservesUnknownHostCode() throws {
        let value = RemoteCodeError(code: -39999, message: "future", data: nil)
        XCTAssertEqual(value.kind, .unknown(-39999))
    }
}
