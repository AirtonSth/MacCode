import XCTest
import GhosttyKit
@testable import Surfaces

/// Tests for TerminalLinkClassifier and the GHOSTTY_ACTION_OPEN_URL mapper path.
///
/// WHY these tests matter:
/// - Ghostty detects hyperlinks (OSC 8, URL-shaped tokens) and fires
///   GHOSTTY_ACTION_OPEN_URL on Cmd+click. The embedder previously returned `true`
///   without doing anything, silently swallowing the action — Cmd+click on a URL
///   in the terminal had no effect.
/// - The classifier is the boundary that decides whether a token opens in the
///   browser (http/https) or routes to the in-app FilePreview surface (absolute
///   file paths). Getting this wrong routes URLs to the wrong destination or
///   activates on plain words.
/// - Relative paths are explicitly NOT classified as file paths: Ghostty never
///   generates relative paths in open_url actions (it resolves them against the
///   terminal's cwd before firing the action), so treating them as filePaths
///   would silently route garbage into FilePreview.
///
/// No @MainActor needed: TerminalLinkClassifier is a pure nonisolated enum and
/// GhosttyActionMapper.map is nonisolated static. Neither touches AppKit views.
final class TerminalLinkClassifierTests: XCTestCase {

    // MARK: - TerminalLinkClassifier.classify

    func test_httpURL_producesURLResult() {
        // http:// links must open in the default browser via NSWorkspace.open.
        // If we returned .none the user's Cmd+click would silently do nothing.
        let result = TerminalLinkClassifier.classify("http://example.com/path?q=1")
        guard case .url(let url) = result else {
            XCTFail("http:// token must classify as .url, not \(result)")
            return
        }
        XCTAssertEqual(url.absoluteString, "http://example.com/path?q=1",
            "classified URL must preserve the full string including query params")
    }

    func test_httpsURL_producesURLResult() {
        // https:// is the dominant scheme for web links shown in terminal output.
        // It must map to .url so it routes to NSWorkspace.open, not FilePreview.
        let result = TerminalLinkClassifier.classify("https://github.com/foo/bar")
        guard case .url(let url) = result else {
            XCTFail("https:// token must classify as .url, not \(result)")
            return
        }
        XCTAssertEqual(url.absoluteString, "https://github.com/foo/bar",
            "classified URL must preserve the exact https string")
    }

    func test_absoluteFilePath_producesFilePathResult() {
        // Absolute POSIX paths (starting with /) that appear in error output,
        // compiler diagnostics, or file listings must route to FilePreview.
        // A wrong mapping (e.g. .none) means the user's Cmd+click silently fails.
        let result = TerminalLinkClassifier.classify("/Users/sam/project/Sources/Foo.swift")
        guard case .filePath(let path) = result else {
            XCTFail("absolute file path must classify as .filePath, not \(result)")
            return
        }
        XCTAssertEqual(path, "/Users/sam/project/Sources/Foo.swift",
            "classified file path must preserve the exact path string")
    }

    func test_absoluteFilePathWithColon_producesFilePathResult() {
        // Compiler diagnostics often include line:col after the path,
        // e.g. /path/to/File.swift:42:10. Ghostty strips the coordinates before
        // firing open_url, so we receive only the path; this test guards that
        // a bare path with no trailing context still classifies correctly.
        let result = TerminalLinkClassifier.classify("/tmp/build/output.log")
        guard case .filePath = result else {
            XCTFail("absolute path /tmp/... must classify as .filePath, not \(result)")
            return
        }
    }

    func test_plainWord_producesNone() {
        // Plain words appear constantly in terminal output; treating them as
        // links would open browser/FilePreview on random text.
        let result = TerminalLinkClassifier.classify("hello")
        guard case .none = result else {
            XCTFail("plain word must classify as .none, not \(result)")
            return
        }
    }

    func test_emptyString_producesNone() {
        // Ghostty may pass an empty url pointer; the mapper converts nil pointers
        // to empty string. An empty token must never trigger an action.
        let result = TerminalLinkClassifier.classify("")
        guard case .none = result else {
            XCTFail("empty string must classify as .none")
            return
        }
    }

    func test_relativePathDotSlash_producesNone() {
        // Ghostty resolves paths against the terminal cwd before firing open_url,
        // so a relative path in a classify call is not a genuine Ghostty-generated
        // token. We must NOT route it to FilePreview to avoid activating on
        // ./foo-shaped plain tokens in command output.
        let result = TerminalLinkClassifier.classify("./relative/path")
        guard case .none = result else {
            XCTFail("relative path must classify as .none — Ghostty only fires open_url with absolute paths")
            return
        }
    }

    func test_fileSchemeURL_producesFilePathResult() {
        // Ghostty may fire a file:// URL for OSC 8 links that point to local files.
        // These must route to FilePreview, not the browser.
        let result = TerminalLinkClassifier.classify("file:///Users/sam/doc.txt")
        guard case .filePath(let path) = result else {
            XCTFail("file:// URL must classify as .filePath (routed to FilePreview), not \(result)")
            return
        }
        XCTAssertEqual(path, "/Users/sam/doc.txt",
            "file:// URL must yield the extracted POSIX path, not the raw file:// string")
    }

    // MARK: - GhosttyActionMapper — GHOSTTY_ACTION_OPEN_URL

    func test_openURL_httpToken_producesOpenURLEffect() {
        // The mapper must extract the url field from open_url and classify it.
        // Returning nil here means Cmd+click on http links silently does nothing.
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_OPEN_URL
        "https://swift.org".withCString { ptr in
            var openURL = ghostty_action_open_url_s()
            openURL.url = ptr
            openURL.kind = GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
            action.action = ghostty_action_u()
            action.action.open_url = openURL
            guard case .openURL(let url) = GhosttyActionMapper.map(action) else {
                XCTFail("GHOSTTY_ACTION_OPEN_URL with https token must produce .openURL effect")
                return
            }
            XCTAssertEqual(url.absoluteString, "https://swift.org",
                "openURL effect must carry the exact URL")
        }
    }

    func test_openURL_absolutePathToken_producesOpenFilePathEffect() {
        // When Ghostty fires open_url for a file path (e.g. from OSC 8 with a
        // file:// link or a compiler diagnostic path), it must route to FilePreview.
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_OPEN_URL
        "/Users/sam/proj/main.swift".withCString { ptr in
            var openURL = ghostty_action_open_url_s()
            openURL.url = ptr
            openURL.kind = GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
            action.action = ghostty_action_u()
            action.action.open_url = openURL
            guard case .openFilePath(let path) = GhosttyActionMapper.map(action) else {
                XCTFail("GHOSTTY_ACTION_OPEN_URL with absolute path must produce .openFilePath effect")
                return
            }
            XCTAssertEqual(path, "/Users/sam/proj/main.swift",
                "openFilePath effect must carry the exact path string")
        }
    }

    func test_openURL_nilURLPointer_producesNil() {
        // A nil url field in the open_url struct (defensive: Ghostty should never
        // do this, but we must not crash if it does). Returning nil causes the
        // dispatcher to return true without side-effects.
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_OPEN_URL
        var openURL = ghostty_action_open_url_s()
        openURL.url = nil
        openURL.kind = GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
        action.action = ghostty_action_u()
        action.action.open_url = openURL
        XCTAssertNil(GhosttyActionMapper.map(action),
            "nil url pointer in open_url must produce nil — must not crash or produce a garbage effect")
    }

    func test_openURL_plainWordToken_producesNil() {
        // If Ghostty fires open_url for a token that is neither a URL nor an
        // absolute path (should not happen in practice), the mapper must produce
        // nil so nothing unexpected opens.
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_OPEN_URL
        "notaurl".withCString { ptr in
            var openURL = ghostty_action_open_url_s()
            openURL.url = ptr
            openURL.kind = GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
            action.action = ghostty_action_u()
            action.action.open_url = openURL
            XCTAssertNil(GhosttyActionMapper.map(action),
                "plain-word token in open_url must produce nil (no-op), not crash or open garbage")
        }
    }
}
