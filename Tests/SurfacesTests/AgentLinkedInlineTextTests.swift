import XCTest
import AppKit
@testable import Surfaces
import DesignSystemKit

/// WHY: Split-opening transcript links must show the pointing-hand cursor.
/// SwiftUI `Text` + textSelection never does; we convert AttributedString runs
/// into NSAttributedString and assert every link carries `NSCursor.pointingHand`.
final class AgentLinkedInlineTextTests: XCTestCase {

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

    /// WHY: live RemoteCode sample (pid 30891) spent the main thread in
    /// LazyVStackLayout + AgentLinkedInlineTextRepresentable while RSS grew
    /// to 16 GB. `layout()` must not invalidate; SwiftUI already asks
    /// `sizeThatFits` for the proposed width.
    func test_layout_doesNotInvalidateIntrinsicSizeOnceWidthHasSettled() {
        let tv = IntrinsicHeightTextView(usingTextLayoutManager: false)
        tv.string = String(repeating: "word ", count: 80)
        tv.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        tv.layoutSubtreeIfNeeded()
        let afterFirstPass = tv.intrinsicInvalidationCountForTesting
        for _ in 0..<20 {
            tv.frame.size.width = 240
            tv.layout()
        }
        tv.frame.size.width = 241
        tv.layout()
        tv.frame.size.width = 239
        tv.layout()
        XCTAssertEqual(
            tv.intrinsicInvalidationCountForTesting,
            afterFirstPass,
            "layout() must never invalidate intrinsic size; that retriggers LazyVStack placement"
        )
        let fitted = tv.sizeThatFitsWidth(240)
        XCTAssertGreaterThan(
            fitted.height,
            0,
            "sizeThatFits must still report a concrete wrapped height for the proposed width"
        )
    }

    /// WHY: live freeze pid 65678 spent the entire 8s sample on the main thread
    /// in LazyVStackLayout.sizeThatFits → AgentLinkedInlineText. SwiftUI proposes
    /// the column width while the NSView frame is still the previous estimate.
    /// Measuring against bounds (widthTracksTextView / reentrant layout()) reports
    /// height-for-240 as height-for-400 and placement never settles.
    func test_sizeThatFits_usesProposedWidthEvenWhenFrameIsNarrower() {
        let tv = IntrinsicHeightTextView(usingTextLayoutManager: false)
        tv.string = String(repeating: "wrapping word ", count: 60)
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.textContainer?.widthTracksTextView = true
        tv.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        tv.layoutSubtreeIfNeeded()
        let heightAt240 = tv.sizeThatFitsWidth(240).height
        let heightAt400 = tv.sizeThatFitsWidth(400).height
        XCTAssertGreaterThan(
            heightAt240,
            heightAt400,
            "narrower width must wrap to a taller block"
        )
        XCTAssertEqual(
            tv.sizeThatFitsWidth(400).height,
            heightAt400,
            "repeated proposed-width measurement must stay stable"
        )
    }

    func test_intrinsicContentSize_reusesMeasuredHeightWhenBoundsAreEmpty() {
        let tv = IntrinsicHeightTextView(usingTextLayoutManager: false)
        tv.string = String(repeating: "wrapping word ", count: 60)
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.frame = .zero
        let fitted = tv.sizeThatFitsWidth(240)
        XCTAssertGreaterThan(fitted.height, tv.font!.boundingRectForFont.height)
        XCTAssertEqual(
            tv.intrinsicContentSize.height,
            fitted.height,
            "empty bounds must not remeasure at an unconstrained fallback width"
        )
    }

    /// WHY: AgentSelectablePlainText is the AppKit replacement for SwiftUI
    /// `.textSelection(.enabled)`. Callers (BotsWindow compiled payload) pass
    /// `monospaced: true`; that flag must map to the same NSFont as AppKit's
    /// monospaced system face, not a proportional system font.
    func test_nsFont_monospacedTrue_equalsMonospacedSystemFont() {
        let size: CGFloat = 11
        let weight = NSFont.Weight.regular
        XCTAssertEqual(
            AgentLinkedInlineText.nsFont(size: size, weight: weight, monospaced: true),
            NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        )
        XCTAssertEqual(
            AgentLinkedInlineText.nsFont(size: size, weight: weight, monospaced: false),
            NSFont.systemFont(ofSize: size, weight: weight)
        )
    }

    /// WHY: AgentChatUserBubble hugs short prompts. After SelectionOverlay,
    /// `sizeThatFits` treated unspecified / 0 / infinite proposals as width 0,
    /// so "Go to my linear" painted as a 2-glyph column ("Go" / "Gr").
    func test_sizeThatFitsProposal_unspecifiedHugsInsteadOfCollapsingToZero() {
        let tv = IntrinsicHeightTextView(usingTextLayoutManager: false)
        tv.string = "Go to my linear"
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.frame = .zero
        let ideal = tv.sizeThatFitsIdeal()
        XCTAssertGreaterThan(
            ideal.width,
            80,
            "hug width must fit the prompt on one line, not a 2-glyph column"
        )
        XCTAssertLessThan(ideal.width, 240)
        XCTAssertEqual(tv.sizeThatFitsProposal(width: nil).width, ideal.width, accuracy: 0.5)
        XCTAssertEqual(tv.sizeThatFitsProposal(width: 0).width, ideal.width, accuracy: 0.5)
        XCTAssertEqual(
            tv.sizeThatFitsProposal(width: CGFloat.infinity).width,
            ideal.width,
            accuracy: 0.5
        )
        XCTAssertEqual(
            IntrinsicHeightTextView.idealSize(
                string: "Go to my linear",
                font: NSFont.systemFont(ofSize: 13)
            ).width,
            ideal.width,
            accuracy: 1.5,
            "static measurer must match the live NSTextView hug"
        )
    }

    func test_sizeThatFitsIdeal_doesNotPoisonWrapCache() {
        let tv = IntrinsicHeightTextView(usingTextLayoutManager: false)
        tv.string = String(repeating: "wrapping word ", count: 60)
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        let wrap = tv.sizeThatFitsWidth(240)
        let invalidations = tv.intrinsicInvalidationCountForTesting
        let ideal = tv.sizeThatFitsIdeal()
        XCTAssertLessThan(
            ideal.width,
            10_000,
            "hug must be glyph width, not the 10_000pt probe or extra line fragment"
        )
        XCTAssertGreaterThan(ideal.width, 1_000)
        XCTAssertGreaterThan(
            ideal.width,
            wrap.width,
            "unwrapped hug must be wider than the 240pt column wrap"
        )
        XCTAssertLessThan(ideal.height, wrap.height)
        XCTAssertEqual(
            tv.sizeThatFitsWidth(240).height,
            wrap.height,
            accuracy: 0.5,
            "hug measurement must not replace the wrap cache with the 10_000pt probe"
        )
        XCTAssertEqual(
            tv.intrinsicInvalidationCountForTesting,
            invalidations,
            "hug measurement must not invalidate intrinsic size"
        )
    }

    func test_sizeThatFits_sameWidthDoesNotInvalidateIntrinsicSize() {
        let tv = IntrinsicHeightTextView(usingTextLayoutManager: false)
        tv.string = String(repeating: "word ", count: 80)
        tv.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        _ = tv.sizeThatFitsWidth(240)
        let afterMeasure = tv.intrinsicInvalidationCountForTesting
        for _ in 0..<20 {
            _ = tv.sizeThatFitsWidth(240)
        }
        XCTAssertEqual(
            tv.intrinsicInvalidationCountForTesting,
            afterMeasure,
            "settled-width sizeThatFits must not dirty intrinsic size"
        )
    }
}
