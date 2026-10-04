import AgentRuntime
import CoreModel
import Persistence
import Darwin
import XCTest
@testable import Surfaces

/// Resident memory (phys_footprint), as Activity Monitor reports it.
func perfPhysFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Goal: Agent App / bot desk streaming should cost about what Distill in a
/// terminal costs. These drive the shipped live-row markdown path and the
/// shipped AgentAppViewModel stream path with a 2,000-delta Distill-shaped reply.
final class DistillTerminalParityPerfTests: XCTestCase {
    /// Realistic Distill reply: paragraphs, lists, a code fence, a table.
    private static func reply(deltas: Int) -> [String] {
        let paragraph = "The coordinator buffers stream writes and flushes them in batches so a delta never pays a transaction. "
        let units = [
            "## Section\n\n", paragraph, paragraph, "\n\n",
            "- first point about `code`\n", "- second **bold** point\n\n",
            "```swift\nlet x = 1\n\nlet y = 2\n```\n\n",
            "| a | b |\n|---|---|\n| 1 | 2 |\n\n",
            paragraph, "\n\n"
        ]
        let text = String(repeating: units.joined(), count: 60)
        let chars = Array(text)
        let size = max(1, chars.count / deltas)
        return stride(from: 0, to: chars.count, by: size).map { String(chars[$0..<min(chars.count, $0 + size)]) }
    }

    func test_liveMarkdownSplitParseEqualsFullParseForEveryStreamPrefix() {
        // WHY: the live path parses a cached stable prefix plus the growing
        // tail. It must render exactly what a full parse renders at every
        // token, including inside open code fences and tables.
        var text = ""
        for (index, delta) in Self.reply(deltas: 400).enumerated() {
            text += delta
            let live = AgentMessageMarkdown.blocks(from: text, cache: false)
            let full = AgentMessageMarkdown.blocks(from: text, cache: true)
            XCTAssertEqual(live, full, "prefix #\(index) diverged:\n\(text.suffix(120))")
            if live != full { return }
        }
    }

    func test_liveMarkdownParseWorkStaysLinearOver2000Deltas() {
        // WHY: every 33 ms paint re-tokenized the whole growing body, so a long
        // reply cost O(n²) parse bytes on the main thread. After the stable
        // prefix split the per-paint parse is the tail only.
        let deltas = Self.reply(deltas: 2_000)
        XCTAssertGreaterThanOrEqual(deltas.count, 2_000)
        var text = ""
        var prefixes: [String] = []
        for delta in deltas { text += delta; prefixes.append(text) }
        let totalBytes = text.utf8.count

        AgentMessageMarkdown.blocksParsedUTF8BytesForTesting = 0
        let clock = ContinuousClock()
        let liveStart = clock.now
        for prefix in prefixes { _ = AgentMessageMarkdown.blocks(from: prefix, cache: false) }
        let liveElapsed = liveStart.duration(to: clock.now)
        let liveBytes = AgentMessageMarkdown.blocksParsedUTF8BytesForTesting

        // Reference: the previous live behavior was one full uncached parse per paint.
        AgentMessageMarkdown.blocksParsedUTF8BytesForTesting = 0
        let fullStart = clock.now
        for prefix in prefixes { _ = AgentMessageMarkdown.blocks(from: prefix + "\u{0}", cache: true) }
        let fullElapsed = fullStart.duration(to: clock.now)
        let fullBytes = AgentMessageMarkdown.blocksParsedUTF8BytesForTesting

        print("PERF markdown deltas=\(deltas.count) replyBytes=\(totalBytes) liveParsedBytes=\(liveBytes) fullParsedBytes=\(fullBytes) liveMs=\(liveElapsed) fullMs=\(fullElapsed)")
        // Each paint may re-parse only the open tail (one block group, < 1 KiB
        // here), never the stable history.
        XCTAssertLessThan(liveBytes, deltas.count * 1_024, "per-paint parse must be bounded by the open tail")
        XCTAssertLessThan(liveBytes * 10, fullBytes, "split parse must do <10% of full re-parse work")
    }

    /// Mirrors one live-row paint of `AgentMessageMarkdownView.body`.
    private func paintLiveRow(_ text: String) {
        let groups = AgentMessageMarkdown.selectionGroups(from: AgentMessageMarkdown.blocks(from: text, cache: false))
        for (index, group) in groups.enumerated() where !(group.count == 1 && {
            if case .code = group[0].kind { return true }
            if case .table = group[0].kind { return true }
            return false
        }()) {
            _ = AgentMessageMarkdown.selectableProse(from: group, compact: false, cache: index < groups.count - 1)
        }
    }

    func test_liveRowPaintCostOver2000Deltas() {
        // WHY: the whole live row (block parse + prose attribution) runs on the
        // main thread every 33 ms paint. Its total cost over a long turn must
        // not grow quadratically with reply length.
        let deltas = Self.reply(deltas: 2_000)
        var text = ""
        var prefixes: [String] = []
        for delta in deltas { text += delta; prefixes.append(text) }
        AgentMessageMarkdown.inlineComputeCountForTesting = 0
        let clock = ContinuousClock()
        let memBefore = perfPhysFootprintBytes()
        let start = clock.now
        for prefix in prefixes { autoreleasepool { paintLiveRow(prefix) } }
        let elapsed = start.duration(to: clock.now)
        let memGrowth = Int64(perfPhysFootprintBytes()) - Int64(memBefore)
        let inline = AgentMessageMarkdown.inlineComputeCountForTesting
        print("PERF liveRow deltas=\(deltas.count) inlineParses=\(inline) elapsed=\(elapsed) memGrowthKB=\(memGrowth / 1024)")
        // A ~27 KB reply must not leave tens of MB resident (the old path parsed 27 MB).
        XCTAssertLessThan(memGrowth, 32 * 1024 * 1024, "live row paint must not retain memory proportional to prefixes parsed")
        XCTAssertLessThan(inline, deltas.count * 3, "each paint may attribute only the growing block, not every prose block")
    }
}
