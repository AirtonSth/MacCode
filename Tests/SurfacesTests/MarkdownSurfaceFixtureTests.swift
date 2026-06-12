import XCTest
@testable import Surfaces

// WHY (todo-QA line 105): two fixture categories that the existing test
// coverage does not exercise:
//   T052 — a multibyte UTF-8 character that straddles the 512 KB truncation
//           boundary must not cause a broken Unicode scalar, a crash, or
//           corrupted output.
//   T053 — a raw <script> injection in a markdown file must be neutralized
//           (HTML-escaped) by renderHTML so the script is never executed in
//           the WKWebView, closing the stored-XSS surface.
//
// Both tests use programmatically constructed inputs to guarantee
// reproducibility without fixture files on disk.

final class MarkdownSurfaceFixtureTests: XCTestCase {

    // The cap is private but its value (512 * 1024) is the contract; tests
    // construct inputs relative to this constant so they stay correct if the
    // cap changes.
    private let cap = 512 * 1024

    // MARK: - T052: multibyte char straddling the 512 KB cap

    /// WHY: loadMarkdownBody clips at maxBytes using Data.prefix, which is a
    /// byte-level operation. If a multi-byte UTF-8 character straddles the
    /// boundary the last byte(s) of that character are dropped, and
    /// String(data:encoding:) returns nil — the function must fall back
    /// gracefully rather than returning nil/crashing or emitting a broken
    /// partial scalar.
    ///
    /// This test constructs a payload of exactly (cap - 1) ASCII bytes followed
    /// by a 2-byte UTF-8 character (U+00E9, 0xC3 0xA9). After prefix(cap), only
    /// the first byte of the 2-byte sequence is retained, making the Data
    /// invalid UTF-8. The function must still return a non-empty, valid String.
    func test_T052_multibyteCharStraddle_noCrashNoPartialScalar() throws {
        // Build a temp file whose content straddles the cap.
        // Content: (cap - 1) ASCII "a" bytes + U+00E9 (2 bytes) = cap+1 bytes total.
        // After prefix(cap): (cap - 1) "a" + 0xC3 only — invalid UTF-8.
        let padding = Data(repeating: UInt8(ascii: "a"), count: cap - 1)
        let twoByteChar = Data([0xC3, 0xA9]) // U+00E9 LATIN SMALL LETTER E WITH ACUTE
        let fileContent = padding + twoByteChar

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-t052-\(UUID().uuidString).md")
        try fileContent.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let body = MarkdownSurface.loadMarkdownBody(filePath: tmpURL.path)

        // Must return a non-empty string — no crash, no nil propagation.
        XCTAssertFalse(body.isEmpty,
            "T052: loadMarkdownBody must return a non-empty result when a multibyte char straddles the cap")

        // Must not contain a partial UTF-8 replacement character from a broken scalar.
        XCTAssertFalse(body.contains("\u{FFFD}"),
            "T052: broken scalar at cap boundary must not produce a replacement character in the output")

        // The returned string must be valid Swift/Unicode (iterating scalars
        // would crash on an invalid String, but Swift's String is always valid —
        // we verify no fatalError occurs during iteration).
        var scalarCount = 0
        for _ in body.unicodeScalars { scalarCount += 1 }
        XCTAssertGreaterThan(scalarCount, 0,
            "T052: output must have at least one valid Unicode scalar")

        // When String(data:encoding:.utf8) returns nil the function emits a
        // safe fallback message; that message starts with '#' (heading).
        // Either way the output must be a valid, printable, non-empty string.
        let firstChar = body.unicodeScalars.first?.value ?? 0
        XCTAssertGreaterThan(firstChar, 0x20,
            "T052: output must begin with a visible character whether it is content or the fallback message")
    }

    /// WHY: when the multibyte char falls exactly at the cap (all bytes fit),
    /// there must be no truncation warning and the char must appear in output.
    /// This is the exact-fit sibling of T052.
    func test_T052_multibyteCharExactlyAtCap_noTruncationWarning() throws {
        // Content: (cap - 2) "a" bytes + U+00E9 (2 bytes) = cap bytes total.
        // prefix(cap) retains the full 2-byte sequence — valid UTF-8.
        let padding = Data(repeating: UInt8(ascii: "a"), count: cap - 2)
        let twoByteChar = Data([0xC3, 0xA9]) // U+00E9
        let fileContent = padding + twoByteChar

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-t052b-\(UUID().uuidString).md")
        try fileContent.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let body = MarkdownSurface.loadMarkdownBody(filePath: tmpURL.path)

        // File fits exactly in cap — no truncation banner.
        XCTAssertFalse(body.contains("Preview truncated"),
            "T052: file at exactly cap bytes must not show truncation warning")

        // The 2-byte char must appear in the body.
        XCTAssertTrue(body.hasSuffix("\u{00E9}") || body.contains("\u{00E9}"),
            "T052: multibyte char that fits within cap must appear unmodified in output")
    }

    // MARK: - T053: HTML / script injection neutralized

    /// WHY: MarkdownSurface.renderHTML passes markdown through inlineMD, which
    /// calls escape() to HTML-encode &, <, and >. A raw <script> tag in the
    /// markdown must therefore be rendered as the literal text &lt;script&gt;
    /// rather than an executable HTML element. If it ever appeared unescaped,
    /// the WKWebView would execute the injected script — a stored-XSS
    /// vulnerability for any markdown file from an untrusted repo.
    func test_T053_scriptTagInMarkdown_isEscapedNotExecuted() {
        let injection = "<script>alert('XSS')</script>"
        let markdown = "# Safe file\n\nSome text with \(injection) injected."

        let html = MarkdownSurface.renderHTML(markdown: markdown)

        // The literal <script> tag must NOT appear as a raw HTML element.
        XCTAssertFalse(html.contains("<script>alert"),
            "T053: raw <script> injection in markdown must not reach WKWebView as an executable element")

        // The text must appear HTML-escaped so the user can see it as text.
        XCTAssertTrue(html.contains("&lt;script&gt;"),
            "T053: injected <script> must be HTML-escaped to &lt;script&gt; to neutralize execution")
    }

    /// WHY: img onerror and other event-handler injection vectors must also be
    /// escaped. This covers the <img onerror=...> pattern used to bypass naive
    /// script-only filters.
    func test_T053_imgOnerrorInjection_isEscaped() {
        let injection = "<img src=x onerror=\"alert(1)\">"
        let markdown = "Look at this image: \(injection)"

        let html = MarkdownSurface.renderHTML(markdown: markdown)

        XCTAssertFalse(html.contains("<img src=x onerror"),
            "T053: <img onerror> injection must not reach HTML unescaped")
        XCTAssertTrue(html.contains("&lt;img"),
            "T053: injected <img> must be HTML-escaped to neutralize onerror handler")
    }

    /// WHY: an injection inside a code fence uses escape() directly (not
    /// inlineMD). Verify that code-fence content is also safe.
    func test_T053_scriptInCodeFence_isEscaped() {
        let markdown = "```\n<script>evil()</script>\n```"

        let html = MarkdownSurface.renderHTML(markdown: markdown)

        XCTAssertFalse(html.contains("<script>evil"),
            "T053: <script> inside a code fence must be HTML-escaped by escape()")
        XCTAssertTrue(html.contains("&lt;script&gt;evil()&lt;/script&gt;"),
            "T053: code fence must HTML-escape angle brackets so the script is inert")
    }

    /// WHY: an & ampersand in markdown must not double-encode when round-tripped.
    /// escape() converts & -> &amp;; inlineMD must not re-encode that. This
    /// is a correctness fixture, not a security fixture, but it lives here
    /// because it exercises the same escape() path as T053.
    func test_T053_ampersandInMarkdown_encodedOnce() {
        let markdown = "Tom & Jerry"

        let html = MarkdownSurface.renderHTML(markdown: markdown)

        XCTAssertTrue(html.contains("Tom &amp; Jerry"),
            "& must be encoded to &amp; exactly once (not double-encoded to &amp;amp;)")
        XCTAssertFalse(html.contains("&amp;amp;"),
            "double-encoding of & is incorrect and breaks user-visible text")
    }
}
