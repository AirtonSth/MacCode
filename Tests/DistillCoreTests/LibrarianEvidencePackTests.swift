import XCTest
@testable import DistillCore

final class LibrarianEvidencePackTests: XCTestCase {
    func test_shortSourceIsByteIdenticalAndHasNoPackMarkers() {
        let source = "status: ok\nUnicode 🙂 remains exact\n"

        let result = LibrarianEvidencePack(budgetBytes: 6_000).pack(
            source: source,
            question: "status"
        )

        XCTAssertEqual(result.strategy, .unchanged)
        XCTAssertEqual(Array(result.text.utf8), Array(source.utf8))
        XCTAssertFalse(result.text.contains("[bytes:"), "a source that fits must not gain pack metadata")
        XCTAssertEqual(result.headerByteCount, 0)
        XCTAssertTrue(result.verbatimSegmentsAreValid(in: source))
    }

    func test_sourceLineSplitPreservesNewlinesAndRawUTF8Offsets() {
        let source = "α\r\nβ🙂\nlast"

        let lines = LibrarianEvidencePack.sourceLines(in: source)

        XCTAssertEqual(lines.map(\.text), ["α\r\n", "β🙂\n", "last"])
        XCTAssertEqual(lines.first?.sourceByteRange.lowerBound, 0)
        XCTAssertEqual(lines.last?.sourceByteRange.upperBound, source.utf8.count)
        XCTAssertEqual(
            lines.dropLast().map(\.sourceByteRange.upperBound),
            lines.dropFirst().map(\.sourceByteRange.lowerBound),
            "line byte ranges must be contiguous even when Unicode precedes LF"
        )
        XCTAssertEqual(lines.map(\.text).joined(), source)
        for line in lines {
            let bytes = Array(source.utf8)[line.sourceByteRange]
            XCTAssertTrue(bytes.elementsEqual(line.text.utf8))
        }
    }

    func test_rankedPackFindsExactEvidenceAfterSixThousandBytePrefix() {
        var lines = (0..<520).map { "routine-output-\($0)-nothing-actionable-here" }
        lines[410] = "ROTATION_SECRET_9f2c must be revoked immediately"
        let source = lines.joined(separator: "\n")
        let baseline = String(decoding: Array(source.utf8.prefix(6_000)), as: UTF8.self)
        XCTAssertFalse(baseline.contains("ROTATION_SECRET_9f2c"))

        let result = LibrarianEvidencePack(budgetBytes: 6_000).pack(
            source: source,
            question: "ROTATION_SECRET_9f2c"
        )

        XCTAssertEqual(result.strategy, .rankedEvidence)
        XCTAssertLessThanOrEqual(result.renderedByteCount, 6_000)
        XCTAssertLessThan(result.renderedByteCount, source.utf8.count)
        XCTAssertTrue(result.hasEvidenceBeyondPrefixCutoff)
        XCTAssertTrue(result.containsExactSpan("ROTATION_SECRET_9f2c", in: source))
        XCTAssertTrue(result.verbatimSegmentsAreValid(in: source))
    }

    func test_targetBundleIncludesOneVerbatimLineBeforeAndAfter() {
        var lines = (0..<180).map { "ordinary row \($0)" }
        lines[90] = "context immediately before"
        lines[91] = "UNIQUE_TARGET evidence"
        lines[92] = "context immediately after"
        let source = lines.joined(separator: "\n")

        let result = LibrarianEvidencePack(budgetBytes: 500).pack(
            source: source,
            question: "UNIQUE_TARGET"
        )

        XCTAssertEqual(result.strategy, .rankedEvidence)
        XCTAssertTrue(result.containsExactSpan("context immediately before", in: source))
        XCTAssertTrue(result.containsExactSpan("UNIQUE_TARGET evidence", in: source))
        XCTAssertTrue(result.containsExactSpan("context immediately after", in: source))
    }

    func test_scoreSelectionRendersCoalescedSegmentsInOriginalOrder() {
        var lines = (0..<220).map { "noise row \($0)" }
        lines[70] = "ALPHA_TARGET first decisive fact"
        lines[160] = "OMEGA_TARGET second decisive fact"
        let source = lines.joined(separator: "\n")

        let result = LibrarianEvidencePack(budgetBytes: 520).pack(
            source: source,
            question: "OMEGA_TARGET ALPHA_TARGET"
        )

        XCTAssertEqual(result.strategy, .rankedEvidence)
        XCTAssertEqual(result.segments.map(\.sourceByteRange.lowerBound), result.segments.map(\.sourceByteRange.lowerBound).sorted())
        XCTAssertTrue(zip(result.segments, result.segments.dropFirst()).allSatisfy {
            $0.sourceByteRange.upperBound < $1.sourceByteRange.lowerBound
        }, "adjacent selected lines should be coalesced into one source segment")
        let alpha = try! XCTUnwrap(result.text.range(of: "ALPHA_TARGET"))
        let omega = try! XCTUnwrap(result.text.range(of: "OMEGA_TARGET"))
        XCTAssertLessThan(alpha.lowerBound, omega.lowerBound, "ranking chooses; source offsets determine render order")
    }

    func test_exactUnicodeSpanRequiresMatchingOriginalAndDisplayedByteRange() {
        var lines = (0..<140).map { "registro \($0) sem novidade" }
        lines[100] = "falha crítica 🙂 código=ÁRVORE_42"
        let source = lines.joined(separator: "\n")
        let result = LibrarianEvidencePack(budgetBytes: 480).pack(
            source: source,
            question: "ÁRVORE_42"
        )
        let range = byteRange(of: "crítica 🙂 código=ÁRVORE_42", in: source)

        XCTAssertEqual(result.strategy, .rankedEvidence)
        XCTAssertTrue(result.containsVerbatimSpan(
            sourceByteRange: range,
            exact: "crítica 🙂 código=ÁRVORE_42",
            in: source
        ))
        XCTAssertFalse(result.containsVerbatimSpan(
            sourceByteRange: range,
            exact: "critica 🙂 código=ÁRVORE_42",
            in: source
        ))
        XCTAssertTrue(result.containsExactSpan("🙂 código=ÁRVORE_42", in: source))
    }

    func test_rangeHeaderCanNeverSatisfyAnEvidenceSpan() {
        var lines = (0..<120).map { "routine row \($0)" }
        lines[60] = "bytes"
        let source = lines.joined(separator: "\n")

        let result = LibrarianEvidencePack(budgetBytes: 180).pack(source: source, question: "")

        XCTAssertEqual(result.strategy, .rankedEvidence)
        XCTAssertTrue(result.text.contains("bytes"), "the compact byte-range header itself contains this word")
        XCTAssertFalse(result.containsExactSpan("bytes", in: source), "headers are not source evidence")
        XCTAssertFalse(result.containsVerbatimSpan(
            sourceByteRange: byteRange(of: "bytes", in: source),
            exact: "bytes",
            in: source
        ))
    }

    func test_mandatoryFloorOverflowReturnsExplicitBaselinePrefix() {
        let source = (0..<80)
            .map { "ERROR required failure \($0) at Sources/Foo\($0).swift:\($0 + 1)" }
            .joined(separator: "\n")

        let result = LibrarianEvidencePack(budgetBytes: 220).pack(source: source, question: "failure")

        XCTAssertEqual(result.strategy, .baselinePrefix, "required floor lines must not be silently discarded")
        XCTAssertLessThanOrEqual(result.renderedByteCount, 220)
        XCTAssertEqual(Array(result.text.utf8), Array(source.utf8.prefix(result.renderedByteCount)))
        XCTAssertEqual(result.headerByteCount, 0)
        XCTAssertFalse(result.hasEvidenceBeyondPrefixCutoff)
    }

    func test_unicodeOutputUsesSuppliedBudgetAsUTF8ByteCap() {
        var lines = (0..<120).map { "🙂 linha \($0)" }
        lines[80] = "🙂 CHAVE_ÚNICA encontrada"
        let source = lines.joined(separator: "\n")
        let budget = 320

        let result = LibrarianEvidencePack(budgetBytes: budget).pack(
            source: source,
            question: "CHAVE_ÚNICA"
        )

        XCTAssertEqual(result.budgetBytes, budget)
        XCTAssertLessThanOrEqual(result.renderedByteCount, budget)
        XCTAssertNotNil(result.text.data(using: .utf8))
        XCTAssertTrue(result.containsExactSpan("CHAVE_ÚNICA", in: source))
    }

    func test_giantSingleLineFallsBackAtValidUnicodeBoundary() {
        let source = String(repeating: "🙂", count: 3_000) + " SECRET_AFTER_CUTOFF"

        let result = LibrarianEvidencePack(budgetBytes: 6_000).pack(
            source: source,
            question: "SECRET_AFTER_CUTOFF"
        )

        XCTAssertEqual(result.strategy, .baselinePrefix, "one required line cannot be partially presented as a pack segment")
        XCTAssertLessThanOrEqual(result.renderedByteCount, 6_000)
        XCTAssertEqual(result.renderedByteCount % "🙂".utf8.count, 0)
        XCTAssertFalse(result.text.contains("SECRET_AFTER_CUTOFF"))
        XCTAssertTrue(result.verbatimSegmentsAreValid(in: source))
    }

    func test_jsonDiffAndStackFloorEvidenceRemainVerbatim() {
        assertCriticalEvidenceSurvives(
            rows: (0..<180).map { "  \"row_\($0)\": \"ok\"," },
            replacementIndex: 100,
            replacement: "  \"error\": \"JSON_NEEDLE\",",
            exact: "\"error\": \"JSON_NEEDLE\""
        )
        assertCriticalEvidenceSurvives(
            rows: (0..<180).map { "+ordinary diff row \($0)" },
            replacementIndex: 100,
            replacement: "+fatal DIFF_NEEDLE at Sources/Foo.swift:42",
            exact: "fatal DIFF_NEEDLE at Sources/Foo.swift:42"
        )
        assertCriticalEvidenceSurvives(
            rows: (0..<180).map { "trace detail row \($0)" },
            replacementIndex: 100,
            replacement: "    at runTask (/tmp/worker.js:77:4) STACK_NEEDLE",
            exact: "at runTask (/tmp/worker.js:77:4) STACK_NEEDLE"
        )
    }

    func test_secretAfterCutoffIsIncludedOrConservativelyFallsBack() {
        var normalLines = (0..<260).map { "unrelated record \($0)" }
        normalLines[210] = "API_SECRET_Z9=redacted"
        let normal = normalLines.joined(separator: "\n")
        let included = LibrarianEvidencePack(budgetBytes: 900).pack(
            source: normal,
            question: "API_SECRET_Z9"
        )
        XCTAssertEqual(included.strategy, .rankedEvidence)
        XCTAssertTrue(included.containsExactSpan("API_SECRET_Z9=redacted", in: normal))

        let oversizedSecretLine = String(repeating: "padding-", count: 300) + "API_SECRET_Z9=redacted"
        let oversized = "head\n" + oversizedSecretLine + "\ntail"
        let fallback = LibrarianEvidencePack(budgetBytes: 180).pack(
            source: oversized,
            question: "API_SECRET_Z9"
        )
        XCTAssertEqual(fallback.strategy, .baselinePrefix)
        XCTAssertFalse(fallback.containsExactSpan("API_SECRET_Z9=redacted", in: oversized))
    }

    func test_spanPresentOnlyInOmittedSourceIsRejected() {
        var lines = (0..<160).map { "quiet row \($0)" }
        lines[80] = "OMITTED_EXACT_SPAN"
        let source = lines.joined(separator: "\n")

        let result = LibrarianEvidencePack(budgetBytes: 180).pack(source: source, question: "")

        XCTAssertEqual(result.strategy, .rankedEvidence)
        XCTAssertFalse(result.text.contains("OMITTED_EXACT_SPAN"))
        XCTAssertFalse(result.containsExactSpan("OMITTED_EXACT_SPAN", in: source))
        XCTAssertFalse(result.containsVerbatimSpan(
            sourceByteRange: byteRange(of: "OMITTED_EXACT_SPAN", in: source),
            exact: "OMITTED_EXACT_SPAN",
            in: source
        ))
    }

    private func assertCriticalEvidenceSurvives(
        rows: [String],
        replacementIndex: Int,
        replacement: String,
        exact: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var rows = rows
        rows[replacementIndex] = replacement
        let source = rows.joined(separator: "\n")
        let result = LibrarianEvidencePack(budgetBytes: 440).pack(source: source, question: "")
        XCTAssertEqual(result.strategy, .rankedEvidence, file: file, line: line)
        XCTAssertTrue(result.containsExactSpan(exact, in: source), file: file, line: line)
        XCTAssertTrue(result.verbatimSegmentsAreValid(in: source), file: file, line: line)
        XCTAssertLessThanOrEqual(result.renderedByteCount, 440, file: file, line: line)
    }

    private func byteRange(of exact: String, in source: String) -> Range<Int> {
        let range = try! XCTUnwrap(source.range(of: exact))
        let lower = source[..<range.lowerBound].utf8.count
        return lower..<(lower + exact.utf8.count)
    }
}
