import XCTest
@testable import SocketServer

// Tests for the NDJSON framing contract used by `rc2 events stream`.
//
// The server writes each pushed event as:
//   JSONEncoder().encode(JSONRPCResponse) + 0x0A
// (see UnixSocketServer.write(fd:response:))
//
// The CLI reads these lines verbatim and forwards them to stdout.
// These tests verify the encoding contract independently of the socket loop.
//
// Manual smoke-test (requires running macOS app):
//   rc2 events stream
//   # In another shell: rc2 ping          <- triggers events
//   # Observe: one JSON object per line, each with "jsonrpc","id","result".
//   # result.kind, result.seq, result.ts, result.payload present.
//   # Ctrl-C terminates cleanly.

final class EventsStreamNDJSONTests: XCTestCase {

    private let encoder = JSONEncoder()

    // MARK: - single-event framing

    /// One event -> one JSON line terminated by exactly one newline.
    /// This is the atomic contract: if framing breaks, the NDJSON consumer
    /// sees either a parse error (missing newline) or merged lines (extra data).
    func test_singleEvent_producesOneNewlineTerminatedJSONLine() throws {
        let event = makeFakeResponse(seq: 1, kind: "workspace.created")
        let data = try encoder.encode(event)
        var framed = data
        framed.append(0x0A)

        // Must decode as valid JSON.
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0",
                       "every pushed line must be a valid JSON-RPC 2.0 object so consumers can parse it without a schema")

        // Must end with exactly one newline.
        XCTAssertEqual(framed.last, 0x0A,
                       "NDJSON framing requires each record to end with \\n; missing delimiter causes consumers to buffer forever")
        XCTAssertEqual(framed.filter({ $0 == 0x0A }).count, 1,
                       "exactly one newline per event — multiple newlines would inject empty lines that break strict NDJSON parsers")
    }

    /// The `result` object must carry the four fields the CLI contract promises:
    /// seq, kind, ts, payload.
    func test_singleEvent_resultCarriesRequiredFields() throws {
        let event = makeFakeResponse(seq: 7, kind: "surface.output")
        let data = try encoder.encode(event)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(obj["result"] as? [String: Any])

        XCTAssertNotNil(result["seq"],     "seq is the ordering field; consumers use it to detect gaps and replay")
        XCTAssertNotNil(result["kind"],    "kind lets consumers filter event types without parsing payload")
        XCTAssertNotNil(result["ts"],      "ts is wall-clock for latency measurement")
        XCTAssertNotNil(result["payload"], "payload carries the event-specific data")
    }

    // MARK: - ordering across multiple events

    /// N events emitted in order must produce N independent parseable lines in the
    /// same order. Order matters: the consumer rebuilds state incrementally from seq.
    func test_multipleEvents_produceLinesInEmissionOrder() throws {
        let kinds = ["workspace.created", "surface.created", "surface.output"]
        let lines: [Data] = try kinds.enumerated().map { idx, kind in
            let resp = makeFakeResponse(seq: Int64(idx + 1), kind: kind)
            var d = try encoder.encode(resp)
            d.append(0x0A)
            return d
        }

        // Simulate what the CLI does: collect lines by splitting on 0x0A.
        let combined = lines.reduce(Data(), +)
        let parsedLines = combined.split(separator: 0x0A, omittingEmptySubsequences: true)

        XCTAssertEqual(parsedLines.count, kinds.count,
                       "each event must produce exactly one parseable line; merged or split lines lose ordering information")

        for (idx, lineData) in parsedLines.enumerated() {
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: lineData) as? [String: Any])
            let result = try XCTUnwrap(obj["result"] as? [String: Any])
            XCTAssertEqual(result["kind"] as? String, kinds[idx],
                           "line \(idx) must carry kind='\(kinds[idx])'; wrong order means state machine diverges")
            XCTAssertEqual(result["seq"] as? Double, Double(idx + 1),
                           "seq must be monotonically increasing so gap detection works")
        }
    }

    // MARK: - ack frame

    /// The server sends an ack frame ({subscribed:true}) before live events.
    /// This ack must also be valid NDJSON so the consumer can detect it.
    func test_ackFrame_isValidNDJSON() throws {
        let ack = JSONRPCResponse(id: .string("events.stream"),
                                  result: .object(["subscribed": .bool(true)]))
        let data = try encoder.encode(ack)
        var framed = data
        framed.append(0x0A)

        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["subscribed"] as? Bool, true,
                       "ack must carry subscribed:true so the client knows the stream is live before blocking on reads")
    }

    // MARK: - helpers

    private func makeFakeResponse(seq: Int64, kind: String) -> JSONRPCResponse {
        let payload: [String: JSONValue] = [
            "seq":     .number(Double(seq)),
            "kind":    .string(kind),
            "ts":      .number(1_700_000_000.0),
            "payload": .object(["id": .string("fake-id")])
        ]
        return JSONRPCResponse(id: .string("events.stream"), result: .object(payload))
    }
}
