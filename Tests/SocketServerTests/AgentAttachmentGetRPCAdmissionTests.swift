import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// WHY: the iPhone fetches screenshot thumbnails with a read-scoped device
/// (and inside its read-only batch), and only on hosts that advertise the
/// RPC; it must never be a ledger mutation, or a viewer would need write access.
final class AgentAttachmentGetRPCAdmissionTests: XCTestCase {
    func test_getIsReadScopedBatchableAndNotAMutation() {
        XCTAssertTrue(JSONRPCDispatcher.isReadOnlyBatchMethod("agent.attachment.get"))
        XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: "agent.attachment.get"), "read")
        XCTAssertFalse(JSONRPCDispatcher.hostMutationMethods.contains("agent.attachment.get"))
        XCTAssertEqual(AgentAttachmentGet.method, "agent.attachment.get")
    }

    @MainActor
    func test_capabilitiesAdvertiseAttachmentGetOnBothAuthorities() async throws {
        let payload = DirectHTTPServer.capabilitiesProjection(loopbackOnly: false)
            .authenticatedPayload(serverID: "host-1", bootEpoch: 42)
        let capabilities = try XCTUnwrap(payload["capabilities"] as? [String: Any])
        let agent = try XCTUnwrap(capabilities["agent"] as? [String: Any])
        XCTAssertEqual(agent["attachment_get_v1"] as? Bool, true)
        let decoded = try JSONDecoder().decode(
            HostCapabilities.Agent.self,
            from: JSONSerialization.data(withJSONObject: agent)
        )
        XCTAssertTrue(decoded.attachmentGetV1, "the treaty type the iPhone gates on reads the same flag")

        let response = await JSONRPCDispatcher(router: FakeRouter()).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil
        ))
        XCTAssertEqual(response.result?.objectValue?["agent"]?.objectValue?["attachment_get_v1"], .bool(true))
    }

    func test_olderHostWithoutFlagDecodesAsUnsupported() throws {
        let decoded = try JSONDecoder().decode(
            HostCapabilities.Agent.self,
            from: Data(#"{"providers":["codex"],"supports_stream_events":true,"supports_resume":true}"#.utf8)
        )
        XCTAssertFalse(decoded.attachmentGetV1)
    }

    func test_errorKindsMapFromTheirDomain() {
        func kind(_ code: Int, _ value: String) -> RemoteCodeError.Kind {
            RemoteCodeError(code: code, message: "", data: .object([
                "domain": .string("attachment"), "kind": .string(value),
            ])).kind
        }
        XCTAssertEqual(kind(AgentAttachmentGetWire.notFoundCode, "not_found"), .attachmentNotFound)
        XCTAssertEqual(kind(AgentAttachmentGetWire.tooLargeCode, "too_large"), .attachmentTooLarge)
        XCTAssertEqual(kind(AgentAttachmentGetWire.unavailableCode, "unavailable"), .attachmentUnavailable)
    }

    func test_paramsClampToCeilingAndPixelRange() throws {
        let base: [String: JSONValue] = [
            "thread_id": .string(UUID().uuidString),
            "message_id": .string(UUID().uuidString),
            "attachment_id": .string("abc"),
        ]
        let defaults = try AgentAttachmentGetWire.request(from: base)
        XCTAssertNil(defaults.thumbnailMaxPixels, "no thumbnail unless asked")
        XCTAssertEqual(defaults.maxBytes, AgentAttachmentGetWire.maxBytesCeiling)

        var asked = base
        asked["thumbnail"] = .bool(true)
        asked["thumbnail_max_pixels"] = .number(100_000)
        asked["max_bytes"] = .number(Double(AgentAttachmentGetWire.maxBytesCeiling * 10))
        let clamped = try AgentAttachmentGetWire.request(from: asked)
        XCTAssertEqual(clamped.thumbnailMaxPixels, AgentAttachmentGetWire.thumbnailMaxPixelsRange.upperBound)
        XCTAssertEqual(clamped.maxBytes, AgentAttachmentGetWire.maxBytesCeiling)

        asked["thumbnail_max_pixels"] = .number(1)
        XCTAssertEqual(try AgentAttachmentGetWire.request(from: asked).thumbnailMaxPixels,
                       AgentAttachmentGetWire.thumbnailMaxPixelsRange.lowerBound)
        asked.removeValue(forKey: "thumbnail_max_pixels")
        XCTAssertEqual(try AgentAttachmentGetWire.request(from: asked).thumbnailMaxPixels,
                       AgentAttachmentGetWire.defaultThumbnailMaxPixels)
    }
}
