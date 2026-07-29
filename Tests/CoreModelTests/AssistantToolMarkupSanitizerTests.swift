import XCTest
@testable import CoreModel

/// Contract: raw tool-invocation markup must never survive into final assistant
/// text, while fenced/inline code that documents tool syntax must be untouched.
///
/// WHY: headless runs sometimes emit an unexecuted tool call as plain text
/// (mangled `<ScheduleWakeup>…</invoke>`), which was persisted and rendered,
/// then the run reported completed and the thread stalled.
final class AssistantToolMarkupSanitizerTests: XCTestCase {

    /// Exact mangled payload from the proven incident (fact 2).
    private let mangledIncidentPayload = """
    <ScheduleWakeup>
    <parameter name="delaySeconds">10</parameter>
    <parameter name="reason">Waiting for sam-plan skill to complete execution</parameter>
    <parameter name="prompt">/sam-task https://linear.app/empathmsp/issue/DEV-3983</parameter>
    </invoke>
    """

    func test_stripsExactMangledIncidentPayload() {
        XCTAssertTrue(
            AssistantToolMarkupSanitizer.contains(mangledIncidentPayload),
            "incident mangled form must be detected"
        )
        let stripped = AssistantToolMarkupSanitizer.strip(mangledIncidentPayload)
        XCTAssertFalse(stripped.contains("ScheduleWakeup"))
        XCTAssertFalse(stripped.contains("<parameter"))
        XCTAssertFalse(stripped.contains("</invoke>"))
        XCTAssertFalse(stripped.contains("delaySeconds"))
        XCTAssertTrue(stripped.isEmpty, "markup-only message strips to empty before marker injection")
    }

    func test_sanitize_injectsUncalledToolMarkerOnMangledPayload() {
        let sanitized = AssistantToolMarkupSanitizer.sanitize(mangledIncidentPayload)
        XCTAssertTrue(
            AssistantToolMarkupSanitizer.containsUncalledToolSignal(sanitized),
            "sanitize must leave a durable incomplete-turn signal"
        )
        XCTAssertTrue(sanitized.contains(AssistantToolMarkupSanitizer.uncalledToolMarker))
        XCTAssertFalse(sanitized.contains("<ScheduleWakeup>"))
        XCTAssertFalse(sanitized.contains("</invoke>"))
    }

    func test_stripsCanonicalInvokeAndPreservesSurroundingProse() {
        let text = """
        I'll schedule a follow-up.
        <invoke name="ScheduleWakeup">
        <parameter name="delaySeconds">10</parameter>
        </invoke>
        Then continue the task.
        """
        let out = AssistantToolMarkupSanitizer.strip(text)
        XCTAssertTrue(out.contains("I'll schedule a follow-up."))
        XCTAssertTrue(out.contains("Then continue the task."))
        XCTAssertFalse(out.contains("<invoke"))
        XCTAssertFalse(out.contains("</invoke>"))
        XCTAssertFalse(out.contains("<parameter"))
    }

    func test_stripsNamespacedInvokeAndFunctionCallsWrapper() {
        let text = """
        <function_calls>
        <ns:invoke name="Bash">
        <parameter name="command">ls</parameter>
        </ns:invoke>
        </function_calls>
        Done listing.
        """
        let out = AssistantToolMarkupSanitizer.strip(text)
        XCTAssertEqual(out, "Done listing.")
        XCTAssertFalse(out.contains("function_calls"))
        XCTAssertFalse(out.contains("invoke"))
    }

    func test_stripsStandaloneParameterRuns() {
        let text = """
        Partial dump:
        <parameter name="reason">still waiting</parameter>
        after.
        """
        let out = AssistantToolMarkupSanitizer.strip(text)
        XCTAssertTrue(out.contains("Partial dump:"))
        XCTAssertTrue(out.contains("after."))
        XCTAssertFalse(out.contains("<parameter"))
    }

    func test_leavesFencedCodeBlocksUntouched() {
        let docs = """
        Example tool syntax for docs:

        ```
        <ScheduleWakeup>
        <parameter name="delaySeconds">10</parameter>
        </invoke>
        ```

        That is documentation only.
        """
        let out = AssistantToolMarkupSanitizer.strip(docs)
        XCTAssertTrue(
            out.contains("<ScheduleWakeup>"),
            "fenced documentation of tool syntax must survive strip"
        )
        XCTAssertTrue(out.contains("<parameter name=\"delaySeconds\">10</parameter>"))
        XCTAssertTrue(out.contains("</invoke>"))
        XCTAssertTrue(out.contains("That is documentation only."))
        XCTAssertFalse(
            AssistantToolMarkupSanitizer.contains(docs),
            "markup only inside fences must not count as an uncalled-tool signal"
        )
        let sanitized = AssistantToolMarkupSanitizer.sanitize(docs)
        XCTAssertFalse(
            sanitized.contains(AssistantToolMarkupSanitizer.uncalledToolMarker),
            "docs-only fences must not inject the incomplete-turn marker"
        )
    }

    func test_leavesInlineCodeSpansUntouched() {
        let text = "Use `<invoke name=\"Bash\">` in docs, not as a final answer."
        let out = AssistantToolMarkupSanitizer.strip(text)
        XCTAssertEqual(out, text)
        XCTAssertFalse(AssistantToolMarkupSanitizer.contains(text))
    }

    func test_proseMarkupStrippedWhileAdjacentFencePreserved() {
        let text = """
        Bad final:
        <invoke name="ScheduleWakeup"><parameter name="delaySeconds">5</parameter></invoke>

        Good docs:
        ```
        <invoke name="ScheduleWakeup"></invoke>
        ```
        """
        let out = AssistantToolMarkupSanitizer.strip(text)
        XCTAssertFalse(out.contains("Bad final:\n<invoke"), "prose invoke must be stripped")
        XCTAssertTrue(out.contains("```\n<invoke name=\"ScheduleWakeup\"></invoke>\n```"))
        XCTAssertTrue(out.contains("Good docs:"))
    }

    func test_leavesCleanTextUnchanged() {
        let text = "All four steps are done; the build is green and the PR is open."
        XCTAssertEqual(AssistantToolMarkupSanitizer.strip(text), text)
        XCTAssertEqual(AssistantToolMarkupSanitizer.sanitize(text), text)
        XCTAssertFalse(AssistantToolMarkupSanitizer.contains(text))
        XCTAssertFalse(AssistantToolMarkupSanitizer.containsUncalledToolSignal(text))
    }

    func test_strippingUncalledToolMarker_removesMarkerKeepsProse() {
        let raw = "\(AssistantToolMarkupSanitizer.uncalledToolMarker)\nI'll continue without that tool."
        let shown = AssistantToolMarkupSanitizer.strippingUncalledToolMarker(raw)
        XCTAssertFalse(shown.contains(AssistantToolMarkupSanitizer.uncalledToolMarker))
        XCTAssertEqual(shown, "I'll continue without that tool.")
    }

    func test_strippingAwaitingMarker_alsoStripsUncalledToolMarker() {
        // Render path uses strippingAwaitingMarker for every assistant bubble.
        let raw = "\(AssistantToolMarkupSanitizer.uncalledToolMarker)\nResuming."
        let shown = BackgroundAwaitContinuation.strippingAwaitingMarker(raw)
        XCTAssertFalse(shown.contains(AssistantToolMarkupSanitizer.uncalledToolMarker))
        XCTAssertEqual(shown, "Resuming.")
    }
}
