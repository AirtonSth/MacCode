import Foundation
import XCTest
@testable import SocketServer

/// Structural JSON-RPC success envelope sizing must match `JSONEncoder.encode.count`.
///
/// WHY: agent.thread.read, plan.notes, and checkpoint.list success ceilings used to
/// allocate encoder `Data` on every fit/measure. EventBus walks must stay length-equal
/// so admitted pages do not change.
final class AgentAppEnvelopeStructuralBytesTests: XCTestCase {

    func test_jsonRPCResponseByteCount_matchesJSONEncoder() throws {
        let encoder = JSONEncoder()
        let envelopes: [(JSONRPCID?, JSONValue)] = [
            (.number(7), .object([
                "events": .array([
                    .object(["kind": .string("token"), "text": .string("hi")]),
                ]),
                "has_more": .bool(false),
            ])),
            (.string("req-1"), .object([
                "notes": .array([.string("a"), .null, .bool(true)]),
            ])),
            (nil, .string("café 🐱 quote\" slash/path")),
            (.number(0), .array([])),
            (.number(-42), .object([:])),
            (.string("id\"\\"), .object([
                "items": .array([
                    .object([
                        "id": .string("c1"),
                        "title": .string("step"),
                    ]),
                ]),
                "truncated": .bool(false),
                "next_before": .null,
                "catalog_revision": .number(3),
            ])),
        ]

        for (id, result) in envelopes {
            let encoded = try encoder.encode(JSONRPCResponse(id: id, result: result))
            XCTAssertEqual(
                EventBus.jsonRPCResponseByteCount(id: id, result: result),
                encoded.count,
                "structural != JSONEncoder for id=\(String(describing: id)) json=\(String(data: encoded, encoding: .utf8) ?? "?")"
            )
        }
    }

    func test_planNotesEncodedJSONRPCResponseBytes_matchesEncoder() throws {
        let encoder = JSONEncoder()
        let notes = "plan notes structural sizing fixture"
        let page = try PlanNotesProjectionV1.page(
            notes: notes,
            caps: .init(
                offsetBytes: 0,
                maxBytes: PlanNotesProjectionV1.maxBytesCeiling,
                expectedContentDigest: nil
            )
        )
        let ids: [JSONRPCID] = [.number(1), .string("abc"), .number(0)]
        for id in ids {
            let structural = try PlanNotesProjectionV1.encodedJSONRPCResponseBytes(id: id, page: page)
            let encoded = try encoder.encode(JSONRPCResponse(id: id, result: page.json))
            XCTAssertEqual(
                structural,
                encoded.count,
                "plan.notes structural != JSONEncoder for id=\(id)"
            )
        }
    }

    func test_jsonRPCIDByteCount_matchesEncoder() throws {
        let encoder = JSONEncoder()
        let ids: [JSONRPCID] = [.number(0), .number(-1), .number(Int.max), .string(""), .string("x"), .string("a\"b")]
        for id in ids {
            let encoded = try encoder.encode(id)
            XCTAssertEqual(EventBus.jsonRPCIDByteCount(id), encoded.count)
        }
    }
}
