import XCTest
@testable import DistillCore

final class ManagedDistillCLITests: XCTestCase {
    private let state = ManagedDistillCLI.State(baseURL: "http://127.0.0.1:9", authToken: "t")

    func test_compress_success_emitsOutputAndHandleMarker() async {
        let resp = DistillResponse(requestID: UUID(), output: "PASS", inputCharacters: 100, inputTokens: 25, outputTokens: 1, originalHandle: "abc123")
        let data = try! JSONEncoder().encode(resp)
        let cli = ManagedDistillCLI(arguments: ["Return PASS or FAIL only."], stdin: Data("build passed\n0 failures".utf8), state: state) { _ in (data, 200) }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        let s = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("PASS"))
        XCTAssertTrue(s.contains("[[rc:abc123]]"), "handle marker embedded so the agent can retrieve the original")
    }

    func test_compress_noState_failsOpenToRawStdin() async {
        let raw = Data("the exact tool output that must NOT be lost".utf8)
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: nil) { _ in nil }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw, "no state => echo raw stdin verbatim, never lose piped data")
    }

    func test_compress_transportFailure_failsOpen() async {
        let raw = Data("tool output".utf8)
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in nil }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw)
    }

    func test_compress_non200_failsOpen() async {
        let raw = Data("tool output".utf8)
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in (Data("{}".utf8), 500) }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw)
    }

    func test_compress_emptyOutput_failsOpen() async {
        let resp = DistillResponse(requestID: UUID(), output: "   ", inputCharacters: 5)
        let data = try! JSONEncoder().encode(resp)
        let raw = Data("tool output".utf8)
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in (data, 200) }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw)
    }

    func test_emptyStdin_returnsEmptyExitZero() async {
        let cli = ManagedDistillCLI(arguments: [], stdin: Data(), state: state) { _ in (Data(), 200) }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.isEmpty)
    }

    func test_retrieve_success_returnsOriginal() async {
        let json = #"{"handle":"h","found":true,"original":"the original bytes"}"#
        let cli = ManagedDistillCLI(arguments: ["retrieve", "h"], stdin: Data(), state: state) { request in
            XCTAssertTrue(request.url?.path.contains("/v1/retrieve/h") ?? false)
            return (Data(json.utf8), 200)
        }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "the original bytes")
    }

    func test_retrieve_miss_exitsNonZero() async {
        let json = #"{"handle":"h","found":false,"original":null}"#
        let cli = ManagedDistillCLI(arguments: ["retrieve", "h"], stdin: Data(), state: state) { _ in (Data(json.utf8), 404) }
        let (_, code) = await cli.run()
        XCTAssertEqual(code, 1, "retrieve has no stdin to preserve => loud non-zero on miss")
    }
}
