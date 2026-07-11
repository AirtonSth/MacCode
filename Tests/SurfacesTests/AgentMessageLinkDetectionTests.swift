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
}
