import XCTest
@testable import DistillCore

/// Wave 3 — deterministic polish: I6.2 floor exemption, I6.3 Python frames,
/// I9.4 hex/SHA volatility, C5/M5 metrics wiring.
final class Wave3DeterministicTests: XCTestCase {

    // I6.2: a burst of error lines must NEVER push a real error out of the keep-set.
    func test_importanceScorerNeverDropsErrorOrFileLineLines() {
        var lines: [String] = []
        for i in 0..<60 { lines.append("debug noise line number \(i) nothing important here") }
        // 30 error/file:line lines scattered through the noise — more than maxKeep.
        for i in 0..<30 { lines.insert("ERROR: widget \(i) failed at src/widget\(i).swift:\(i + 1)", at: i * 2) }
        let text = lines.joined(separator: "\n")
        let result = DistillImportanceScorer.compact(text, maxKeep: 20, keepLast: 4)

        XCTAssertGreaterThan(result.droppedLines, 0, "noise should be elided")
        for i in 0..<30 {
            XCTAssertTrue(
                result.compacted.contains("src/widget\(i).swift:\(i + 1)"),
                "floor line for widget \(i) must survive maxKeep budget (I6.2)")
        }
    }

    func test_importanceScorerKeepsPythonAndJsStackFrames() {
        let text = ([
            "Traceback (most recent call last):",
            "  File \"/app/main.py\", line 42, in handler",
            "    raise ValueError(\"boom\")",
        ] + (0..<60).map { "noise \($0)" }).joined(separator: "\n")
        let result = DistillImportanceScorer.compact(text, maxKeep: 10, keepLast: 2)
        XCTAssertTrue(result.compacted.contains("File \"/app/main.py\", line 42"), "Python frame is a floor line (I6.3)")
    }

    // I6.3: LiteralPreservation pins Python frames → a compression that drops one is rejected.
    func test_literalPreservationPinsPythonFrame() {
        let original = "Traceback:\nFile \"/srv/app.py\", line 128\nValueError: nope"
        let dropped = "Traceback:\nValueError: nope"
        let (output, missing) = LiteralPreservation.guarded(original: original, compressed: dropped)
        XCTAssertEqual(output, original, "must reject toward original")
        XCTAssertNotNil(missing, "a load-bearing literal from the Python frame must be reported missing")
        // The frame and its absolute path are both pinned; either being flagged proves the frame is protected.
        XCTAssertTrue(
            LiteralPreservation.pinnedLiterals(in: original).contains("File \"/srv/app.py\", line 128"),
            "the Python frame itself is pinned")
    }

    // I10.7: order/duplicate-semantic config (INI/env/YAML anchors) must never be
    // key-sorted or crushed — it is not valid JSON, so it falls through unchanged.
    func test_orderSemanticConfigIsNotCrushedOrKeySorted() {
        let router = DistillContentRouter()
        // INI/env with a duplicate key (last-wins semantics) + a comment.
        let ini = "# database\nhost=localhost\nport=5432\nhost=replica\n"
        XCTAssertNil(router.route(ini, options: .losslessOnly), "order/dup-semantic config must not be crushed (I10.7)")
        // YAML anchors are not JSON → the only key-sorting crusher refuses them.
        let yaml = "base: &a\n  k: v\nchild:\n  <<: *a\n"
        XCTAssertNil(JSONCrusher.minify(yaml), "YAML (anchors/order-semantic) is not JSON → not key-sorted")
    }

    func test_jsonKeySortingIsLosslessForValidJSONOnly() {
        // Valid JSON with whitespace: object key order is non-semantic, so sorting +
        // minify is allowed + reversible (whitespace makes it worth crushing).
        let minified = JSONCrusher.minify("{\"b\": 2,  \"a\": 1}")
        XCTAssertNotNil(minified)
        // Round-trips to the same object regardless of key order.
        let obj = try? JSONSerialization.jsonObject(with: Data(minified!.utf8)) as? [String: Int]
        XCTAssertEqual(obj as? [String: Int], ["a": 1, "b": 2])
    }

    // V4: encoder quantization gate — fp16/int8 ship, int4 only with offline-eval sign-off.
    func test_encoderQuantizationGate() {
        XCTAssertTrue(TokenSaverEncoderManifest.isApprovedQuantization("fp16"))
        XCTAssertTrue(TokenSaverEncoderManifest.isApprovedQuantization("int8"))
        XCTAssertTrue(TokenSaverEncoderManifest.isApprovedQuantization("w8a16"))
        XCTAssertFalse(TokenSaverEncoderManifest.isApprovedQuantization("int4"), "int4 blocked without eval")
        XCTAssertTrue(TokenSaverEncoderManifest.isApprovedQuantization("int4", offlineEvalApproved: true))
        XCTAssertFalse(TokenSaverEncoderManifest.isApprovedQuantization("int2"))
    }

    // I10.6: compiler/lint codes are pinned before any lossy crusher runs.
    func test_compilerLintCodesArePinned() {
        let pins = LiteralPreservation.pinnedLiterals(in: "error TS2345: type mismatch; flake8 E501 line too long; rustc E0382 borrow")
        XCTAssertTrue(pins.contains("TS2345"))
        XCTAssertTrue(pins.contains("E501"))
        XCTAssertTrue(pins.contains("E0382"))
        // A compression that drops the code is rejected toward the original. The
        // original is crafted so TS2345 is the ONLY pinned literal (no "error" word,
        // no path/number/file:line), so the reported missing literal is deterministic
        // regardless of Set iteration order.
        let original = "build halted on TS2345 inside that module"
        XCTAssertEqual(LiteralPreservation.pinnedLiterals(in: original), ["TS2345"])
        let (output, missing) = LiteralPreservation.guarded(original: original, compressed: "build halted inside that module")
        XCTAssertEqual(output, original)
        XCTAssertEqual(missing, "TS2345")
    }

    // I9.4: a bare git SHA / hex (no 0x prefix) is NOT volatile — collapsing two blocks
    // that differ only by SHA must be REFUSED by the deterministic diff.
    func test_dedupeTreatsGitShaAsLoadBearingNotVolatile() {
        let stem = (1...6).map { "build step \($0) compiling module and linking objects now" }.joined(separator: "\n")
        let a = "HEAD is 5c38ec7c405ec4b44b94cc5a9bb96e735b38267a\n" + stem
        let b = "HEAD is 3edf6d7de0faa426b09780416fe61009f26ae589\n" + stem
        let text = a + "\n\n" + b
        let result = DistillBlockDeduper.dedupe(text, minBlockChars: 100)
        XCTAssertEqual(result.nearDedupedBlocks, 0, "differing git SHAs are load-bearing, not volatile (I9.4)")
        XCTAssertEqual(result.output, text)
    }

    // C5 / M5: the recorder surfaces BERT-first telemetry + encoder lane counters.
    func test_recorderExposesRouteAndEncoderTelemetry() async {
        let recorder = DistillServiceMetricsRecorder()
        await recorder.recordRoute(.init(lane: .commandOutput, stage: .deterministic, wallClockMilliseconds: 3))
        await recorder.recordRoute(.init(lane: .longText, stage: .encoderBERT, wallClockMilliseconds: 50))
        await recorder.recordRoute(.init(lane: .wireEncode, stage: .llmMLX, wallClockMilliseconds: 1500))
        await recorder.recordEncoderMetrics(.init(invocations: 10, accepts: 7, fallbacks: 3, failures: 0, deadlineTimeouts: 1, disabled: false))

        let m = await recorder.snapshot(activeRequests: 0, maxConcurrentRequests: 4)
        XCTAssertEqual(m.resolvedWithoutLLMRate, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(m.encoderAvgMillis, 50, accuracy: 0.0001)
        XCTAssertEqual(m.llmAvgMillis, 1500, accuracy: 0.0001)
        XCTAssertEqual(m.encoderLaneInvocations, 10)
        XCTAssertEqual(m.encoderLaneAccepts, 7)
        XCTAssertEqual(m.encoderLaneDeadlineTimeouts, 1)

        // JSON exposes the new snake_case keys.
        let json = String(data: try! JSONEncoder().encode(m), encoding: .utf8)!
        XCTAssertTrue(json.contains("resolved_without_llm_rate"))
        XCTAssertTrue(json.contains("encoder_avg_millis"))
    }
}
