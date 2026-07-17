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
}
