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

    func test_compress_sendsPerRequestReversibleStoreMinBytes() async {
        var captured: DistillRequest?
        let resp = DistillResponse(requestID: UUID(), output: "x", inputCharacters: 2_000, originalHandle: "h")
        let data = try! JSONEncoder().encode(resp)
        let cli = ManagedDistillCLI(
            arguments: [],
            stdin: Data(String(repeating: "line of command output\n", count: 50).utf8),
            state: state,
            reversibleStoreMinBytes: 256
        ) { request in
            captured = try? JSONDecoder().decode(DistillRequest.self, from: request.httpBody ?? Data())
            return (data, 200)
        }
        _ = await cli.run()
        XCTAssertEqual(captured?.reversibleStoreMinBytes, 256,
                       "the wrap path lowers the store floor so compressed output always carries a recovery handle")
    }

    func test_distillRequest_reversibleStoreMinBytes_roundTripsAndOmissionDecodesNil() throws {
        // Round-trip the field itself (encoder + tolerant decoder).
        let encoded = try JSONEncoder().encode(DistillRequest(mode: .commandOutput, input: "x", reversibleStoreMinBytes: 2048))
        XCTAssertEqual(try JSONDecoder().decode(DistillRequest.self, from: encoded).reversibleStoreMinBytes, 2048)
        // A wire body (as the Claude hook / wrappers hand-build) that omits the key decodes to
        // nil — version-skew safe. `priority` is an Int on the wire, matching the hook's payload.
        let omitted = #"{"mode":"commandOutput","priority":1,"input":"x","maxOutputCharacters":4000}"#
        XCTAssertNil(try JSONDecoder().decode(DistillRequest.self, from: Data(omitted.utf8)).reversibleStoreMinBytes)
    }

    // MARK: - QA-mac:54 saturation -> 429 -> CLI fail-open chain

    func test_distillErrorHttpMappingSeam() {
        // The wire contract: a bounded-worker overflow is 429 queue_full; the other
        // errors keep their distinct codes so the CLI fail-opens only on the right ones.
        XCTAssertEqual(DistillError.queueFull.httpMapping.status, 429)
        XCTAssertEqual(DistillError.queueFull.httpMapping.code, "queue_full")
        XCTAssertEqual(DistillError.emptyInput.httpMapping.status, 400)
        XCTAssertEqual(DistillError.invalidOutput.httpMapping.status, 502)
    }

    func test_saturationQueueFullChainsToCLIFailOpen() async {
        // End-to-end saturation contract across the 3 already-tested links:
        //   (1) a saturated DistillScheduler throws DistillError.queueFull
        //   (2) that maps to HTTP 429 queue_full (httpMapping seam, routed through
        //       DistillService)
        //   (3) the managed CLI, seeing a non-200, FAILS OPEN -- echoes stdin
        //       verbatim, exit 0 -- so distill saturation never blocks an agent turn.
        let saturation = DistillError.queueFull
        let mapping = saturation.httpMapping
        XCTAssertEqual(mapping.status, 429, "scheduler saturation must surface as 429 over the wire")

        let raw = Data("the agent tool output that must survive saturation".utf8)
        // Transport stands in for the saturated service returning exactly the mapped status.
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in
            (Data(#"{"error":"\#(mapping.code)","message":"bounded distill worker is full"}"#.utf8), mapping.status)
        }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0, "a saturated (429) distill service must fail-open, exit 0 -- never block the agent")
        XCTAssertEqual(out, raw, "fail-open must echo the agent's tool output verbatim under saturation, losing nothing")
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

    func test_statsSubcommandFetchesStatsWithoutCompressingPipedInput() async {
        let raw = Data("transcript or stats input must not become a compression prompt".utf8)
        let snapshot = DistillStatsSnapshot(
            totalSavedTokens: 150,
            totalRuns: 3,
            providers: [DistillStatsProviderSavings(provider: "claude", savedTokens: 150, inputTokens: 500, outputTokens: 350, runs: 3)],
            modes: [DistillStatsModeSavings(provider: "claude", mode: "command-output", savedTokens: 150, runs: 3)]
        )
        let encoded = try! JSONEncoder().encode(snapshot)
        let cli = ManagedDistillCLI(arguments: ["stats"], stdin: raw, state: state) { request in
            XCTAssertEqual(request.url?.path, "/v1/stats")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
            return (encoded, 200)
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("saved_tokens=150"))
        XCTAssertTrue(text.contains("provider claude: saved=150"))
        XCTAssertNotEqual(out, raw, "stats must not fail-open as command-output compression")
    }

    func test_dslLearnThreadConsumesTranscriptWithoutCompression() async {
        let raw = Data("S start\nD patch\nP pass\n".utf8)
        let cli = ManagedDistillCLI(arguments: ["dsl", "learn-thread", "--stdin"], stdin: raw, state: state) { _ in
            XCTFail("dsl learn-thread must not call /v1/distill")
            return nil
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("accepted \(raw.count) bytes"))
    }

    func test_reservedRankAndWrapSubcommandsDoNotCompressPipedInput() async {
        let raw = Data("rank or wrap input must not become a compression prompt".utf8)
        for subcommand in ["rank", "wrap"] {
            let cli = ManagedDistillCLI(arguments: [subcommand], stdin: raw, state: state) { _ in
                XCTFail("reserved \(subcommand) must not call /v1/distill")
                return nil
            }

            let (out, code) = await cli.run()

            XCTAssertEqual(code, 1)
            XCTAssertNotEqual(out, raw)
            XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("reserved subcommand"))
        }
    }

    // MARK: - stdin cap (WHY: oversized stdin must not OOM the CLI)

    func test_exceedsStdinCap_pureSeam_rejectsAboveCap() {
        // Inputs above the cap must be flagged so the reject path fires before any
        // String/JSONEncoder allocation. Business rule: cap + 1 byte is over limit.
        XCTAssertTrue(
            ManagedDistillCLI.exceedsStdinCap(byteCount: ManagedDistillCLI.stdinCapBytes + 1, cap: ManagedDistillCLI.stdinCapBytes),
            "one byte over cap must be rejected"
        )
    }

    func test_exceedsStdinCap_pureSeam_acceptsAtCap() {
        // Exactly at the cap is allowed; the cap is an exclusive upper bound.
        XCTAssertFalse(
            ManagedDistillCLI.exceedsStdinCap(byteCount: ManagedDistillCLI.stdinCapBytes, cap: ManagedDistillCLI.stdinCapBytes),
            "exactly at cap must be accepted"
        )
    }

    func test_exceedsStdinCap_pureSeam_acceptsUnderCap() {
        XCTAssertFalse(
            ManagedDistillCLI.exceedsStdinCap(byteCount: 1_024, cap: ManagedDistillCLI.stdinCapBytes),
            "small input well under cap must be accepted"
        )
    }

    func test_compress_overCapStdin_rejectsNonZero() async {
        // An oversized stdin must exit non-zero (not fail-open) so the caller gets an
        // actionable error rather than silently discarded data or an OOM crash.
        let overCap = Data(repeating: UInt8(ascii: "x"), count: ManagedDistillCLI.stdinCapBytes + 1)
        let cli = ManagedDistillCLI(arguments: ["summarize"], stdin: overCap, state: state) { _ in nil }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 1, "over-cap stdin must exit non-zero")
        let msg = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(msg.contains("cap"), "error message must mention the cap so the caller knows what to fix")
    }

    func test_compress_atCapStdin_proceedsNormally_failsOpenOnTransportFailure() async {
        // A stdin exactly at the cap must not be rejected; normal fail-open applies.
        let atCap = Data(repeating: UInt8(ascii: "x"), count: ManagedDistillCLI.stdinCapBytes)
        let cli = ManagedDistillCLI(arguments: [], stdin: atCap, state: state) { _ in nil }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0, "at-cap stdin is accepted; transport failure => fail-open, exit 0")
        XCTAssertEqual(out, atCap, "fail-open echoes stdin verbatim")
    }
}
