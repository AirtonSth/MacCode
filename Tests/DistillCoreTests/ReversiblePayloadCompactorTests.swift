import XCTest
@testable import DistillCore

final class ReversiblePayloadCompactorTests: XCTestCase {
    func test_compactsLargeStringPreservingStructureAndRecoverable() throws {
        var store: [String: String] = [:]
        var counter = 0
        func put(_ s: String) -> String? { counter += 1; let h = "h\(counter)"; store[h] = s; return h }

        let bigOutput = String(repeating: "tool output line with an error at File.swift:42 and value 5012\n", count: 400)
        XCTAssertGreaterThan(bigOutput.count, 16_000)
        let payload = "{\"kind\":\"tool\",\"itemId\":\"abc\",\"state\":\"completed\",\"output\":\(jsonString(bigOutput)),\"seq\":7}"

        let compacted = ReversiblePayloadCompactor.compact(payload, thresholdChars: 16_000, store: put)
        XCTAssertNotEqual(compacted, payload)

        // Replay safety: still valid JSON with the SAME keys; structural fields untouched.
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(compacted.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["kind", "itemId", "state", "output", "seq"])
        XCTAssertEqual(obj["kind"] as? String, "tool")
        XCTAssertEqual(obj["itemId"] as? String, "abc")
        XCTAssertEqual(obj["state"] as? String, "completed")
        XCTAssertEqual(obj["seq"] as? Int, 7)

        let compactedOutput = try XCTUnwrap(obj["output"] as? String)
        XCTAssertLessThan(compactedOutput.count, bigOutput.count, "the large output value is shrunk")
        XCTAssertTrue(compactedOutput.contains("[[rc:"), "carries a recovery handle")

        // The original is byte-recoverable from the stored handle.
        let handle = extractHandle(compactedOutput)
        XCTAssertEqual(store[handle], bigOutput, "original tool output recoverable via the stored handle")
    }

    func test_smallPayloadUnchanged() {
        let payload = #"{"kind":"tool","output":"short"}"#
        XCTAssertEqual(ReversiblePayloadCompactor.compact(payload, thresholdChars: 16_000) { _ in "h" }, payload)
    }

    func test_unparseablePayloadUnchanged() {
        let junk = String(repeating: "x", count: 20_000) // big but not JSON
        XCTAssertEqual(ReversiblePayloadCompactor.compact(junk, thresholdChars: 16_000) { _ in "h" }, junk)
    }

    func test_storeFailureLeavesValueVerbatim() throws {
        let big = String(repeating: "y", count: 20_000)
        let payload = "{\"output\":\(jsonString(big))}"
        let out = ReversiblePayloadCompactor.compact(payload, thresholdChars: 16_000) { _ in nil } // store unavailable
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(obj["output"] as? String, big, "no handle => value left verbatim (N5: never drop without recovery)")
    }

    private func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        var t = String(data: data, encoding: .utf8)!
        t.removeFirst(); t.removeLast() // strip the surrounding [ ]
        return t
    }

    private func extractHandle(_ s: String) -> String {
        guard let start = s.range(of: "[[rc:"),
              let end = s.range(of: "]]", range: start.upperBound..<s.endIndex) else { return "" }
        return String(s[start.upperBound..<end.lowerBound])
    }
}
