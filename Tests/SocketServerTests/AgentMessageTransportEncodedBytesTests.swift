import Foundation
import XCTest
@testable import SocketServer

/// Structural JSON byte counts must match `JSONEncoder.encode(...).count`.
///
/// WHY: agent.message list/get binary-search fit used to allocate encoder
/// `Data` ~log(N) times per RPC. The walk must stay length-equal so envelope
/// truncation / attachment wire caps do not change which payload fits.
final class AgentMessageTransportEncodedBytesTests: XCTestCase {

    func test_encodedResponseAndValueBytes_matchJSONEncoderCount() throws {
        let encoder = JSONEncoder()
        let envelopes: [(JSONRPCID?, JSONValue)] = [
            (.number(7), .object([
                "messages": .array([
                    .object([
                        "id": .string("00000000-0000-0000-0000-000000000002"),
                        "content": .string("hello"),
                        "body_available": .bool(true),
                        "body_truncated": .bool(false),
                        "body_byte_count": .number(5),
                    ]),
                ]),
                "has_more": .bool(false),
            ])),
            (.string("req-1"), .object([
                "nested": .array([
                    .bool(true), .bool(false), .null, .number(0), .string(""),
                ]),
            ])),
            (nil, .string("café 🐱 slash/path quote\" tab\tend")),
            (.number(0), .array([])),
            (.number(-42), .object([:])),
            (.string(""), .number(Double.pi)),
            (.number(Int.max), .object([
                "body_append": .string("line\nquote\"slash\\path/tab\tend"),
                "progress": .number(1.0 / 3.0),
                "thread_id": .string("t"),
            ])),
            (.string("id\"\\"), .object([
                "attachments": .array([
                    .object([
                        "id": .string("a1"),
                        "displayName": .string("shot.png"),
                        "kind": .string("image"),
                        "sha256": .string("abc"),
                        "sizeBytes": .number(1024),
                        "mimeType": .string("image/png"),
                    ]),
                ]),
            ])),
        ]

        for (id, result) in envelopes {
            let encoded = try encoder.encode(JSONRPCResponse(id: id, result: result))
            XCTAssertEqual(
                AgentMessageTransport.encodedResponseBytes(id: id, result: result),
                encoded.count,
                "envelope walk != JSONEncoder for id=\(String(describing: id)) json=\(String(data: encoded, encoding: .utf8) ?? "?")"
            )
            XCTAssertEqual(
                EventBus.jsonRPCResponseByteCount(id: id, result: result),
                encoded.count
            )
            let valueData = try encoder.encode(result)
            XCTAssertEqual(
                AgentMessageTransport.encodedValueBytes(result),
                valueData.count,
                "value walk != JSONEncoder json=\(String(data: valueData, encoding: .utf8) ?? "?")"
            )
            XCTAssertEqual(
                EventBus.jsonValueByteCount(result),
                valueData.count
            )
        }
    }

    func test_encodedValueBytes_matchesEncoderForPrimitiveJSONValues() throws {
        let encoder = JSONEncoder()
        let values: [JSONValue] = [
            .null,
            .bool(true),
            .bool(false),
            .number(0),
            .number(-0.0),
            .number(1e20),
            .string(""),
            .string("a"),
            .array([.string("x"), .object(["k": .number(1)])]),
        ]
        for value in values {
            let encoded = try encoder.encode(value)
            XCTAssertEqual(
                AgentMessageTransport.encodedValueBytes(value),
                encoded.count,
                "walk != encoder json=\(String(data: encoded, encoding: .utf8) ?? "?")"
            )
        }
    }
}
