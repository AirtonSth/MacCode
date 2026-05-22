import Foundation
import AppKit
import WebKit
import CoreModel

@MainActor
public final class MarkdownSurface: NSObject, Surface {
    private nonisolated static let maxMarkdownBytes = 512 * 1024

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let webView: WKWebView
    public private(set) var filePath: String?

    public init(workspaceID: WorkspaceID, filePath: String?, title: String = "markdown") {
        self.descriptor = SurfaceDescriptor(
            type: .markdown,
            title: title,
            iconName: "doc.text",
            metadata: ["workspace": workspaceID.value.uuidString, "path": filePath ?? ""]
        )
        self.filePath = filePath
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = false
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        self.view = container

        super.init()
        loadAndRender()
    }

    public func load(filePath: String) {
        self.filePath = filePath
        descriptor.metadata["path"] = filePath
        loadAndRender()
    }

    private func loadAndRender() {
        let body = Self.loadMarkdownBody(filePath: filePath)
        let html = Self.renderHTML(markdown: body)
        webView.loadHTMLString(html, baseURL: filePath.flatMap { URL(fileURLWithPath: $0).deletingLastPathComponent() })
    }

    static func loadMarkdownBody(filePath: String?, maxBytes: Int = MarkdownSurface.maxMarkdownBytes) -> String {
        guard let path = filePath,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return "# Markdown Preview\n\nNo file loaded."
        }
        defer { try? handle.close() }
        let limit = max(1, maxBytes)
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        let clipped = Data(data.prefix(limit))
        guard var body = String(data: clipped, encoding: .utf8) else {
            return "# Markdown Preview\n\nUnable to render this file as UTF-8 markdown."
        }
        if data.count > limit {
            body += "\n\n---\n\n_Preview truncated after \(limit) bytes._"
        }
        return body
    }

    /// Minimal Markdown -> HTML translator. Handles headings, code fences,
    /// inline code, bold, italic, lists, paragraphs, links, hr. Good
    /// enough for in-app preview of READMEs; not CommonMark-complete.
    public static func renderHTML(markdown: String) -> String {
        var body = ""
        var inFence = false
        var fenceLang = ""
        var fenceBuf: [String] = []
        var inList = false

        func closeList() {
            if inList { body += "</ul>\n"; inList = false }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine
            if inFence {
                if line.hasPrefix("```") {
                    body += "<pre><code class=\"lang-\(fenceLang)\">" + escape(fenceBuf.joined(separator: "\n")) + "</code></pre>\n"
                    inFence = false; fenceBuf.removeAll(); fenceLang = ""
                } else {
                    fenceBuf.append(line)
                }
                continue
            }
            if line.hasPrefix("```") {
                closeList()
                inFence = true
                fenceLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { closeList(); continue }
            if trimmed == "---" || trimmed == "***" { closeList(); body += "<hr/>\n"; continue }
            if let h = headingLevel(line) {
                closeList()
                let content = inlineMD(String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces))
                body += "<h\(h)>\(content)</h\(h)>\n"
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !inList { body += "<ul>\n"; inList = true }
                let item = inlineMD(String(line.dropFirst(2)))
                body += "<li>\(item)</li>\n"
                continue
            }
            closeList()
            body += "<p>\(inlineMD(line))</p>\n"
        }
        if inFence {
            body += "<pre><code class=\"lang-\(fenceLang)\">" + escape(fenceBuf.joined(separator: "\n")) + "</code></pre>\n"
        }
        closeList()

        let css = """
        body { font: 14px -apple-system, system-ui; color: #e7edf3; background: #0f1419; padding: 24px; max-width: 820px; margin: 0 auto; }
        h1 { font-size: 28px; border-bottom: 1px solid #2a3440; padding-bottom: 8px; }
        h2 { font-size: 22px; border-bottom: 1px solid #2a3440; padding-bottom: 4px; }
        h3 { font-size: 18px; }
        pre { background: #0a0e13; border: 1px solid #2a3440; border-radius: 6px; padding: 12px; overflow: auto; }
        code { background: #1a1f26; padding: 1px 5px; border-radius: 4px; font-family: ui-monospace, "SF Mono", Menlo, monospace; }
        a { color: #7cc7ff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        ul { padding-left: 22px; }
        hr { border: 0; border-top: 1px solid #2a3440; margin: 22px 0; }
        """
        return "<!doctype html><html><head><meta charset=\"utf-8\"><style>\(css)</style></head><body>\(body)</body></html>"
    }

    private static func headingLevel(_ line: String) -> Int? {
        var n = 0
        for ch in line { if ch == "#" { n += 1 } else { break } }
        if n >= 1 && n <= 6 { return n }
        return nil
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inlineMD(_ s: String) -> String {
        var t = escape(s)
        // links [text](url)
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) {
            let nsRange = NSRange(t.startIndex..<t.endIndex, in: t)
            t = regex.stringByReplacingMatches(in: t, range: nsRange, withTemplate: "<a href=\"$2\">$1</a>")
        }
        // bold **x** then italic *x* then inline code `x`
        if let regex = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#) {
            let nsRange = NSRange(t.startIndex..<t.endIndex, in: t)
            t = regex.stringByReplacingMatches(in: t, range: nsRange, withTemplate: "<strong>$1</strong>")
        }
        if let regex = try? NSRegularExpression(pattern: #"\*([^*]+)\*"#) {
            let nsRange = NSRange(t.startIndex..<t.endIndex, in: t)
            t = regex.stringByReplacingMatches(in: t, range: nsRange, withTemplate: "<em>$1</em>")
        }
        if let regex = try? NSRegularExpression(pattern: "`([^`]+)`") {
            let nsRange = NSRange(t.startIndex..<t.endIndex, in: t)
            t = regex.stringByReplacingMatches(in: t, range: nsRange, withTemplate: "<code>$1</code>")
        }
        return t
    }

    public func focus() { view.window?.makeFirstResponder(webView) }
    public func unfocus() {}
    public func close() {}
    public func sendText(_ text: String) {}
    public func readText() -> String { filePath ?? "" }
    public func snapshot() -> [String: String] { ["path": filePath ?? ""] }
}
