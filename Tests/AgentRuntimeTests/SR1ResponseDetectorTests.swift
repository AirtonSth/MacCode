import XCTest
@testable import AgentRuntime

/// Direct unit tests for SR1ResponseDetector detection thresholds.
///
/// WHY: the detector is only pinned via coordinator integration tests.
/// A "Sure: xxx"-style false-positive would surface as user-visible
/// mistranslation before any existing test fails (P2 QA item).
/// These tests encode the exact boundary conditions so regressions fail
/// at the detector, not downstream.
final class SR1ResponseDetectorTests: XCTestCase {

    // MARK: - isSR1: true positives

    func test_isSR1_explicitSR1Prefix_returnsTrue() {
        let text = "SR1 D: deploy service. C: staging. P: tests pass."
        XCTAssertTrue(SR1ResponseDetector.isSR1(text),
                      "text starting with 'SR1' is unambiguously compressed and must be detected")
    }

    func test_isSR1_dictColonPrefix_returnsTrue() {
        let text = "Dict: S=state D=action\nD: run tests"
        XCTAssertTrue(SR1ResponseDetector.isSR1(text),
                      "'Dict:' prefix is the SR1 dictionary declaration and must trigger detection")
    }

    func test_isSR1_multipleDelimitedSemanticLines_returnsTrue() {
        let text = "S: running\nD: build service\nR: none\nO: binary deployed"
        XCTAssertTrue(SR1ResponseDetector.isSR1(text),
                      "four colon-delimited semantic prefix lines must be detected as SR1")
    }

    func test_isSR1_twoInlineSegments_returnsTrue() {
        // Two inline segments with semantic boundary markers.
        let text = "D: fix bug. O: resolved."
        XCTAssertTrue(SR1ResponseDetector.isSR1(text),
                      "inline multi-segment SR1 line must be detected")
    }

    func test_isSR1_singleSemanticLine_returnsTrue() {
        let text = "D: deploy the service"
        XCTAssertTrue(SR1ResponseDetector.isSR1(text),
                      "a single colon-delimited semantic line must be detected as SR1")
    }

    func test_isSR1_threeSemanticLinesWithDifferentPrefixes_returnsTrue() {
        let text = "S: complete\nC: normal run\nP: all tests green"
        XCTAssertTrue(SR1ResponseDetector.isSR1(text),
                      "three colon-delimited lines with distinct prefixes must exceed the threshold")
    }

    func test_isSR1_classifierConfidentTrueOverridesHeuristicFalse() {
        let text = "compressed answer with nonstandard labels that the heuristic cannot prove"
        let classifier: SR1ResponseClassifier = { _ in
            SR1ClassifierDecision(isSR1: true, confidence: 0.93)
        }

        XCTAssertTrue(SR1ResponseDetector.isSR1(text, classifier: classifier),
                      "a confident classifier decision must catch SR1 that prefix heuristics miss")
    }

    func test_isSR1_classifierConfidentFalseOverridesHeuristicTrue() {
        let text = "D: Doctor recommends rest and fluids."
        let classifier: SR1ResponseClassifier = { _ in
            SR1ClassifierDecision(isSR1: false, confidence: 0.91)
        }

        XCTAssertFalse(SR1ResponseDetector.isSR1(text, classifier: classifier),
                       "a confident classifier rejection must prevent prefix false-positive buffer holds")
    }

    func test_isSR1_classifierLowConfidenceFallsBackToHeuristic() {
        let text = "D: deploy the service"
        let classifier: SR1ResponseClassifier = { _ in
            SR1ClassifierDecision(isSR1: false, confidence: 0.20)
        }

        XCTAssertTrue(SR1ResponseDetector.isSR1(text, classifier: classifier),
                      "low-confidence classifier output must fail open to the existing heuristic")
    }

    func test_isSR1_classifierNilDecisionFallsBackToHeuristic() {
        let text = "D: deploy the service"
        let classifier: SR1ResponseClassifier = { _ in nil }

        XCTAssertTrue(SR1ResponseDetector.isSR1(text, classifier: classifier),
                      "missing classifier output must preserve current SR1 detection behavior")
    }

    // MARK: - isSR1: false positives that must NOT be detected

    func test_isSR1_normalEnglishParagraph_returnsFalse() {
        let text = "Sure, I can help you with that. Let me take a look at the code and suggest some improvements."
        XCTAssertFalse(SR1ResponseDetector.isSR1(text),
                       "'Sure:'-prefixed natural English must not be treated as SR1 — this is the primary false-positive risk")
    }

    func test_isSR1_shortText_returnsFalse() {
        // Text shorter than 6 chars is guarded explicitly.
        let text = "OK"
        XCTAssertFalse(SR1ResponseDetector.isSR1(text),
                       "very short text must never be detected as SR1")
    }

    func test_isSR1_emptyText_returnsFalse() {
        XCTAssertFalse(SR1ResponseDetector.isSR1(""),
                       "empty text must return false")
    }

    func test_isSR1_singleWordWithColon_returnsFalse() {
        // "D: " alone fails the length guard; but a typical "Doctor: X" is prose.
        let text = "Doctor: I recommend rest and fluids for the next few days."
        XCTAssertFalse(SR1ResponseDetector.isSR1(text),
                       "prose starting with a capitalized word+colon must not be mistaken for SR1")
    }

    func test_isSR1_markdownHeadings_returnsFalse() {
        let text = "## Summary\n\nThis PR adds a new endpoint.\n\n## Changes\n\n- Added GET /v2/items\n- Updated schema"
        XCTAssertFalse(SR1ResponseDetector.isSR1(text),
                       "standard markdown (no semantic prefix characters) must not be detected as SR1")
    }

    // MARK: - parseSemanticLine

    func test_parseSemanticLine_colonDelimited_returnsPrefix() {
        let result = SR1ResponseDetector.parseSemanticLine("D: deploy service")
        XCTAssertEqual(result?.prefix, "D",
                       "colon-delimited line must parse the first character as prefix")
        XCTAssertEqual(result?.content, "deploy service",
                       "content must strip the 'D:' prefix and leading whitespace")
    }

    func test_parseSemanticLine_equalsDelimited_returnsPrefix() {
        let result = SR1ResponseDetector.parseSemanticLine("S=running")
        XCTAssertEqual(result?.prefix, "S")
        XCTAssertEqual(result?.content, "running",
                       "equals-delimited semantic line must parse correctly")
    }

    func test_parseSemanticLine_spaceDelimited_returnsPrefix() {
        let result = SR1ResponseDetector.parseSemanticLine("C context detail here")
        XCTAssertEqual(result?.prefix, "C")
        XCTAssertEqual(result?.content, "context detail here",
                       "space-delimited semantic line must parse correctly")
    }

    func test_parseSemanticLine_unknownPrefix_returnsNil() {
        // "X" is not in the semantic prefix set (SCDRONP).
        let result = SR1ResponseDetector.parseSemanticLine("X: unknown prefix line")
        XCTAssertNil(result,
                     "characters outside SCDRONP must not be parsed as semantic prefixes")
    }

    func test_parseSemanticLine_emptyContent_returnsNil() {
        let result = SR1ResponseDetector.parseSemanticLine("D:")
        XCTAssertNil(result,
                     "a semantic prefix with no content must return nil")
    }

    // MARK: - extractVariableAliases

    func test_extractVariableAliases_keyEqualsValue() {
        let text = "#A1 = deploy service"
        let aliases = SR1ResponseDetector.extractVariableAliases(text)
        XCTAssertEqual(aliases["#A1"], "deploy service",
                       "key=value assignment must be captured as a variable alias")
    }

    func test_extractVariableAliases_multipleOnOneLine() {
        let text = "#S1 = staging #S2 = production"
        let aliases = SR1ResponseDetector.extractVariableAliases(text)
        XCTAssertNotNil(aliases["#S1"], "first variable on the line must be captured")
        XCTAssertNotNil(aliases["#S2"], "second variable on the line must be captured")
    }

    func test_extractVariableAliases_noAssignments_returnsEmpty() {
        let text = "no variables here"
        let aliases = SR1ResponseDetector.extractVariableAliases(text)
        XCTAssertTrue(aliases.isEmpty,
                      "text with no variable patterns must return an empty alias map")
    }

    // MARK: - expandVariables

    func test_expandVariables_replacesDefinedKey() {
        let source = "#T1 = test suite"
        let text = "run #T1 now"
        let expanded = SR1ResponseDetector.expandVariables(in: text, from: source)
        XCTAssertEqual(expanded, "run test suite now",
                       "expandVariables must substitute defined variable keys with their values")
    }

    func test_expandVariables_noAliases_returnsOriginal() {
        let text = "no variables here"
        let expanded = SR1ResponseDetector.expandVariables(in: text, from: "also no variables")
        XCTAssertEqual(expanded, text,
                       "expandVariables with no aliases must return the input unchanged")
    }

    func test_expandVariables_doesNotReplacePartialMatch() {
        let source = "#T1 = test"
        let text = "run #T10 now"  // #T10 != #T1
        let expanded = SR1ResponseDetector.expandVariables(in: text, from: source)
        XCTAssertTrue(expanded.contains("#T10"),
                      "expandVariables must use whole-variable boundaries so #T1 does not clobber #T10")
    }

    // MARK: - isSingleSemanticLine

    func test_isSingleSemanticLine_trueForColonDelimited() {
        XCTAssertTrue(SR1ResponseDetector.isSingleSemanticLine("D: deploy now"),
                      "a single colon-delimited semantic line must be detected as such")
    }

    func test_isSingleSemanticLine_falseForMultiline() {
        XCTAssertFalse(SR1ResponseDetector.isSingleSemanticLine("D: one\nS: two"),
                       "text with newlines is not a single semantic line")
    }

    func test_isSingleSemanticLine_falseForProseO_withoutAllowFlag() {
        // Space-delimited O lines are ambiguous; default disallows them.
        XCTAssertFalse(SR1ResponseDetector.isSingleSemanticLine("O this is outcome", allowSpaceDelimitedOutcome: false),
                       "space-delimited O line must not be detected without the allowSpaceDelimitedOutcome flag")
    }

    func test_isSingleSemanticLine_trueForColonDelimitedO() {
        XCTAssertTrue(SR1ResponseDetector.isSingleSemanticLine("O: outcome text"),
                      "colon-delimited O line must always be detected as a single semantic line")
    }
}
