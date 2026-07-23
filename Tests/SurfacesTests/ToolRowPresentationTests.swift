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

    func test_structuredInputDigestIsCleanNotRawBraces() {
        // AskUserQuestion-shaped input: no priority key matches, so the digest is used.
        let item = toolItem(body: #"{"questions":[{"header":"Route guard"},{"header":"X"}],"mode":"single"}"#, summary: "AskUserQuestion")
        let preview = AgentTimelineItemPresentation.toolCommandPreview(for: item)
        XCTAssertEqual(preview, "mode: single   questions: [2]",
                       "structured inputs show a clean shape hint, not Swift's brace-y debug description")
        XCTAssertFalse(preview?.contains("{ {") ?? false)
    }

    func test_shortValueShapeHints() {
        XCTAssertEqual(AgentTimelineItemPresentation.shortValue(["a", "b", "c"]), "[3]")
        XCTAssertEqual(AgentTimelineItemPresentation.shortValue(["k": 1]), "{k}")
        XCTAssertEqual(AgentTimelineItemPresentation.shortValue("hello"), "hello")
        XCTAssertEqual(AgentTimelineItemPresentation.shortValue(NSNull()), "—")
    }

    // MARK: Tool-burst grouping

    private func item(_ type: AssistantItemType, id: String = "x", state: AssistantItemState = .completed) -> AssistantItem {
        AssistantItem(id: id, turnId: "t", type: type, state: state, summary: nil, body: "", startedAtMs: 0)
    }

    private func isGroup(_ block: AgentAppView.TurnRenderBlock) -> Bool {
        if case .toolGroup = block { return true }
        return false
    }

    func test_threeConsecutiveToolsCollapseIntoOneGroup() {
        let items = (0..<3).map { item(.mcpToolCall, id: "m\($0)") }
        let blocks = AgentAppView.turnRenderBlocks(items)
        XCTAssertEqual(blocks.count, 1, "a burst of identical tool calls must fold into a single group, not flood the transcript")
        guard case .toolGroup(_, let grouped) = blocks[0] else { return XCTFail("expected a toolGroup") }
        XCTAssertEqual(grouped.count, 3)
    }

    func test_loneToolStaysInline() {
        let blocks = AgentAppView.turnRenderBlocks([item(.tool)])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertFalse(isGroup(blocks[0]), "a single tool call must NOT be hidden behind a group header")
    }

    func test_assistantMessageBreaksTheRun() {
        // tool, tool | message | tool, tool  ->  group, item, group (not one big group)
        let items = [
            item(.tool, id: "a"), item(.tool, id: "b"),
            item(.assistantMessage, id: "msg"),
            item(.tool, id: "c"), item(.tool, id: "d"),
        ]
        let blocks = AgentAppView.turnRenderBlocks(items)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(isGroup(blocks[0]))
        XCTAssertFalse(isGroup(blocks[1]), "the answer prose must never be swallowed into a tool group")
        XCTAssertTrue(isGroup(blocks[2]))
    }

    func test_errorIsNeverGrouped() {
        // An error between two tools breaks the run and stays standalone (must remain visible).
        let items = [item(.tool, id: "a"), item(.error, id: "e"), item(.tool, id: "b")]
        let blocks = AgentAppView.turnRenderBlocks(items)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(blocks.allSatisfy { !isGroup($0) }, "errors must not be folded away into a count")
    }

    func test_summaryUsesCountVerbAndNoun() {
        let commands = (0..<4).map { item(.commandExecution, id: "c\($0)") }
        XCTAssertEqual(AgentAppView.toolGroupSummary(commands), "Ran 4 commands")

        let files = (0..<2).map { item(.fileChange, id: "f\($0)") }
        XCTAssertEqual(AgentAppView.toolGroupSummary(files), "Changed 2 files")
    }

    func test_summaryGoesLiveWhileStreaming() {
        let items = [item(.tool, id: "a"), item(.tool, id: "b", state: .streaming)]
        XCTAssertEqual(AgentAppView.toolGroupSummary(items), "Running 2 commands…",
                       "a still-running burst must read as live, not as a finished count")
    }

    func test_partitionLiveTurnItems_foldsSettledWorkBeforeStreamingTail() {
        // WHY: Grok interleaves Thought between tools. Without partitioning, every
        // completed command stays a full toolRow and the live transcript cannot
        // collapse. Settled prefix must fold; the streaming item stays active.
        var items: [AssistantItem] = []
        for index in 0..<6 {
            items.append(item(.commandExecution, id: "cmd-\(index)", state: .completed))
            items.append(item(.reasoning, id: "thought-\(index)", state: .completed))
        }
        items.append(item(.commandExecution, id: "active", state: .streaming))

        let (settled, active) = AgentAppView.partitionLiveTurnItems(items)

        XCTAssertEqual(active.last?.id, "active",
                       "the streaming item must stay in the active tail")
        XCTAssertTrue(active.contains(where: { $0.id == "active" }))
        XCTAssertFalse(settled.contains(where: { $0.id == "active" }),
                       "the active command must not also live in the collapsed work disclosure")
        XCTAssertEqual(settled.count + active.count, items.count,
                       "partition must preserve every item exactly once")
        XCTAssertGreaterThan(settled.count, 0,
                             "completed tools/thoughts before the stream must collapse into settled work")
        XCTAssertLessThanOrEqual(active.count, AgentAppView.liveTurnActiveTailLimit,
                                 "active tail must stay short so the live view stays chat-dense")
    }

    func test_partitionLiveTurnItems_noStreamingKeepsOnlyNewestTail() {
        let items = (0..<10).map { item(.tool, id: "t\($0)", state: .completed) }
        let (settled, active) = AgentAppView.partitionLiveTurnItems(items)
        XCTAssertEqual(active.count, AgentAppView.liveTurnActiveTailLimit)
        XCTAssertEqual(settled.count, items.count - AgentAppView.liveTurnActiveTailLimit)
        XCTAssertEqual(active.map(\.id), items.suffix(AgentAppView.liveTurnActiveTailLimit).map(\.id))
    }

    func test_computeTurnRenderInputs_runningTurnCollapsesSettledWork() {
        let turnId = "live-turn"
        var items: [AssistantItem] = (0..<5).map {
            item(.commandExecution, id: "done-\($0)", state: .completed)
        }
        items.append(item(.commandExecution, id: "now", state: .streaming))
        let turn = AssistantTurnSnapshot(turnId: turnId, items: items.map { item in
            var copy = item
            // turnId must match for snapshot integrity
            return AssistantItem(
                id: copy.id, turnId: turnId, type: copy.type, state: copy.state,
                summary: nil, body: "", startedAtMs: 1
            )
        })
        let inputs = AgentAppView.computeTurnRenderInputs(
            turn: turn,
            persistedAssistantTexts: [],
            proposedPlans: [],
            running: true
        )
        XCTAssertFalse(inputs.completedWorkBlocks.isEmpty,
                       "settled work must become a collapsible work disclosure while running")
        XCTAssertFalse(inputs.visibleBlocks.isEmpty,
                       "the active streaming command must still paint live")
        // Active blocks should not re-list every completed command.
        let visibleIds = inputs.visibleBlocks.flatMap { block -> [String] in
            switch block {
            case .item(let i): return [i.id]
            case .toolGroup(_, let group): return group.map(\.id)
            }
        }
        XCTAssertTrue(visibleIds.contains("now"))
        XCTAssertFalse(visibleIds.contains("done-0"),
                       "early completed commands must not stay expanded in the live path")
    }
}
