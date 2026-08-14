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
        XCTAssertLessThan(capped.count, long.count, "a noisy ordinary command dump must not blow up the transcript")
        XCTAssertTrue(capped.contains("truncated in view"))
    }

    func test_cappedDetailLeavesShortOutput() {
        XCTAssertEqual(AgentTimelineItemPresentation.cappedDetail("short", limit: 6_000), "short")
    }

    /// WHY: multi-byte graphemes can sit under the grapheme window while over the
    /// UTF-8 budget — expanded tool detail must not over-truncate them.
    func test_cappedDetail_preservesMultibyteUnderGraphemeLimit() {
        let multibyte = "héllo" // 5 graphemes, >5 UTF-8 bytes
        XCTAssertGreaterThan(multibyte.utf8.count, 5)
        XCTAssertEqual(
            AgentTimelineItemPresentation.cappedDetail(multibyte, limit: 5),
            multibyte,
            "tool detail cap must stay grapheme-based for multi-byte text under the limit"
        )
        let emoji = "😀😀😀😀"
        let capped = AgentTimelineItemPresentation.cappedDetail(emoji, limit: 2)
        XCTAssertTrue(capped.hasPrefix("😀😀"))
        XCTAssertTrue(capped.contains("truncated in view"))
    }

    /// Microbench: full-body `String.count` walk vs O(limit) index tool detail cap.
    /// Simulates expanded tool-row paint re-capping a long command dump.
    ///
    /// `cappedDetail` bundles `stripANSI` with the cap, and stripANSI dominates
    /// (~90% of wall time on an 80k body). Timing the two arms end to end reported
    /// a ~9% delta for a cap that got ~50x cheaper. Subtracting a separately
    /// sampled stripANSI floor does NOT fix that: the isolated signal is smaller
    /// than the inter-loop noise, so the subtraction clamps to zero and reports a
    /// vacuous 100%.
    ///
    /// So hoist the shared cost out instead of estimating it. Both arms run on the
    /// same pre-stripped `clean`, timing only the cap. The index arm is pinned to
    /// the shipped `cappedDetail` output first, so the benchmark cannot drift away
    /// from the product path it stands for.
    func test_microbench_cappedDetail_indexFasterThanFullGraphemeCount() {
        let body = String(repeating: "x", count: 80_000)
        let limit = 6_000
        let iterations = 2_000
        let warmup = 2
        let samples = 5
        let clean = AgentTimelineItemPresentation.stripANSI(body)

        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        /// Legacy shape: full O(n) grapheme count, then prefix.
        func legacyCap(_ text: String) -> String {
            guard text.count > limit else { return text }
            let head = text.prefix(limit)
            let dropped = text.count - head.count
            return "\(head)\n… \(dropped) more characters truncated in view …"
        }

        /// Shipped shape: O(1) utf8 gate + O(limit) index arithmetic.
        func indexCap(_ text: String) -> String {
            guard text.utf8.count > limit else { return text }
            guard let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex),
                  end < text.endIndex else { return text }
            let head = text[..<end]
            let dropped = max(1, text.utf8.count - head.utf8.count)
            return "\(head)\n… \(AgentTimelineItemPresentation.truncationSizeLabel(dropped)) more truncated in view …"
        }

        // Pin: the benchmarked shape must equal what the product function returns,
        // so a future change to cappedDetail cannot silently leave this measuring
        // a stale algorithm.
        XCTAssertEqual(indexCap(clean), AgentTimelineItemPresentation.cappedDetail(body, limit: limit),
                       "benchmarked index shape must match the shipped cappedDetail output")

        func time(_ shape: (String) -> String) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations { sink &+= shape(clean).utf8.count }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup { _ = time(legacyCap); _ = time(indexCap) }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(time(legacyCap))
            after.append(time(indexCap))
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        // Key names the ISOLATED cap sub-step, not end-to-end `cappedDetail`:
        // the shipped function still calls stripANSI on every invocation, so its
        // end-to-end improvement is far smaller (~9%). Quoting this number as
        // "cappedDetail got 90% faster" would repeat the over-claim this whole
        // correction exists to stop.
        NSLog("[perf-proof] cappedDetail_isolatedCap legacy_count_ms=%@ index_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 50.0,
            "isolated tool detail cap must beat the full grapheme count by ≥50% (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
        let capped = AgentTimelineItemPresentation.cappedDetail(body, limit: limit)
        XCTAssertTrue(capped.contains("truncated in view"))
        XCTAssertTrue(capped.hasPrefix(String(body.prefix(limit))))
    }

    func test_skillToolOutputIsNeverTruncatedEvenWhenLarge() {
        // WHY: skill content is a protected verbatim category. Ordinary tool output
        // still uses the generic cap; Skill must return complete bodies so the agent
        // path and the displayed/persisted canonical representation stay whole.
        let largeSkillBody = """
        ---
        name: fixture-skill
        ---
        # Fixture Skill
        \(String(repeating: "complete skill line — never distill or truncate\n", count: 400))
        SKILL_FIXTURE_END
        """
        XCTAssertGreaterThan(largeSkillBody.count, 6_000, "fixture must exceed the ordinary display cap")

        let skillItem = toolItem(
            body: #"{"skill":"fixture-skill","args":""}"#,
            summary: "Skill",
            output: largeSkillBody
        )
        XCTAssertTrue(AgentTimelineItemPresentation.isSkillToolItem(skillItem))

        let presented = AgentTimelineItemPresentation.cappedDetail(largeSkillBody, limit: 6_000, for: skillItem)
        XCTAssertEqual(presented, largeSkillBody,
                       "Skill presentation must preserve exact skill content with no truncation marker")
        XCTAssertFalse(presented.contains("truncated in view"))
        XCTAssertFalse(presented.contains("[[rc:"))
        XCTAssertTrue(presented.hasSuffix("SKILL_FIXTURE_END\n") || presented.contains("SKILL_FIXTURE_END"))

        // Ordinary Bash of the same size still truncates (cap remains for non-skill).
        let bashItem = toolItem(body: #"{"command":"swift test"}"#, summary: "Bash", output: largeSkillBody)
        XCTAssertFalse(AgentTimelineItemPresentation.isSkillToolItem(bashItem))
        let ordinary = AgentTimelineItemPresentation.cappedDetail(largeSkillBody, limit: 6_000, for: bashItem)
        XCTAssertTrue(ordinary.contains("truncated in view"),
                      "ordinary tool output remains eligible for display truncation")
        XCTAssertNotEqual(ordinary, largeSkillBody)
    }

    func test_presentationStillShowsRanToolName() {
        let p = AgentTimelineItemPresentation.make(for: toolItem(body: #"{"command":"ls"}"#, summary: "Bash"))
        XCTAssertEqual(p.verb, "Ran")
        XCTAssertEqual(p.label, "Bash")
    }

    // MARK: Tool card density (UX-MAC_AGENT-TOOL-CARD)

    func test_toolDisplayLabel_stripsBgAndShellPipelineFromTitle() {
        // WHY: Grok titles often paste `[bg] cd … && git push…` into summary; L1 must
        // stay a short tool name so the row is scannable.
        let item = toolItem(
            body: #"{"command":"cd /Users/sam/dev/app && git push origin production 2>&1 | distill \"reason\"","background":true}"#,
            summary: "[bg] cd /Users/sam/dev/app && git push origin production 2>&1 | distill \"reason\""
        )
        XCTAssertEqual(AgentTimelineItemPresentation.toolDisplayLabel(for: item), "Shell")
        XCTAssertTrue(AgentTimelineItemPresentation.isBackgroundTool(for: item))
    }

    func test_toolDisplayLabel_stripsCallUUIDFromGetTaskOutput() {
        let item = toolItem(
            body: #"{"task_ids":[1],"timeout_ms":180000}"#,
            summary: "Get task output: call-3566c18b-b595-4299-91fe-088abdba8159-25"
        )
        XCTAssertEqual(
            AgentTimelineItemPresentation.toolDisplayLabel(for: item),
            "Get task output",
            "call UUIDs are provider noise on L1 — keep the human tool name only"
        )
    }

    func test_toolCommandSummary_prefersLastCommandAndStripsDistill() {
        // WHY: collapsed L2 must show the intent (`git push`), not cd + distill wrapper —
        // and must advertise elision (`+N more`) so Token Saver is not silently hidden.
        let item = toolItem(
            body: #"{"command":"cd /Users/samuelfajreldines/dev/pamela-studio && git push origin production 2>&1 | distill \"push success or failure reason\""}"#,
            summary: "Bash"
        )
        let summary = AgentTimelineItemPresentation.toolCommandSummary(for: item)
        XCTAssertEqual(summary, "git push origin production · +2 more")
        XCTAssertTrue(AgentTimelineItemPresentation.toolCommandWasDistilled(for: item))
        let full = AgentTimelineItemPresentation.rawShellCommand(for: item)
        XCTAssertTrue(full?.contains("distill") == true,
                      "full preview retains the real command for expand/copy")
        XCTAssertNotEqual(summary, full)
    }

    func test_toolCommandWasDistilled_detectsAutomaticInterceptorReceipt() {
        // WHY: transparent PATH interception leaves the original command unchanged;
        // the reversible output receipt is the authoritative evidence that Distill ran.
        let item = toolItem(
            body: #"{"command":"ls -la /usr/bin"}"#,
            summary: "Bash",
            output: "important lines\n[[rc:rcv1.ABCDEFGHIJKLMNOPQRSTUV]]"
        )

        XCTAssertFalse(item.body.contains("| distill"))
        XCTAssertTrue(AgentTimelineItemPresentation.toolCommandWasDistilled(for: item))
    }

    func test_toolCommandWasDistilled_ignoresMalformedRecoveryMarker() {
        // WHY: arbitrary tool output must not be able to spoof the Distilled badge.
        let item = toolItem(
            body: #"{"command":"printf hello"}"#,
            summary: "Bash",
            output: "hello [[rc:rcv1.not-a-capability]]"
        )

        XCTAssertFalse(AgentTimelineItemPresentation.toolCommandWasDistilled(for: item))
    }

    func test_toolCommandPreview_humanizesTaskTimeoutPayload() {
        // WHY: raw `task_ids: [1] timeout_ms: 180000` reads like a debug dump.
        let item = toolItem(
            body: #"{"task_ids":[1],"timeout_ms":180000}"#,
            summary: "Get task output"
        )
        XCTAssertEqual(
            AgentTimelineItemPresentation.toolCommandPreview(for: item),
            "1 task · timeout 3m"
        )
        XCTAssertEqual(
            AgentTimelineItemPresentation.toolCommandSummary(for: item),
            "1 task · timeout 3m"
        )
    }

    func test_formatDurationMs_boundaries() {
        XCTAssertEqual(AgentTimelineItemPresentation.formatDurationMs(450), "450ms")
        XCTAssertEqual(AgentTimelineItemPresentation.formatDurationMs(12_000), "12s")
        XCTAssertEqual(AgentTimelineItemPresentation.formatDurationMs(113_000), "1m 53s")
        XCTAssertEqual(AgentTimelineItemPresentation.formatDurationMs(180_000), "3m")
        XCTAssertEqual(AgentTimelineItemPresentation.formatDurationMs(3_600_000), "1h")
    }

    func test_toolDurationLabel_usesFinishedAtWhenCompleted() {
        let item = AssistantItem(
            id: "i", turnId: "t", type: .tool, state: .completed,
            summary: "Bash", body: #"{"command":"ls"}"#,
            startedAtMs: 1_000, finishedAtMs: 13_500
        )
        XCTAssertEqual(AgentTimelineItemPresentation.toolDurationLabel(for: item), "12s")
    }

    func test_toolDurationLabel_ordinaryStreamingStaysNil() {
        // WHY: per-row live clocks are a known transcript perf trap for ordinary tools;
        // "Working for Xs" already covers the active run. Only background / task-wait
        // streaming rows opt into live elapsed (with nowMs).
        let item = AssistantItem(
            id: "i", turnId: "t", type: .tool, state: .streaming,
            summary: "Bash", body: #"{"command":"sleep 1"}"#,
            startedAtMs: 0
        )
        XCTAssertNil(AgentTimelineItemPresentation.toolDurationLabel(for: item))
        XCTAssertNil(AgentTimelineItemPresentation.toolDurationLabel(for: item, nowMs: 90_000))
        XCTAssertFalse(AgentTimelineItemPresentation.showsLiveToolElapsed(for: item))
    }

    func test_toolDurationLabel_backgroundStreamingShowsLiveElapsed() {
        // WHY: background shells can run for minutes with an empty body — without a
        // live chip the row looks frozen even though the host is fine.
        let item = AssistantItem(
            id: "i", turnId: "t", type: .tool, state: .streaming,
            summary: "[bg] long job",
            body: #"{"command":"sleep 600","background":true}"#,
            startedAtMs: 1_000
        )
        XCTAssertTrue(AgentTimelineItemPresentation.showsLiveToolElapsed(for: item))
        XCTAssertNil(AgentTimelineItemPresentation.toolDurationLabel(for: item),
                     "without nowMs the pure helper must not invent a wall clock")
        XCTAssertEqual(
            AgentTimelineItemPresentation.toolDurationLabel(for: item, nowMs: 1_000 + 113_000),
            "1m 53s"
        )
        XCTAssertNil(
            AgentTimelineItemPresentation.toolDurationLabel(for: item, nowMs: 1_400),
            "sub-second live elapsed stays suppressed to avoid first-paint flicker"
        )
    }

    func test_taskWaitTool_liveStatusAndActivityHint() {
        // WHY: Get task output is the primary "looks stuck" surface — Waiting + hint
        // must work from task_ids payloads even when stdout is empty.
        let item = AssistantItem(
            id: "i", turnId: "t", type: .tool, state: .streaming,
            summary: "Get task output: call-3566c18b-b595-4299-91fe-088abdba8159-25",
            body: #"{"task_ids":[1],"timeout_ms":600000}"#,
            startedAtMs: 10_000
        )
        XCTAssertTrue(AgentTimelineItemPresentation.isTaskWaitTool(for: item))
        XCTAssertTrue(AgentTimelineItemPresentation.showsLiveToolElapsed(for: item))
        XCTAssertEqual(AgentTimelineItemPresentation.toolStreamingStatusLabel(for: item), "Waiting")
        XCTAssertEqual(
            AgentTimelineItemPresentation.make(for: item).verb, "Waiting",
            "L1 verb must match Waiting so the row never reads Running…Waiting"
        )
        XCTAssertEqual(
            AgentTimelineItemPresentation.toolActivityHint(for: item, hasOutput: false),
            "No output yet · background task still running"
        )
        XCTAssertNil(
            AgentTimelineItemPresentation.toolActivityHint(for: item, hasOutput: true),
            "once output arrives the empty-wait strip must hide"
        )
        XCTAssertEqual(
            AgentTimelineItemPresentation.toolDurationLabel(for: item, nowMs: 10_000 + 12_000),
            "12s"
        )
        XCTAssertTrue(AgentTimelineItemPresentation.toolCanExpandWithoutOutput(for: item))

        let a11y = AgentTimelineItemPresentation.toolAccessibilityLabel(for: item, nowMs: 10_000 + 12_000)
        XCTAssertTrue(a11y.localizedCaseInsensitiveContains("waiting"))
        XCTAssertTrue(a11y.contains("12s"))
        XCTAssertTrue(a11y.localizedCaseInsensitiveContains("no output yet"))
    }

    func test_taskWaitTool_completedDoesNotExpandOrClaimWaiting() {
        // WHY: dead chevron + VO "waiting" after a finished empty poll is a false liveness claim.
        let item = AssistantItem(
            id: "i", turnId: "t", type: .tool, state: .completed,
            summary: "Get task output",
            body: #"{"task_ids":[1],"timeout_ms":600000}"#,
            startedAtMs: 10_000, finishedAtMs: 40_000
        )
        XCTAssertTrue(AgentTimelineItemPresentation.isTaskWaitTool(for: item))
        XCTAssertFalse(AgentTimelineItemPresentation.showsLiveToolElapsed(for: item))
        XCTAssertFalse(AgentTimelineItemPresentation.toolCanExpandWithoutOutput(for: item))
        let a11y = AgentTimelineItemPresentation.toolAccessibilityLabel(for: item)
        XCTAssertFalse(
            a11y.localizedCaseInsensitiveContains("waiting for task output"),
            "completed task-wait must not keep the active-wait a11y fragment; got \(a11y)"
        )
        XCTAssertTrue(a11y.localizedCaseInsensitiveContains("ran"))
    }

    func test_isTaskWaitTool_doesNotMisclassifyShellWithTaskIdNoise() {
        let shell = toolItem(
            body: #"{"command":"echo hi","task_id":"x"}"#,
            summary: "Bash"
        )
        XCTAssertFalse(AgentTimelineItemPresentation.isTaskWaitTool(for: shell))
        XCTAssertEqual(AgentTimelineItemPresentation.toolStreamingStatusLabel(for: AssistantItem(
            id: "i", turnId: "t", type: .tool, state: .streaming,
            summary: "Bash", body: #"{"command":"echo"}"#, startedAtMs: 0
        )), "Running")
    }

    func test_isTaskWaitTool_classifiesClaudeBashOutput() {
        // WHY: Claude collects bg shell via BashOutput / bash_id — same freeze feel as Grok polls.
        let bySummary = AssistantItem(
            id: "i", turnId: "t", type: .tool, state: .streaming,
            summary: "BashOutput", body: #"{"bash_id":"b1"}"#, startedAtMs: 0
        )
        XCTAssertTrue(AgentTimelineItemPresentation.isTaskWaitTool(for: bySummary))
        XCTAssertTrue(AgentTimelineItemPresentation.showsLiveToolElapsed(for: bySummary))
        let byKey = AssistantItem(
            id: "j", turnId: "t", type: .tool, state: .streaming,
            summary: "Tool", body: #"{"bash_id":"abc-123"}"#, startedAtMs: 0
        )
        XCTAssertTrue(AgentTimelineItemPresentation.isTaskWaitTool(for: byKey))
        XCTAssertEqual(
            AgentTimelineItemPresentation.toolCommandPreview(for: byKey),
            "bash abc-123"
        )
    }

    func test_liveWaitToolsStayUngroupedSoPhaseAIsVisible() {
        // WHY: collapsed "Running 2 commands…" hides Waiting + elapsed; bg + Get task output
        // must stay inline so the freeze-fix UI mounts without expand.
        let bg = AssistantItem(
            id: "bg", turnId: "t", type: .tool, state: .completed,
            summary: "[bg] sleep", body: #"{"command":"sleep 600","background":true}"#,
            startedAtMs: 1_000, finishedAtMs: 1_100
        )
        let wait = AssistantItem(
            id: "wait", turnId: "t", type: .tool, state: .streaming,
            summary: "Get task output",
            body: #"{"task_ids":[1],"timeout_ms":600000}"#,
            startedAtMs: 1_200
        )
        XCTAssertTrue(AgentTimelineItemPresentation.mustKeepToolsUngrouped([bg, wait]))
        let blocks = AgentAppView.turnRenderBlocks([bg, wait])
        XCTAssertEqual(blocks.count, 2, "live wait pair must not fold into one group")
        XCTAssertFalse(isGroup(blocks[0]))
        XCTAssertFalse(isGroup(blocks[1]))
        XCTAssertEqual(AgentAppView.turnRenderBlockCount([bg, wait]), 2)

        // Ordinary completed burst still groups (density invariant).
        let ordinary = (0..<3).map {
            AssistantItem(
                id: "m\($0)", turnId: "t", type: .mcpToolCall, state: .completed,
                summary: "MCP", body: "{}", startedAtMs: 0, finishedAtMs: 1
            )
        }
        XCTAssertFalse(AgentTimelineItemPresentation.mustKeepToolsUngrouped(ordinary))
        XCTAssertEqual(AgentAppView.turnRenderBlocks(ordinary).count, 1)
        XCTAssertEqual(AgentAppView.turnRenderBlockCount(ordinary), 1)
    }

    func test_toolGroupSummary_usesWaitingWhenLiveTaskWaitPresent() {
        let wait = AssistantItem(
            id: "wait", turnId: "t", type: .tool, state: .streaming,
            summary: "Get task output",
            body: #"{"task_ids":[1]}"#,
            startedAtMs: 0
        )
        let other = AssistantItem(
            id: "x", turnId: "t", type: .tool, state: .completed,
            summary: "Bash", body: #"{"command":"echo"}"#,
            startedAtMs: 0, finishedAtMs: 1
        )
        XCTAssertEqual(
            AgentAppView.toolGroupSummary([other, wait]),
            "Waiting 2 commands…",
            "defense path if a group still contains a live wait"
        )
        XCTAssertEqual(AgentAppView.liveElapsedAnchor(in: [other, wait])?.id, "wait")
    }

    func test_toolDurationLabel_suppressesSubSecondFinished() {
        let item = AssistantItem(
            id: "i", turnId: "t", type: .tool, state: .completed,
            summary: "Bash", body: #"{"command":"ls"}"#,
            startedAtMs: 1_000, finishedAtMs: 1_400
        )
        XCTAssertNil(AgentTimelineItemPresentation.toolDurationLabel(for: item),
                     "0s walls from equal/near-equal timestamps must not clutter finished rows")
    }

    func test_toolAccessibilityLabel_includesStatusNameAndBackground() {
        let item = toolItem(
            body: #"{"command":"git status","background":true}"#,
            summary: "[bg] git status"
        )
        let label = AgentTimelineItemPresentation.toolAccessibilityLabel(for: item)
        XCTAssertTrue(label.localizedCaseInsensitiveContains("ran"))
        XCTAssertTrue(label.localizedCaseInsensitiveContains("background"))
        XCTAssertTrue(label.contains("git status") || label.localizedCaseInsensitiveContains("shell"))
    }

    func test_isBackgroundTool_fromRunInBackgroundFlag() {
        let item = toolItem(body: #"{"command":"echo hi","run_in_background":true}"#, summary: "Bash")
        XCTAssertTrue(AgentTimelineItemPresentation.isBackgroundTool(for: item))
        let fg = toolItem(body: #"{"command":"echo hi"}"#, summary: "Bash")
        XCTAssertFalse(AgentTimelineItemPresentation.isBackgroundTool(for: fg))
    }

    func test_summarizeShellishCommand_shortensHomePaths() {
        let home = NSHomeDirectory()
        let cmd = "swift test --package-path \(home)/dev/remote-code/macos-app"
        let summary = AgentTimelineItemPresentation.summarizeShellishCommand(cmd)
        XCTAssertTrue(summary.hasPrefix("swift test --package-path ~/"),
                      "home directory must collapse to ~ for density; got \(summary)")
        XCTAssertFalse(summary.contains(home))
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
        let collapsed = AgentAppView.computeTurnRenderInputs(
            turn: turn,
            persistedAssistantTexts: [],
            proposedPlans: [],
            running: true,
            expandCompletedWork: false
        )
        XCTAssertGreaterThan(collapsed.completedWorkBlockCount, 0,
                             "all live work counts toward Work so far (macOS↔iOS chat parity)")
        XCTAssertTrue(collapsed.completedWorkBlocks.isEmpty,
                      "collapsed live work must not materialize full blocks (PERF)")
        XCTAssertTrue(collapsed.visibleBlocks.isEmpty,
                      "live turns never paint tools outside Work so far")
        let expanded = AgentAppView.computeTurnRenderInputs(
            turn: turn,
            persistedAssistantTexts: [],
            proposedPlans: [],
            running: true,
            expandCompletedWork: true
        )
        XCTAssertFalse(expanded.completedWorkBlocks.isEmpty,
                       "expanded live work materializes disclosure body including active tail")
        XCTAssertEqual(expanded.completedWorkBlockCount, expanded.completedWorkBlocks.count)
        XCTAssertTrue(expanded.visibleBlocks.isEmpty,
                      "parity: no Ran N / tool rows outside Work so far while live")
        let workIds = expanded.completedWorkBlocks.flatMap { block -> [String] in
            switch block {
            case .item(let i): return [i.id]
            case .toolGroup(_, let group): return group.map(\.id)
            }
        }
        XCTAssertTrue(workIds.contains("now"), "streaming tool lives inside Work so far")
        XCTAssertTrue(workIds.contains("done-0"), "settled tools live inside Work so far")
        // Append-friendly second projection: pass prior expanded blocks so growth reuses identity.
        let priorItems = expanded.expandedWorkSourceItems
        let priorBlocks = expanded.completedWorkBlocks
        var more = items
        more.insert(
            AssistantItem(
                id: "done-extra", turnId: turnId, type: .commandExecution, state: .completed,
                summary: nil, body: "", startedAtMs: 1
            ),
            at: more.count - 1
        )
        let turn2 = AssistantTurnSnapshot(turnId: turnId, items: more.map { copy in
            AssistantItem(
                id: copy.id, turnId: turnId, type: copy.type, state: copy.state,
                summary: nil, body: "", startedAtMs: 1
            )
        })
        let expanded2 = AgentAppView.computeTurnRenderInputs(
            turn: turn2,
            persistedAssistantTexts: [],
            proposedPlans: [],
            running: true,
            expandCompletedWork: true,
            previousExpandedWorkItems: priorItems,
            previousExpandedWorkBlocks: priorBlocks
        )
        XCTAssertFalse(expanded2.completedWorkBlocks.isEmpty)
        let prevIds = priorBlocks.map(\.id)
        let nextIds = expanded2.completedWorkBlocks.map(\.id)
        let decision = AgentCompletedWorkBlockGrowth.growthDecision(
            previousItemIds: priorItems.map(\.id),
            previousBlockIds: prevIds,
            nextItemIds: expanded2.expandedWorkSourceItems.map(\.id),
            nextBlockIds: nextIds
        )
        // Insert-before-stream is not pure suffix growth; append path only requires
        // non-empty work blocks and stable disclosure (outside still empty).
        XCTAssertTrue(expanded2.visibleBlocks.isEmpty)
        XCTAssertGreaterThanOrEqual(
            expanded2.completedWorkBlockCount,
            expanded.completedWorkBlockCount,
            "extra settled tool increases Work so far step count"
        )
        _ = decision // growth mode depends on insert vs pure append
    }

    func test_turnRenderBlockCount_matchesTurnRenderBlocksCount() {
        // WHY: collapsed "Work so far" uses count-only grouping; it must agree
        // with the full block list so the label never lies about step count.
        let items: [AssistantItem] = (0..<5).map {
            AssistantItem(id: "c-\($0)", turnId: "t", type: .commandExecution,
                          state: .completed, body: "", startedAtMs: Int64($0))
        } + [
            AssistantItem(id: "r", turnId: "t", type: .reasoning, state: .completed,
                          body: "thought", startedAtMs: 10),
            AssistantItem(id: "t1", turnId: "t", type: .tool, state: .completed,
                          body: "", startedAtMs: 11),
            AssistantItem(id: "t2", turnId: "t", type: .tool, state: .completed,
                          body: "", startedAtMs: 12),
        ]
        XCTAssertEqual(
            AgentAppView.turnRenderBlockCount(items),
            AgentAppView.turnRenderBlocks(items).count,
            "count-only path must equal full grouping length"
        )
    }
}
