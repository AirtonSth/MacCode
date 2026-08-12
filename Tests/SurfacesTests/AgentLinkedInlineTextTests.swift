import XCTest
import AppKit
@testable import Surfaces
import DesignSystemKit

/// WHY: Split-opening transcript links must show the pointing-hand cursor.
/// SwiftUI `Text` + textSelection never does; we convert AttributedString runs
/// into NSAttributedString and assert every link carries `NSCursor.pointingHand`.
final class AgentLinkedInlineTextTests: XCTestCase {

    /// WHY: This is the smallest reproducible proxy for the reported hang. It
    /// keeps one linked transcript cell at a stable width, warms the AppKit
    /// text system, and repeats the exact intrinsic-size query that SwiftUI
    /// asks while placing a stable row. It is intentionally labelled a CPU
    /// layout proxy; it does not claim first-paint or end-to-end UI latency.
    @MainActor
    func test_intrinsicHeightCacheBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RC2_INLINE_TEXT_BENCHMARK"] == "1",
            "benchmark is opt-in; set RC2_INLINE_TEXT_BENCHMARK=1"
        )

        let textView = IntrinsicHeightTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 360, height: 500)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude)
        let attributed = AgentLinkedInlineTextRepresentable.makeNSAttributedString(
            attributed: AgentMessageMarkdown.attributedInline(
                String(repeating: "Stable linked transcript content with `Package.swift` and https://example.com/docs. ", count: 8)
            ),
            font: .systemFont(ofSize: 13),
            textColor: DS.NS.text,
            lineSpacing: 2
        )
        AgentLinkedInlineTextRepresentable.applyTextStorage(attributed, to: textView)
        textView.layoutSubtreeIfNeeded()

        let queryCount = 16_384
        func measuredBatch() -> Int {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<queryCount {
                _ = textView.intrinsicContentSize
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            return max(1, Int((elapsed + 999_999) / 1_000_000))
        }

        _ = measuredBatch()
        _ = measuredBatch()
        var samples: [[String: Int]] = []
        for _ in 0..<7 {
            textView.invalidateIntrinsicContentSize()
            let settled = measuredBatch()
            samples.append([
                "feedback_ms": settled,
                "meaningful_ms": settled,
                "settled_ms": settled,
                "dead_time_ms": 0,
                "query_count": queryCount,
            ])
        }
        let sortedSettled = samples.compactMap { $0["settled_ms"] }.sorted()
        let median = sortedSettled[sortedSettled.count / 2]
        let payload: [String: Any] = [
            "fixture": "intrinsic_height_cpu_layout_proxy",
            "width": 360,
            "warmup_samples": 2,
            "query_count_per_sample": queryCount,
            "samples": samples,
            "feedback_ms": median,
            "meaningful_ms": median,
            "settled_ms": median,
            "dead_time_ms": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print("AGENT_LINKED_INLINE_BENCHMARK \(String(decoding: data, as: UTF8.self))")
    }

    func test_makeNSAttributedString_appliesPointingHandOnFileLinks() {
        let attributed = AgentMessageMarkdown.attributedInline(
            "Changed files — backend: `plan-proposal.service.ts` and Sources/App/Main.swift today"
        )
        let ns = AgentLinkedInlineTextRepresentable.makeNSAttributedString(
            attributed: attributed,
            font: .systemFont(ofSize: 13),
            textColor: DS.NS.text,
            lineSpacing: 5
        )
        var linkRanges = 0
        var handRanges = 0
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length), options: []) { attrs, _, _ in
            guard attrs[.link] != nil else { return }
            linkRanges += 1
            if attrs[.cursor] as? NSCursor === NSCursor.pointingHand
                || (attrs[.cursor] as? NSCursor) == NSCursor.pointingHand {
                handRanges += 1
            }
        }
        XCTAssertGreaterThan(linkRanges, 0, "sample text must produce at least one file link")
        XCTAssertEqual(
            linkRanges, handRanges,
            "every NSLink run must carry pointingHand so hover matches open-in-split affordance"
        )
    }

    func test_makeNSAttributedString_appliesPointingHandOnHTTPLinks() {
        let attributed = AgentMessageMarkdown.attributedInline("see https://example.com/docs for details")
        let ns = AgentLinkedInlineTextRepresentable.makeNSAttributedString(
            attributed: attributed,
            font: .systemFont(ofSize: 13),
            textColor: DS.NS.text,
            lineSpacing: 0
        )
        var found = false
        ns.enumerateAttribute(.link, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
            guard value != nil else { return }
            found = true
            let cursor = ns.attribute(.cursor, at: range.location, effectiveRange: nil) as? NSCursor
            XCTAssertEqual(cursor, NSCursor.pointingHand)
        }
        XCTAssertTrue(found)
    }

    func test_fileLinkSchemeStillResolvableAfterNSConversion() {
        let attributed = AgentMessageMarkdown.attributedInline("open `Package.swift` please")
        let ns = AgentLinkedInlineTextRepresentable.makeNSAttributedString(
            attributed: attributed,
            font: .systemFont(ofSize: 13),
            textColor: DS.NS.text,
            lineSpacing: 0
        )
        var resolved: String?
        ns.enumerateAttribute(.link, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
            guard let url = value as? URL else { return }
            resolved = AgentMessageMarkdown.filePath(fromFileLink: url)
        }
        XCTAssertEqual(resolved, "Package.swift",
                       "click routing still needs remotecode-file query path after AppKit conversion")
    }

    func test_applyTextStorage_preservesMultilineSelectionForIdenticalContent() {
        let textView = IntrinsicHeightTextView(usingTextLayoutManager: false)
        let value = NSAttributedString(string: "first line\nsecond line\nthird line")
        AgentLinkedInlineTextRepresentable.applyTextStorage(value, to: textView)
        textView.setSelectedRange(NSRange(location: 0, length: value.length))

        AgentLinkedInlineTextRepresentable.applyTextStorage(value, to: textView)

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: value.length),
                       "routine SwiftUI updates with unchanged text must not collapse an in-progress multiline transcript selection")
    }

    /// WHY: Stable transcript rows can receive many intrinsic-size queries
    /// during a parent refresh. Equal content and width must reuse the exact
    /// measured height instead of re-entering TextKit layout.
    @MainActor
    func test_intrinsicHeight_repeatedQueryUsesCacheAndPreservesExactHeight() {
        let textView = IntrinsicHeightTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 220, height: 400)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 220,
            height: CGFloat.greatestFiniteMagnitude
        )
        let value = AgentLinkedInlineTextRepresentable.makeNSAttributedString(
            attributed: AgentMessageMarkdown.attributedInline(
                "Stable row with `Package.swift` and https://example.com/docs."
            ),
            font: .systemFont(ofSize: 13),
            textColor: DS.NS.text,
            lineSpacing: 2
        )
        AgentLinkedInlineTextRepresentable.applyTextStorage(value, to: textView)
        textView.layoutSubtreeIfNeeded()

        let first = textView.intrinsicContentSize
        let computations = textView.intrinsicHeightComputationCount
        let second = textView.intrinsicContentSize

        XCTAssertEqual(second, first, "cached intrinsic size must preserve exact height and width semantics")
        XCTAssertEqual(
            textView.intrinsicHeightComputationCount,
            computations,
            "a stable content+width query must not repeat TextKit layout computation"
        )
    }

    /// WHY: SwiftUI proposed 220.00 ↔ 220.25 during the 2026-08-12 hang.
    /// Evicting intrinsic height on that jitter re-enters AttributeGraph.
    func test_containerWidthPolicy_ignoresSubpixelJitterAndCommitsWholePoints() {
        XCTAssertFalse(
            IntrinsicHeightTextView.shouldInvalidateContainerWidth(current: 220, proposed: 220.25),
            "subpixel proposals must not invalidate intrinsic height"
        )
        XCTAssertFalse(
            IntrinsicHeightTextView.shouldInvalidateContainerWidth(current: 220, proposed: 219.6),
            "rounding back to the committed point must be a no-op"
        )
        XCTAssertTrue(
            IntrinsicHeightTextView.shouldInvalidateContainerWidth(current: 220, proposed: 222),
            "a real whole-point wrap change must still evict"
        )
        XCTAssertTrue(
            IntrinsicHeightTextView.shouldInvalidateContainerWidth(current: 0, proposed: 220),
            "first layout must accept a positive width"
        )
    }

    @MainActor
    func test_intrinsicHeight_wholePointWidthChangeRecomputesHeight() {
        let textView = IntrinsicHeightTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 220, height: 400)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 220,
            height: CGFloat.greatestFiniteMagnitude
        )
        let value = AgentLinkedInlineTextRepresentable.makeNSAttributedString(
            attributed: AgentMessageMarkdown.attributedInline(
                "A stable row with enough words to make width-sensitive wrapping observable."
            ),
            font: .systemFont(ofSize: 13),
            textColor: DS.NS.text,
            lineSpacing: 2
        )
        AgentLinkedInlineTextRepresentable.applyTextStorage(value, to: textView)
        textView.layoutSubtreeIfNeeded()
        _ = textView.intrinsicContentSize

        textView.setFrameSize(NSSize(width: 220.25, height: 400))
        textView.layout()
        _ = textView.intrinsicContentSize
        let afterSubpixel = textView.intrinsicHeightComputationCount
        textView.layout()
        _ = textView.intrinsicContentSize
        XCTAssertEqual(
            textView.intrinsicHeightComputationCount,
            afterSubpixel,
            "repeated subpixel layout must not keep invalidating intrinsic height"
        )

        textView.setFrameSize(NSSize(width: 248, height: 400))
        textView.layout()
        _ = textView.intrinsicContentSize
        XCTAssertGreaterThan(
            textView.intrinsicHeightComputationCount,
            afterSubpixel,
            "a whole-point width change must evict the cached height"
        )
    }

    /// WHY: Width, content, typography, line limits, and padding are all
    /// height inputs. Each change must evict the cache while preserving the
    /// existing selection/link conversion contract.
    @MainActor
    func test_intrinsicHeight_changesEvictCacheAndKeepSelectionAndLinks() {
        let textView = IntrinsicHeightTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 180, height: 400)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 180,
            height: CGFloat.greatestFiniteMagnitude
        )
        let firstValue = AgentLinkedInlineTextRepresentable.makeNSAttributedString(
            attributed: AgentMessageMarkdown.attributedInline(
                "First row with `Package.swift` and https://example.com/docs."
            ),
            font: .systemFont(ofSize: 13),
            textColor: DS.NS.text,
            lineSpacing: 2
        )
        AgentLinkedInlineTextRepresentable.applyTextStorage(firstValue, to: textView)
        textView.layoutSubtreeIfNeeded()
        _ = textView.intrinsicContentSize
        let firstComputations = textView.intrinsicHeightComputationCount

        textView.setFrameSize(NSSize(width: 280, height: 400))
        textView.layoutSubtreeIfNeeded()
        _ = textView.intrinsicContentSize
        XCTAssertGreaterThan(textView.intrinsicHeightComputationCount, firstComputations)

        let selected = NSRange(location: 0, length: min(5, firstValue.length))
        textView.setSelectedRange(selected)
        let secondValue = AgentLinkedInlineTextRepresentable.makeNSAttributedString(
            attributed: AgentMessageMarkdown.attributedInline(
                "Updated row with `Sources/App/Main.swift` and https://example.com/updated."
            ),
            font: .systemFont(ofSize: 15),
            textColor: DS.NS.text,
            lineSpacing: 4
        )
        AgentLinkedInlineTextRepresentable.applyTextStorage(secondValue, to: textView)
        textView.font = .systemFont(ofSize: 15)
        textView.textContainer?.maximumNumberOfLines = 2
        textView.textContainer?.lineFragmentPadding = 4
        textView.invalidateIntrinsicContentSize()
        _ = textView.intrinsicContentSize

        XCTAssertEqual(textView.selectedRange(), selected, "content replacement must preserve selection bounds")
        XCTAssertGreaterThan(textView.intrinsicHeightComputationCount, firstComputations + 1)
        var links = 0
        secondValue.enumerateAttribute(.link, in: NSRange(location: 0, length: secondValue.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        XCTAssertGreaterThan(links, 0, "cache invalidation must not remove converted links")
    }


    // MARK: - Update plan (skip redundant AppKit rebuilds)

    /// WHY: Parent transcript refreshes re-enter updateNSView for every mounted
    /// row while one message streams. Equal attributed + typography must be a
    /// no-op so stable history rows do not rebuild NSAttributedString on the
    /// main thread (observed freeze: AgentLinkedInlineTextRepresentable.apply).
    func test_updatePlan_equalIndependentlyConstructedPresentation_isNoOp() {
        let font = NSFont.systemFont(ofSize: 13)
        let color = DS.NS.text
        let a = AgentLinkedInlineTextAppliedState(
            attributed: AttributedString("stable history row with `Package.swift`"),
            font: font,
            textColor: color,
            lineSpacing: 5,
            maximumNumberOfLines: nil,
            lineFragmentPadding: 0
        )
        let b = AgentLinkedInlineTextAppliedState(
            attributed: AttributedString("stable history row with `Package.swift`"),
            font: NSFont.systemFont(ofSize: 13),
            textColor: color,
            lineSpacing: 5,
            maximumNumberOfLines: nil,
            lineFragmentPadding: 0
        )
        let plan = AgentLinkedInlineTextUpdatePlan.make(previous: a, next: b)
        XCTAssertTrue(plan.isNoOp, "semantically equal rows must skip conversion and layout")
        XCTAssertFalse(plan.storageDirty)
        XCTAssertFalse(plan.heightDirty)
    }

    /// WHY: `selectableProse` rebuilds AttributedString on every parent body
    /// pass. If independently constructed results compare unequal, apply()
    /// rebuilds NSAttributedString for every mounted row and invalidates
    /// intrinsic height — the observed AgentLinkedInlineTextRepresentable.apply freeze.
    func test_updatePlan_equalIndependentlyConstructedMarkdownProse_isNoOp() {
        let source = "See `Package.swift` and https://example.com/docs for the wrap path."
        let font = NSFont.systemFont(ofSize: 13)
        let color = DS.NS.text
        let blocks = AgentMessageMarkdown.blocks(from: source)
        let first = AgentMessageMarkdown.selectableProse(from: blocks, compact: false)
        let second = AgentMessageMarkdown.selectableProse(from: blocks, compact: false)
        let plan = AgentLinkedInlineTextUpdatePlan.make(
            previous: AgentLinkedInlineTextAppliedState(
                attributed: first,
                font: font,
                textColor: color,
                lineSpacing: 5,
                maximumNumberOfLines: nil,
                lineFragmentPadding: 0
            ),
            next: AgentLinkedInlineTextAppliedState(
                attributed: second,
                font: font,
                textColor: color,
                lineSpacing: 5,
                maximumNumberOfLines: nil,
                lineFragmentPadding: 0
            )
        )
        XCTAssertTrue(
            plan.isNoOp,
            "markdown prose rebuilt from the same blocks must skip NSTextView storage/layout"
        )
    }

    func test_updatePlan_sameCharactersDifferentLinkDestination_marksStorageDirty() {
        var first = AttributedString("docs")
        first.link = URL(string: "https://example.com/a")
        var second = AttributedString("docs")
        second.link = URL(string: "https://example.com/b")
        let font = NSFont.systemFont(ofSize: 13)
        let previous = AgentLinkedInlineTextAppliedState(
            attributed: first,
            font: font,
            textColor: DS.NS.text,
            lineSpacing: 0,
            maximumNumberOfLines: nil,
            lineFragmentPadding: 0
        )
        let next = AgentLinkedInlineTextAppliedState(
            attributed: second,
            font: font,
            textColor: DS.NS.text,
            lineSpacing: 0,
            maximumNumberOfLines: nil,
            lineFragmentPadding: 0
        )
        let plan = AgentLinkedInlineTextUpdatePlan.make(previous: previous, next: next)
        XCTAssertTrue(plan.storageDirty,
                      "plain-string fingerprints are insufficient; link URL changes must rebuild storage")
        XCTAssertTrue(plan.heightDirty,
                      "attributed changes conservatively invalidate height (runs may affect metrics)")
    }

    func test_updatePlan_streamingAppend_marksStorageAndHeightDirty() {
        let font = NSFont.systemFont(ofSize: 13)
        let previous = AgentLinkedInlineTextAppliedState(
            attributed: AttributedString("Hello"),
            font: font,
            textColor: DS.NS.text,
            lineSpacing: 5,
            maximumNumberOfLines: nil,
            lineFragmentPadding: 0
        )
        let next = AgentLinkedInlineTextAppliedState(
            attributed: AttributedString("Hello world"),
            font: font,
            textColor: DS.NS.text,
            lineSpacing: 5,
            maximumNumberOfLines: nil,
            lineFragmentPadding: 0
        )
        let plan = AgentLinkedInlineTextUpdatePlan.make(previous: previous, next: next)
        XCTAssertTrue(plan.storageDirty)
        XCTAssertTrue(plan.heightDirty)
        XCTAssertFalse(plan.isNoOp)
    }

    func test_updatePlan_colorOnly_storageDirtyWithoutHeight() {
        let font = NSFont.systemFont(ofSize: 13)
        let previous = AgentLinkedInlineTextAppliedState(
            attributed: AttributedString("palette swap"),
            font: font,
            textColor: DS.NS.text,
            lineSpacing: 5,
            maximumNumberOfLines: nil,
            lineFragmentPadding: 0
        )
        let next = AgentLinkedInlineTextAppliedState(
            attributed: AttributedString("palette swap"),
            font: font,
            textColor: DS.NS.textSecondary,
            lineSpacing: 5,
            maximumNumberOfLines: nil,
            lineFragmentPadding: 0
        )
        let plan = AgentLinkedInlineTextUpdatePlan.make(previous: previous, next: next)
        XCTAssertTrue(plan.storageDirty, "color-only must restyle storage")
        XCTAssertFalse(plan.heightDirty, "color-only must not force intrinsic height invalidation")
    }

    func test_updatePlan_fontLineSpacingMaxLinesPadding_driveExpectedFlags() {
        let base = AgentLinkedInlineTextAppliedState(
            attributed: AttributedString("metrics"),
            font: NSFont.systemFont(ofSize: 13),
            textColor: DS.NS.text,
            lineSpacing: 5,
            maximumNumberOfLines: nil,
            lineFragmentPadding: 0
        )

        let fontPlan = AgentLinkedInlineTextUpdatePlan.make(
            previous: base,
            next: AgentLinkedInlineTextAppliedState(
                attributed: base.attributed,
                font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                textColor: base.textColor,
                lineSpacing: base.lineSpacing,
                maximumNumberOfLines: base.maximumNumberOfLines,
                lineFragmentPadding: base.lineFragmentPadding
            )
        )
        XCTAssertTrue(fontPlan.storageDirty && fontPlan.heightDirty)

        let spacingPlan = AgentLinkedInlineTextUpdatePlan.make(
            previous: base,
            next: AgentLinkedInlineTextAppliedState(
                attributed: base.attributed,
                font: base.font,
                textColor: base.textColor,
                lineSpacing: 8,
                maximumNumberOfLines: base.maximumNumberOfLines,
                lineFragmentPadding: base.lineFragmentPadding
            )
        )
        XCTAssertTrue(spacingPlan.storageDirty && spacingPlan.heightDirty)

        let maxLinesPlan = AgentLinkedInlineTextUpdatePlan.make(
            previous: base,
            next: AgentLinkedInlineTextAppliedState(
                attributed: base.attributed,
                font: base.font,
                textColor: base.textColor,
                lineSpacing: base.lineSpacing,
                maximumNumberOfLines: 2,
                lineFragmentPadding: base.lineFragmentPadding
            )
        )
        XCTAssertFalse(maxLinesPlan.storageDirty)
        XCTAssertTrue(maxLinesPlan.heightDirty)
        XCTAssertTrue(maxLinesPlan.maximumNumberOfLinesDirty)

        let paddingPlan = AgentLinkedInlineTextUpdatePlan.make(
            previous: base,
            next: AgentLinkedInlineTextAppliedState(
                attributed: base.attributed,
                font: base.font,
                textColor: base.textColor,
                lineSpacing: base.lineSpacing,
                maximumNumberOfLines: base.maximumNumberOfLines,
                lineFragmentPadding: 4
            )
        )
        XCTAssertFalse(paddingPlan.storageDirty)
        XCTAssertTrue(paddingPlan.heightDirty)
        XCTAssertTrue(paddingPlan.lineFragmentPaddingDirty)
    }

    func test_updatePlan_nilPrevious_isFullyDirty() {
        let next = AgentLinkedInlineTextAppliedState(
            attributed: AttributedString("first mount"),
            font: NSFont.systemFont(ofSize: 13),
            textColor: DS.NS.text,
            lineSpacing: 0,
            maximumNumberOfLines: nil,
            lineFragmentPadding: 0
        )
        let plan = AgentLinkedInlineTextUpdatePlan.make(previous: nil, next: next)
        XCTAssertTrue(plan.storageDirty)
        XCTAssertTrue(plan.heightDirty)
        XCTAssertTrue(plan.maximumNumberOfLinesDirty)
        XCTAssertTrue(plan.lineFragmentPaddingDirty)
    }
}
