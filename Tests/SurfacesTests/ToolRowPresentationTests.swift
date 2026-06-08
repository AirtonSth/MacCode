import XCTest
import CoreModel
@testable import Surfaces

final class ToolRowPresentationTests: XCTestCase {
    private func toolItem(body: String, summary: String? = "Bash", type: AssistantItemType = .tool, output: String? = nil) -> AssistantItem {
        AssistantItem(id: "i", turnId: "t", type: type, state: .completed, summary: summary, body: body, output: output, startedAtMs: 0)
    }

    func test_extractsBashCommandFromJSONBody() {
        let item = toolItem(body: #"{"command":"swift build && swift test","description":"build"}"#)
        XCTAssertEqual(AgentTimelineItemPresentation.toolCommandPreview(for: item), "swift build && swift test",
                       "the bash command (the info that was missing under 'Ran Bash') must be surfaced")
    }

    func test_extractsFilePathForReadEdit() {
        let item = toolItem(body: #"{"file_path":"/a/b/Foo.swift"}"#, summary: "Read")
        XCTAssertEqual(AgentTimelineItemPresentation.toolCommandPreview(for: item), "/a/b/Foo.swift")
    }

    func test_extractsSkillName() {
        let item = toolItem(body: #"{"skill":"ads","args":"audit"}"#, summary: "Skill")
        XCTAssertEqual(AgentTimelineItemPresentation.toolCommandPreview(for: item), "ads")
    }

    func test_nonJSONBodyReturnedVerbatim() {
        XCTAssertEqual(AgentTimelineItemPresentation.toolCommandPreview(for: toolItem(body: "raw command text")), "raw command text")
    }

    func test_nonToolItemReturnsNilCommand() {
        XCTAssertNil(AgentTimelineItemPresentation.toolCommandPreview(for: toolItem(body: #"{"command":"x"}"#, type: .assistantMessage)))
    }

    func test_cappedDetailTruncatesLongOutput() {
        let long = String(repeating: "x", count: 10_000)
        let capped = AgentTimelineItemPresentation.cappedDetail(long, limit: 6_000)
        XCTAssertLessThan(capped.count, long.count, "a noisy Skill/command dump must not blow up the transcript")
        XCTAssertTrue(capped.contains("truncated in view"))
    }

    func test_cappedDetailLeavesShortOutput() {
        XCTAssertEqual(AgentTimelineItemPresentation.cappedDetail("short", limit: 6_000), "short")
    }

    func test_presentationStillShowsRanToolName() {
        let p = AgentTimelineItemPresentation.make(for: toolItem(body: #"{"command":"ls"}"#, summary: "Bash"))
        XCTAssertEqual(p.verb, "Ran")
        XCTAssertEqual(p.label, "Bash")
    }

    func test_cappedDetailStripsANSIEscapeCodes() {
        let ansi = "\u{001B}[32mPASS\u{001B}[0m all tests \u{001B}[1;31mFAIL\u{001B}[0m none"
        let clean = AgentTimelineItemPresentation.cappedDetail(ansi)
        XCTAssertEqual(clean, "PASS all tests FAIL none", "ANSI color codes must be stripped, not shown literally")
        XCTAssertFalse(clean.contains("\u{001B}"))
    }

    func test_stripANSILeavesPlainTextUntouched() {
        XCTAssertEqual(AgentTimelineItemPresentation.stripANSI("no escapes here"), "no escapes here")
    }
}
