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

    func test_classify_detectsHeadroomRouterSubtypes() {
        let searchResults = """
        Sources/App.swift:12:5: func render() -> View
        Tests/AppTests.swift:44:9: XCTAssertEqual(value, expected)
        """
        XCTAssertEqual(router.classify(searchResults), .searchResults)

        let buildOutput = """
        Compile Swift Module RemoteCode
        /tmp/Sources/App.swift:12:8: error: cannot find 'missingValue' in scope
        ** BUILD FAILED **
        """
        XCTAssertEqual(router.classify(buildOutput), .buildOutput)

        let stackTrace = """
        Error: boom
            at render (/tmp/app.js:10:2)
            at render (/tmp/app.js:10:2)
            at render (/tmp/app.js:10:2)
            at render (/tmp/app.js:10:2)
            at main (/tmp/app.js:20:1)
        """
        XCTAssertEqual(router.classify(stackTrace), .stackTrace)

        let testReport = """
        tests/test_a.py::test_one PASSED
        tests/test_b.py::test_two PASSED
        ========================= 2 passed in 0.01s =========================
        """
        XCTAssertEqual(router.classify(testReport), .testReport)

        let sourceCode = """
        import Foundation
        struct Runner {
            func run() -> String { "ok" }
        }
        """
        XCTAssertEqual(router.classify(sourceCode), .sourceCode)

        let html = """
        <!doctype html>
        <html><body><div>ok</div></body></html>
        """
        XCTAssertEqual(router.classify(html), .html)
    }

    func test_classify_fallsBackToProse() {
        XCTAssertEqual(router.classify("This is just an ordinary sentence about nothing."), .prose)
    }

    func test_classify_classifierSeamOnlyAppliesAfterStructuralProbesMiss() {
        let classifier: DistillContentSubtypeClassifier = { _ in
            DistillContentSubtypeDecision(contentType: .testReport, confidence: 0.93)
        }
        XCTAssertEqual(
            router.classify("ordinary residual payload", classifier: classifier),
            .testReport,
            "a confident encoder classifier can subtype residual content"
        )
        XCTAssertEqual(
            router.classify("{\"a\":1}", classifier: classifier),
            .json,
            "structural probes must remain ahead of the classifier"
        )

        let lowConfidence: DistillContentSubtypeClassifier = { _ in
            DistillContentSubtypeDecision(contentType: .testReport, confidence: 0.10)
        }
        XCTAssertEqual(router.classify("ordinary residual payload", classifier: lowConfidence), .prose)
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

    func test_jsonSmartCrusherStatsActivateOnlyForHomogeneousRepeatedLargeArrays() throws {
        let eligible = try smartCrusherFixture()
        let stats = try XCTUnwrap(JSONCrusher.activationStats(eligible))

        XCTAssertGreaterThanOrEqual(stats.itemCount, 5)
        XCTAssertGreaterThanOrEqual(stats.estimatedTokens, 200)
        XCTAssertGreaterThan(stats.lengthVariance, 2.0)
        XCTAssertLessThan(stats.uniquenessRatio, 0.10)
        XCTAssertGreaterThan(stats.schemaSimilarity, 0.80)
        XCTAssertTrue(stats.activatesStatisticalWindow)

        let heterogeneous = try jsonString([
            ["kind": "a", "value": 1],
            ["kind": "b", "other": true],
            ["kind": "c", "payload": "x"],
            ["kind": "d", "nested": ["x": 1]],
            ["kind": "e", "items": [1, 2, 3]]
        ])
        let heterogeneousStats = try XCTUnwrap(JSONCrusher.activationStats(heterogeneous))
        XCTAssertFalse(
            heterogeneousStats.activatesStatisticalWindow,
            "heterogeneous arrays must skip lossy JSON windowing before any row can be dropped"
        )
    }

    func test_jsonCrusherTabularCSVRoundTripsSemanticallyAndSavesAtLeastThirtyPercent() throws {
        let rows: [[String: Any]] = (0..<24).map { index in
            [
                "enabled": index % 2 == 0,
                "id": index,
                "name": "item-\(index)",
                "status": "ready"
            ]
        }
        let input = try jsonString(rows, pretty: true)

        let crushed = try XCTUnwrap(JSONCrusher.tabularCSV(input))
        let expanded = try XCTUnwrap(JSONCrusher.expandTabularCSV(crushed))

        XCTAssertEqual(try canonical(input), try canonical(expanded))
        XCTAssertLessThanOrEqual(
            Double(crushed.count) / Double(input.count),
            0.70,
            "tabular CSV path only activates when it saves at least about 30%"
        )
    }

    func test_jsonCrusherWindowArrayRequiresStoreBackedHandleAndEmbedsDropSentinel() throws {
        let input = try smartCrusherFixture()

        let windowed = try XCTUnwrap(JSONCrusher.windowArray(input, droppedHandle: "[[rc:abc123]]", maxItems: 15))
        XCTAssertTrue(windowed.contains(#""_ccr_dropped""#))
        XCTAssertTrue(windowed.contains("[[rc:abc123]]"))
        XCTAssertTrue(windowed.contains("rows_offloaded"))
        XCTAssertLessThan(windowed.count, input.count)
    }

    func test_jsonCrusherWindowArrayHonorsAnchorsChangePointsAndCap() throws {
        let input = try smartCrusherFixture()

        let windowed = try XCTUnwrap(JSONCrusher.windowArray(input, droppedHandle: "[[rc:abc123]]", maxItems: 15))
        let data = try XCTUnwrap(windowed.data(using: .utf8))
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]])
        let selectedRows = output.filter { $0["kind"] as? String == "event" }
        let shortRows = selectedRows.filter { $0["bucket"] as? String == "short" }
        let longRows = selectedRows.filter { $0["bucket"] as? String == "long" }
        let sentinels = output.compactMap { $0["_ccr_dropped"] as? String }

        XCTAssertEqual(selectedRows.count, 15, "maxItems caps kept rows even after change-point selection")
        XCTAssertEqual(shortRows.count, 9, "30% head anchor keeps the first nine rows from a 30-row array")
        XCTAssertEqual(longRows.count, 6, "15% tail anchor plus the length change point keeps six long rows")
        XCTAssertEqual(sentinels.count, 2)
        XCTAssertTrue(sentinels.contains { $0.contains("offset=9") })
        XCTAssertTrue(sentinels.contains { $0.contains("offset=16") })
    }

    func test_jsonCrusherWindowArrayReturnsNilWhenStatisticalGateFails() throws {
        let rows: [[String: Any]] = (0..<24).map { index in
            [
                "id": index,
                "name": "unique-\(index)",
                "payload": String(repeating: "\(index)", count: 12)
            ]
        }
        let input = try jsonString(rows, pretty: true)

        XCTAssertFalse(try XCTUnwrap(JSONCrusher.activationStats(input)).activatesStatisticalWindow)
        XCTAssertNil(
            JSONCrusher.windowArray(input, droppedHandle: "abc123"),
            "row dropping must stay off for unique or heterogeneous arrays even when a handle is available"
        )
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

    func test_routerFallsThroughForSourceCodeUntilSafeCodeCrusherExists() {
        let sourceCode = """
        import Foundation
        struct Runner {
            func run() -> String {
                return "ok"
            }
        }
        """

        XCTAssertEqual(router.classify(sourceCode), .sourceCode)
        XCTAssertNil(
            router.route(sourceCode),
            "source code must not be rewritten by generic lossy compression before a code-aware, store-backed crusher exists"
        )
    }

    func test_routerRoutesMixedSectionsIndependently() throws {
        let prose = "Build metadata below is prose and must remain byte-exact."
        let json = """
        {
          "status": "ok",
          "items": [
            { "id": 1, "name": "alpha", "enabled": true },
            { "id": 2, "name": "beta", "enabled": false },
            { "id": 3, "name": "gamma", "enabled": true }
          ],
          "meta": { "source": "test", "count": 3 }
        }
        """
        let input = "\(prose)\n\n\(json)"

        let result = try XCTUnwrap(router.route(input))
        XCTAssertEqual(result.contentType, .mixed)
        XCTAssertTrue(result.lossless, "mixed routing is lossless when every routed section is lossless")

        let sections = result.output.components(separatedBy: "\n\n")
        XCTAssertEqual(sections.first, prose, "unrouted prose section stays byte-exact")
        XCTAssertEqual(try canonical(json), try canonical(try XCTUnwrap(sections.last)))
        XCTAssertLessThan(result.output.count, input.count)
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

    func test_stackTraceCrusher_elidesOnlyExactDuplicateFramesWithHandle() throws {
        let trace = """
        Error: boom
            at render (/tmp/app.js:10:2)
            at render (/tmp/app.js:10:2)
            at render (/tmp/app.js:10:2)
            at render (/tmp/app.js:10:2)
        Caused by: root cause
            at main (/tmp/app.js:20:1)
        """

        XCTAssertNil(router.route(trace, options: .init(allowElementDropping: true)),
                     "lossy stack-trace routes require a reversible handle")
        let result = try XCTUnwrap(router.route(
            trace,
            options: .init(allowElementDropping: true, reversibleHandle: "abc123")
        ))
        XCTAssertEqual(result.contentType, .stackTrace)
        XCTAssertFalse(result.lossless)
        XCTAssertTrue(result.output.contains("identical stack frames elided [[rc:abc123]]"))
        XCTAssertTrue(result.output.contains("Caused by: root cause"),
                      "causal boundaries must stay verbatim")
    }

    func test_testReportCrusher_foldsPassingPytestLinesWithSummaryCrossCheck() throws {
        let passed = (0..<12)
            .map { "tests/test_pass_\($0).py::test_case_\($0) PASSED" }
            .joined(separator: "\n")
        let report = """
        \(passed)
        tests/test_c.py::test_three FAILED
        ========================= 1 failed, 12 passed in 0.03s =========================
        """

        let result = try XCTUnwrap(router.route(
            report,
            options: .init(allowElementDropping: true, reversibleHandle: "def456")
        ))
        XCTAssertEqual(result.contentType, .testReport)
        XCTAssertTrue(result.output.contains("12 passing-test lines elided [[rc:def456]]"))
        XCTAssertTrue(result.output.contains("tests/test_c.py::test_three FAILED"),
                      "failing test lines must remain verbatim")
    }

    func test_testReportCrusher_rejectsSummaryMismatch() {
        let report = """
        tests/test_a.py::test_one PASSED
        ========================= 2 passed in 0.03s =========================
        """

        XCTAssertNil(router.route(report, options: .init(allowElementDropping: true, reversibleHandle: "def456")))
    }

    func test_prosePruningLane_isDefaultOffAndRequiresHandle() throws {
        let input = prosePruningFixture()

        XCTAssertNil(router.route(input), "I12 is default-off")
        XCTAssertNil(router.route(input, options: .init(allowElementDropping: true, allowLossyProsePruning: true)),
                     "lossy prose pruning requires a reversible handle")

        let result = try XCTUnwrap(router.route(
            input,
            options: .init(
                allowElementDropping: true,
                reversibleHandle: "feedbeef",
                allowLossyProsePruning: true
            )
        ))
        XCTAssertEqual(result.contentType, .prose)
        XCTAssertFalse(result.lossless)
        XCTAssertTrue(result.output.contains("[[rc:feedbeef]]"))
        XCTAssertTrue(result.output.contains("retrieve before negative claims"),
                      "I12 markers must tell agents not to make negative evidence claims from pruned text")
        XCTAssertTrue(result.output.contains("MUST keep the rollback instruction"))
        XCTAssertLessThan(result.output.count, input.count)
    }

    func test_prosePruningLane_keepsQueryRelevantMiddleLine() throws {
        let input = prosePruningQueryFixture()

        let result = try XCTUnwrap(router.route(
            input,
            options: .init(
                allowElementDropping: true,
                reversibleHandle: "feedbeef",
                allowLossyProsePruning: true,
                query: "billing retry budget"
            )
        ))

        XCTAssertTrue(result.output.contains("Billing retry budget changed from three attempts to five attempts."),
                      "I12 query-aware pruning must keep the middle sentence that answers the request")
        XCTAssertLessThan(result.output.count, input.count)
    }

    func test_prosePruningLane_rejectsWhenPinnedLinesExceedBudget() {
        let input = (0..<40)
            .map { "ERROR: critical pinned diagnostic line \($0) must remain verbatim for the incident report and cannot be elided safely." }
            .joined(separator: "\n")

        XCTAssertNil(router.route(
            input,
            options: .init(
                allowElementDropping: true,
                reversibleHandle: "feedbeef",
                allowLossyProsePruning: true
            )
        ), "I12 must fail open instead of dropping salient error lines to satisfy a pruning budget")
    }

    func test_prosePruningLane_rejectsCodeLikeContent() {
        let code = (0..<80)
            .map { "    func render\($0)() { print(\"line \($0)\") }" }
            .joined(separator: "\n")

        XCTAssertNil(router.route(
            code,
            options: .init(
                allowElementDropping: true,
                reversibleHandle: "feedbeef",
                allowLossyProsePruning: true
            )
        ))
    }

    func test_router_enforcesMinGainRatio() {
        // A JSON payload whose minify saves < 10% must be rejected (not worth it).
        let barelyCompressible = "{\"a\":1, \"b\":2}" // one space; <10% gain
        XCTAssertNil(router.route(barelyCompressible, options: .init(minGainRatio: 0.10)))
    }

    func test_adaptiveMinGainRatioScalesWithContextPressure() {
        XCTAssertEqual(DistillRouterOptions.adaptiveMinGainRatio(contextPressure: 0), 0.15, accuracy: 0.0001)
        XCTAssertEqual(DistillRouterOptions.adaptiveMinGainRatio(contextPressure: 0.5), 0.25, accuracy: 0.0001)
        XCTAssertEqual(DistillRouterOptions.adaptiveMinGainRatio(contextPressure: 1), 0.35, accuracy: 0.0001)
        XCTAssertEqual(DistillRouterOptions.adaptiveMinGainRatio(contextPressure: 2), 0.35, accuracy: 0.0001)
    }

    func test_routerAppliesAdaptiveGainToLosslessRoutes() {
        let mildlyCompressibleJSON = #"{"a":1, "b":2, "c":3, "d":4, "e":5}"#

        XCTAssertNotNil(
            router.route(mildlyCompressibleJSON, options: .init(minGainRatio: 0.10)),
            "baseline 10% gate accepts this lossless minify"
        )
        XCTAssertNil(
            router.route(mildlyCompressibleJSON, options: .init(minGainRatio: 0.10, contextPressure: 1)),
            "under high pressure a small lossless win should not spend the route budget"
        )
    }

    func test_pressureDerivesFromInputVsOutputBudget() throws {
        XCTAssertNil(DistillRouterOptions.pressure(inputCharacters: 1_000, outputBudgetCharacters: 4_000))
        let mediumPressure = try XCTUnwrap(DistillRouterOptions.pressure(inputCharacters: 8_000, outputBudgetCharacters: 4_000))
        let highPressure = try XCTUnwrap(DistillRouterOptions.pressure(inputCharacters: 40_000, outputBudgetCharacters: 4_000))
        XCTAssertEqual(
            mediumPressure,
            1.0 / 3.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            highPressure,
            1.0,
            accuracy: 0.0001
        )
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

    func test_localRuntime_preservesProseLongTextSourceVerbatim() async throws {
        // WHY: prose the lossless router cannot encode must fail open without
        // dropping a late instruction or obeying the compression-size budget.
        let tail = "UNIQUE FINAL INSTRUCTION: preserve the deployment gate."
        let prose = ((0..<20).map { "narrative line number \($0) describing things" } + [tail])
            .joined(separator: "\n")
        let request = DistillRequest(mode: .longText, input: prose, maxOutputCharacters: 32)
        let output = try await LocalDistillRuntime().distill(request)

        XCTAssertEqual(output, prose)
        XCTAssertTrue(output.hasSuffix(tail))
        XCTAssertGreaterThan(output.count, request.maxOutputCharacters)
    }

    // MARK: - Helpers

    /// Canonical JSON form (parsed then re-serialized with sorted keys) — two
    /// strings are *semantically* equal iff their canonical forms match.
    private func canonical(_ string: String) throws -> Data {
        let data = try XCTUnwrap(string.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func jsonString(_ value: Any, pretty: Bool = false) throws -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        let data = try JSONSerialization.data(withJSONObject: value, options: options)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func smartCrusherFixture() throws -> String {
        let shortPayload = String(repeating: "a", count: 20)
        let longPayload = String(repeating: "b", count: 140)
        let rows: [[String: Any]] = (0..<30).map { index in
            if index < 15 {
                return ["kind": "event", "bucket": "short", "payload": shortPayload]
            }
            return ["kind": "event", "bucket": "long", "payload": longPayload]
        }
        return try jsonString(rows, pretty: true)
    }

    private func prosePruningFixture() -> String {
        var lines: [String] = [
            "The operator is investigating a long incident report for the staging environment.",
            "The goal is to keep enough context for a model to continue the work.",
            "Most paragraphs are repetitive background that can be recovered if needed."
        ]
        for index in 0..<34 {
            lines.append("Background paragraph \(index) repeats status context about deploy windows, owner notes, and low-signal narration for later retrieval.")
        }
        lines.append("MUST keep the rollback instruction because it controls the safe next action.")
        for index in 34..<68 {
            lines.append("Background paragraph \(index) repeats status context about deploy windows, owner notes, and low-signal narration for later retrieval.")
        }
        lines.append("The operator should continue only after checking the saved original when detail is needed.")
        return lines.joined(separator: "\n")
    }

    private func prosePruningQueryFixture() -> String {
        var lines: [String] = [
            "The report covers routine operations across multiple services.",
            "The first section summarizes background and status.",
            "The operator can recover the full original through the handle."
        ]
        for index in 0..<30 {
            lines.append("General paragraph \(index) repeats low-signal deployment commentary, owners, meeting notes, and routine context.")
        }
        lines.append("Billing retry budget changed from three attempts to five attempts.")
        for index in 30..<70 {
            lines.append("General paragraph \(index) repeats low-signal deployment commentary, owners, meeting notes, and routine context.")
        }
        lines.append("The ending restates that the full source remains retrievable.")
        return lines.joined(separator: "\n")
    }
}
