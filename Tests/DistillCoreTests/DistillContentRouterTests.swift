import XCTest
@testable import DistillCore

final class DistillContentRouterTests: XCTestCase {
    private let router = DistillContentRouter()

    // MARK: - Classification

    func test_classify_detectsJSON() {
        XCTAssertEqual(router.classify("{\n  \"a\": 1,\n  \"b\": [1, 2, 3]\n}"), .json)
        XCTAssertEqual(router.classify("  [ {\"x\": true} ] "), .json)
    }

    func test_classify_detectsDiff() {
        let diff = """
        diff --git a/x.swift b/x.swift
        @@ -1,3 +1,3 @@
        -old
        +new
        """
        XCTAssertEqual(router.classify(diff), .diff)
    }

    func test_classify_detectsLog() {
        let log = """
        2026-06-08 INFO starting
        2026-06-08 INFO connecting
        2026-06-08 ERROR boom
        2026-06-08 INFO retry
        """
        XCTAssertEqual(router.classify(log), .log)
    }

    func test_classify_fallsBackToProse() {
        XCTAssertEqual(router.classify("This is just an ordinary sentence about nothing."), .prose)
    }

    // MARK: - JSONCrusher (lossless, semantic deep-equal)

    func test_jsonCrusher_minifiesAndIsSemanticallyEqual() throws {
        let pretty = """
        {
          "name": "remote-code",
          "version": 2,
          "tags": ["a", "b", "c"],
          "nested": { "deep": { "value": 42, "flag": false } }
        }
        """
        let crushed = try XCTUnwrap(JSONCrusher.minify(pretty))
        XCTAssertLessThan(crushed.count, pretty.count, "minified must be smaller")
        XCTAssertFalse(crushed.contains("\n"), "minified JSON has no newlines")
        // Lossless: re-parsing both yields the identical canonical form.
        XCTAssertEqual(try canonical(pretty), try canonical(crushed), "minify must be information-preserving")
    }

    func test_jsonCrusher_returnsNilForNonJSON() {
        XCTAssertNil(JSONCrusher.minify("not json at all"))
        XCTAssertNil(JSONCrusher.minify("\"just a string\""), "top-level fragment is not crushed")
    }

    func test_jsonCrusher_returnsNilWhenAlreadyMinimal() {
        // Already-compact JSON yields no further reduction.
        XCTAssertNil(JSONCrusher.minify("{\"a\":1}"))
    }

    // MARK: - LogCollapser (reversible run-length)

    func test_logCollapser_roundTripsExactly() throws {
        let log = """
        start
        retrying
        retrying
        retrying
        retrying
        done
        """
        let collapsed = try XCTUnwrap(LogCollapser.collapse(log))
        XCTAssertLessThan(collapsed.count, log.count)
        XCTAssertEqual(LogCollapser.expand(collapsed), log, "expand must exactly invert collapse")
    }

    func test_logCollapser_returnsNilWhenNoRuns() {
        XCTAssertNil(LogCollapser.collapse("a\nb\nc\nd"))
    }

    // MARK: - DiffCrusher (element-dropping; only via allowElementDropping)

    func test_diffCrusher_keepsChangesDropsContext() throws {
        var lines = ["diff --git a/f b/f", "@@ -1,20 +1,20 @@"]
        for i in 0..<10 { lines.append(" context line \(i)") }
        lines.append("-removed")
        lines.append("+added")
        for i in 0..<10 { lines.append(" tail context \(i)") }
        let diff = lines.joined(separator: "\n")

        let windowed = try XCTUnwrap(DiffCrusher.window(diff, context: 2))
        XCTAssertTrue(windowed.contains("-removed"), "changed lines preserved")
        XCTAssertTrue(windowed.contains("+added"), "changed lines preserved")
        XCTAssertTrue(windowed.contains("unchanged lines"), "context collapsed to a marker")
        XCTAssertLessThan(windowed.count, diff.count)
    }

    // MARK: - Router policy

    func test_router_routesJSONLosslessly() throws {
        let pretty = "{\n  \"k\": [1, 2, 3, 4, 5, 6, 7, 8],\n  \"other\": \"value here\"\n}"
        let result = try XCTUnwrap(router.route(pretty))
        XCTAssertEqual(result.contentType, .json)
        XCTAssertTrue(result.lossless)
        XCTAssertEqual(try canonical(pretty), try canonical(result.output))
    }

    func test_router_returnsNilForProse() {
        XCTAssertNil(router.route("A perfectly normal paragraph of prose with no structure to exploit."))
    }

    func test_router_doesNotDropDiffContextUnlessAllowed() throws {
        var lines = ["diff --git a/f b/f", "@@ -1,20 +1,20 @@"]
        for i in 0..<12 { lines.append(" context \(i)") }
        lines.append("+added")
        for i in 0..<12 { lines.append(" tail \(i)") }
        let diff = lines.joined(separator: "\n")

        XCTAssertNil(router.route(diff, options: .losslessOnly), "diff windowing is off by default")

        let lossy = try XCTUnwrap(router.route(diff, options: .init(allowElementDropping: true)))
        XCTAssertEqual(lossy.contentType, .diff)
        XCTAssertFalse(lossy.lossless, "diff windowing drops context => needs a handle")
    }

    func test_router_enforcesMinGainRatio() {
        // A JSON payload whose minify saves < 10% must be rejected (not worth it).
        let barelyCompressible = "{\"a\":1, \"b\":2}" // one space; <10% gain
        XCTAssertNil(router.route(barelyCompressible, options: .init(minGainRatio: 0.10)))
    }

    // MARK: - Runtime wiring (LocalDistillRuntime, no model)

    func test_localRuntime_routesLongTextJSON_insteadOfSummarizing() async throws {
        let pretty = """
        {
          "status": "ok",
          "items": [ {"id": 1}, {"id": 2}, {"id": 3} ],
          "meta": { "count": 3, "verbose": true }
        }
        """
        let request = DistillRequest(mode: .longText, input: pretty)
        let output = try await LocalDistillRuntime().distill(request)
        XCTAssertFalse(output.hasPrefix("S "), "structured input must be routed, not line-prefixed summarized")
        XCTAssertEqual(try canonical(pretty), try canonical(output), "routed output is the lossless minify")
    }

    func test_localRuntime_leavesProseLongTextToFallback() async throws {
        let prose = (0..<20).map { "narrative line number \($0) describing things" }.joined(separator: "\n")
        let request = DistillRequest(mode: .longText, input: prose)
        let output = try await LocalDistillRuntime().distill(request)
        XCTAssertTrue(output.contains("S "), "prose falls through to the heuristic summary path")
    }

    // MARK: - Helpers

    /// Canonical JSON form (parsed then re-serialized with sorted keys) — two
    /// strings are *semantically* equal iff their canonical forms match.
    private func canonical(_ string: String) throws -> Data {
        let data = try XCTUnwrap(string.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
