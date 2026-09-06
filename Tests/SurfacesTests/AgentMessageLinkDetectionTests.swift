import AppKit
import DesignSystemKit
import SwiftUI
import XCTest
@testable import Surfaces

/// UX-MAC_AGENT-OPEN-SPLIT: file mentions and URLs in transcript prose become
/// tappable links (file mentions via the custom scheme, resolved at click time).
/// These tests pin what must — and must NOT — be linkified: a false positive
/// turns ordinary prose into dead links; a false negative hides the feature.
final class AgentMessageLinkDetectionTests: XCTestCase {
    private func links(in text: String) -> [(text: String, url: URL)] {
        let attributed = AgentMessageMarkdown.attributedInline(text)
        return attributed.runs.compactMap { run in
            guard let url = run.link else { return nil }
            return (String(attributed.characters[run.range]), url)
        }
    }

    private func filePaths(in text: String) -> [String] {
        links(in: text).compactMap { AgentMessageMarkdown.filePath(fromFileLink: $0.url) }
    }

    // MARK: URLs

    func test_bareHTTPURL_becomesTappableLink() {
        let found = links(in: "Docs at https://example.com/guide?x=1 explain it.")
        XCTAssertEqual(found.map(\.url.absoluteString), ["https://example.com/guide?x=1"],
                       "a pasted URL must be clickable — users expect it to open the browser split")
    }

    func test_wwwAndLocalhost_getSchemesSoTheLinkIsLoadable() {
        // Foundation's markdown autolink claims "www." tokens first (http scheme);
        // author/parser-provided links are preserved, not rewritten — what matters
        // is that the token is clickable with a loadable URL.
        XCTAssertEqual(links(in: "see www.example.com now").first?.url.host, "www.example.com")
        XCTAssertEqual(links(in: "dev server on localhost:3000/app").first?.url.absoluteString, "http://localhost:3000/app",
                       "dev-server URLs are the #1 agent-mentioned link in this app's domain")
    }

    func test_trailingSentencePunctuation_isNotPartOfTheURL() {
        XCTAssertEqual(links(in: "Open https://example.com/a.").first?.url.absoluteString, "https://example.com/a")
        XCTAssertEqual(links(in: "(see https://example.com/b)").first?.url.absoluteString, "https://example.com/b")
    }

    func test_markdownAuthoredLink_isPreservedNotRewritten() {
        let found = links(in: "see [the docs](https://example.com/docs)")
        XCTAssertEqual(found.map(\.url.absoluteString), ["https://example.com/docs"],
                       "explicit markdown links must keep their author-chosen target")
    }

    func test_fileURL_routesThroughTheFileScheme() {
        let paths = filePaths(in: "open file:///tmp/report.html now")
        XCTAssertEqual(paths, ["/tmp/report.html"],
                       "file:// URLs are file mentions — they must open the Files split, not a browser")
    }

    // MARK: file paths

    func test_pathShapes_becomeFileLinks() {
        XCTAssertEqual(filePaths(in: "fixed in Sources/CoreModel/Reducer.swift today"), ["Sources/CoreModel/Reducer.swift"])
        XCTAssertEqual(filePaths(in: "log at /var/log/system.log rotated"), ["/var/log/system.log"])
        XCTAssertEqual(filePaths(in: "config in ~/.zshrc works"), ["~/.zshrc"])
        XCTAssertEqual(filePaths(in: "run ./scripts/build.sh first"), ["./scripts/build.sh"])
    }

    func test_lineSuffix_staysInTheRawTokenForClickTimeStripping() {
        XCTAssertEqual(filePaths(in: "crash at Sources/App/Main.swift:42:7 in init"), ["Sources/App/Main.swift:42:7"],
                       "line refs must stay clickable; resolution strips the suffix later")
    }

    func test_inlineCodeBareFilename_isAFileLink_butProseBareFilenameIsNot() {
        XCTAssertEqual(filePaths(in: "edit `Package.swift` to add it"), ["Package.swift"],
                       "a backticked filename is an unambiguous file mention")
        XCTAssertEqual(filePaths(in: "the Package.swift manifest"), [],
                       "bare filenames in prose are too ambiguous — linking them everywhere makes text noisy")
    }

    func test_ordinaryProseWithSlashes_isNotLinkified() {
        for text in ["either/or choices", "the I/O layer", "a 50/50 split", "TCP/IP stack"] {
            XCTAssertEqual(links(in: text).count, 0, "'\(text)' is prose, not a path — a dead link here erodes trust in all links")
        }
    }

    func test_plainDomainInProse_isNotAWebLink() {
        XCTAssertTrue(links(in: "the anthropic.com launch").isEmpty,
                      "bare domains without a scheme/www are too ambiguous with file names (config.dev, setup.sh)")
    }

    // MARK: scheme round-trip

    func test_fileLinkURL_roundTripsArbitraryPaths() {
        for raw in ["Sources/App/Main.swift:42", "~/Library/App Support/x.db", "./a b/c.txt", "/tmp/x.log"] {
            let url = AgentMessageMarkdown.fileLinkURL(for: raw)
            XCTAssertNotNil(url)
            XCTAssertEqual(AgentMessageMarkdown.filePath(fromFileLink: url!), raw,
                           "the click handler must receive the exact detected token (spaces, colons and all)")
        }
    }

    func test_foreignScheme_isNotAFileLink() {
        XCTAssertNil(AgentMessageMarkdown.filePath(fromFileLink: URL(string: "https://example.com?path=/etc/passwd")!),
                     "only the custom scheme may carry file mentions — web URLs must never be interpreted as local paths")
    }

    // MARK: UTF-16 / emoji index conversion

    /// WHY: NSRange is UTF-16. A cursor that walks Character vs UTF-16 must still
    /// land on the same token when a scalar (emoji) precedes the match; dropping
    /// or shifting the link here would be a silent detection-semantic change.
    func test_urlAndPathAfterEmoji_keepTheSameTokens() {
        XCTAssertEqual(
            links(in: "see 🎉 https://example.com/guide now").map(\.url.absoluteString),
            ["https://example.com/guide"]
        )
        XCTAssertEqual(
            filePaths(in: "fixed 👩‍💻 in Sources/CoreModel/Reducer.swift today"),
            ["Sources/CoreModel/Reducer.swift"]
        )
        XCTAssertEqual(
            filePaths(in: "edit `Package.swift` after 🎉"),
            ["Package.swift"]
        )
    }

    /// WHY: `applyingDetectedLinks` round-trips the whole value through AppKit
    /// `NSAttributedString`. Link counts alone do not prove inline-code
    /// font/background or authored-link runs survive that bridge.
    func test_applyingDetectedLinks_preservesInlineCodeAndAuthoredLinks_andLinksUnicodePrefixedMatch() throws {
        let markdown = "see [the docs](https://example.com/docs) and `Package.swift` plus **bold** 🎉 https://example.com/guide"
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var source = try AttributedString(markdown: markdown, options: options)
        let codeRanges = source.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        XCTAssertFalse(codeRanges.isEmpty, "fixture must include an inline-code run to style")
        for range in codeRanges {
            source[range].font = DS.Font.monoSmall
            source[range].backgroundColor = DS.Palette.surfaceOverlay
            source[range].foregroundColor = DS.Palette.accent
        }

        func runText(_ value: AttributedString, _ run: AttributedString.Runs.Run) -> String {
            String(value.characters[run.range])
        }
        let beforeCode = try XCTUnwrap(source.runs.first {
            $0.inlinePresentationIntent?.contains(.code) == true && runText(source, $0) == "Package.swift"
        })
        XCTAssertEqual(beforeCode.font, DS.Font.monoSmall)
        XCTAssertEqual(beforeCode.backgroundColor, DS.Palette.surfaceOverlay)
        let beforeAuthored = try XCTUnwrap(source.runs.first {
            $0.link?.absoluteString == "https://example.com/docs"
        })
        let beforeBold = source.runs.first {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && runText(source, $0) == "bold"
        }

        let after = AgentMessageMarkdown.applyingDetectedLinks(to: source)
        let afterCode = try XCTUnwrap(after.runs.first {
            $0.inlinePresentationIntent?.contains(.code) == true && runText(after, $0) == "Package.swift"
        })
        XCTAssertEqual(afterCode.font, beforeCode.font, "inline-code font must survive the NSAttributedString round-trip")
        XCTAssertEqual(
            afterCode.backgroundColor,
            beforeCode.backgroundColor,
            "inline-code background must survive the round-trip"
        )
        XCTAssertEqual(
            after.runs.first { $0.link?.absoluteString == "https://example.com/docs" }?.link,
            beforeAuthored.link,
            "authored markdown links must keep their author-chosen target"
        )
        if let beforeBold {
            XCTAssertTrue(
                after.runs.contains {
                    $0.inlinePresentationIntent == beforeBold.inlinePresentationIntent
                        && runText(after, $0) == "bold"
                },
                "unrelated styled runs such as bold must survive the round-trip"
            )
        }
        XCTAssertEqual(
            after.runs.compactMap(\.link).compactMap(AgentMessageMarkdown.filePath(fromFileLink:)).first { $0 == "Package.swift" },
            "Package.swift"
        )

        let rendered = AgentLinkedInlineTextRepresentable.makeNSAttributedString(
            attributed: after,
            font: .systemFont(ofSize: 13),
            textColor: DS.NS.text,
            lineSpacing: 0
        )
        func link(at token: String) -> URL? {
            let range = (rendered.string as NSString).range(of: token)
            guard range.location != NSNotFound else { return nil }
            return rendered.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        }
        XCTAssertEqual(link(at: "the docs")?.absoluteString, "https://example.com/docs")
        XCTAssertEqual(link(at: "https://example.com/guide")?.absoluteString, "https://example.com/guide")
        XCTAssertEqual(
            AgentMessageMarkdown.filePath(fromFileLink: try XCTUnwrap(link(at: "Package.swift"))),
            "Package.swift"
        )
    }
}
