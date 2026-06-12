import Foundation
import AppKit
import ImageIO
import Quartz
import CoreModel

// Pure text-content cache -- no AppKit deps; safe to test without a display.
// Caches the UTF-8 string result of previewText(path:) keyed by absolute file path
// to avoid re-running up to 512KB FileHandle reads on every didBecomeVisible.
public struct FilePreviewTextCache {
    private var store: [String: String] = [:]

    public init() {}

    public mutating func store(path: String, text: String) {
        store[path] = text
    }

    public func text(for path: String) -> String? {
        store[path]
    }

    public mutating func evict(path: String) {
        store.removeValue(forKey: path)
    }

    /// Pure helper: returns true when cachedPath differs from newPath (reload required).
    /// Nonisolated -- touches no AppKit state; callable from any context.
    public nonisolated static func shouldReload(cachedPath: String?, newPath: String) -> Bool {
        cachedPath != newPath
    }
}

// PDF-document cache -- keyed by absolute file path.
// PDFDocument is a reference type and not Equatable; stored separately from the text cache.
// Avoids re-running PDFDocument(url:) (synchronous disk parse) on every didBecomeVisible.
public final class FilePreviewPDFCache {
    private var store: [String: PDFDocument] = [:]

    public init() {}

    public func store(path: String, document: PDFDocument) {
        store[path] = document
    }

    public func document(for path: String) -> PDFDocument? {
        store[path]
    }

    public func evict(path: String) {
        store.removeValue(forKey: path)
    }
}

// Pure scroll/page cache -- no AppKit deps; safe to test without a display.
// Keyed by absolute file path. Scroll offset is a Y-axis CGFloat (points from top).
// PDF page is a zero-based Int. Unknown key returns (offset: 0, page: 0).
public struct FilePreviewScrollCache {
    public struct Entry: Equatable {
        public var scrollOffsetY: CGFloat
        public var pdfPageIndex: Int
        public init(scrollOffsetY: CGFloat = 0, pdfPageIndex: Int = 0) {
            self.scrollOffsetY = scrollOffsetY
            self.pdfPageIndex = pdfPageIndex
        }
    }

    private var store: [String: Entry] = [:]

    public init() {}

    public mutating func store(path: String, entry: Entry) {
        store[path] = entry
    }

    public func entry(for path: String) -> Entry {
        store[path] ?? Entry()
    }
}

// Render strategy for a given file extension.
// .native  - handled by a first-class renderer (image / PDF / text).
// .quicklook - no native renderer; fall back to QLPreviewView.
public enum FileRenderStrategy: Equatable {
    case native
    case quicklook
}

@MainActor
public final class FilePreviewSurface: NSObject, Surface {
    private nonisolated static let maxTextPreviewBytes = 512 * 1024

    /// Pure helper: decide render strategy from a lowercased file extension.
    /// Never touches AppKit state; safe to call from any isolation context.
    public nonisolated static func renderStrategy(for ext: String) -> FileRenderStrategy {
        let lowered = ext.lowercased()
        let nativeExts: Set<String> = [
            "png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp",
            "pdf",
            "txt", "md", "swift", "py", "js", "ts", "json", "yaml", "yml",
            "sh", "bash", "zsh", "rb", "go", "rs", "c", "cpp", "h", "hpp",
            "java", "kt", "cs", "html", "css", "xml", "toml", "ini", "cfg",
            "log", "gitignore", "env"
        ]
        return nativeExts.contains(lowered) ? .native : .quicklook
    }

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public private(set) var filePath: String?
    private let containerStack: NSView
    private var isVisible = true
    var scrollCache = FilePreviewScrollCache()
    var textCache = FilePreviewTextCache()
    let pdfCache = FilePreviewPDFCache()

    public init(workspaceID: WorkspaceID, filePath: String?, title: String = "preview") {
        self.descriptor = SurfaceDescriptor(
            type: .filePreview,
            title: title,
            iconName: "doc",
            metadata: ["workspace": workspaceID.value.uuidString, "path": filePath ?? ""]
        )
        self.filePath = filePath
        let stack = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.containerStack = stack
        self.view = stack
        super.init()
        renderForFile(filePath)
    }

    public func load(filePath: String) {
        self.filePath = filePath
        descriptor.metadata["path"] = filePath
        renderForFile(filePath)
    }

    private func renderForFile(_ path: String?) {
        guard isVisible else { return }
        for sub in containerStack.subviews { sub.removeFromSuperview() }
        guard let p = path else {
            let label = NSTextField(labelWithString: "No file selected")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .secondaryLabelColor
            // a11y identifier so UI automation and VoiceOver can locate the
            // placeholder (P3 empty-state a11y).
            label.setAccessibilityIdentifier("filePreview.empty")
            label.setAccessibilityLabel("No file selected")
            containerStack.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: containerStack.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: containerStack.centerYAnchor)
            ])
            return
        }
        let ext = (p as NSString).pathExtension.lowercased()
        switch Self.renderStrategy(for: ext) {
        case .quicklook:
            renderQuickLook(path: p)
        case .native:
            if ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp"].contains(ext) {
                renderImage(path: p)
            } else if ext == "pdf" {
                renderPDF(path: p)
            } else {
                renderText(path: p)
            }
        }
    }

    private func renderImage(path: String) {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.setAccessibilityIdentifier("filePreview.image")
        containerStack.addSubview(iv)
        pin(iv)
        // Decode off the main thread into a downsampled image rather than synchronously
        // decoding the full-resolution NSImage on the RPC/main path (PERF-MAC_FILES-005).
        let url = URL(fileURLWithPath: path)
        Task { [weak self, weak iv] in
            let image = await Task.detached(priority: .userInitiated) {
                Self.decodeDownsampled(url: url)
            }.value
            guard let self, self.filePath == path else { return }
            iv?.image = image
        }
    }

    private nonisolated static func decodeDownsampled(url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func renderPDF(path: String) {
        let pdf = PDFView()
        pdf.autoScales = true
        pdf.translatesAutoresizingMaskIntoConstraints = false
        pdf.setAccessibilityIdentifier("filePreview.pdf")
        containerStack.addSubview(pdf)
        pin(pdf)
        let saved = scrollCache.entry(for: path)
        let url = URL(fileURLWithPath: path)

        // Load PDFDocument off the main thread to avoid blocking the render path
        // (PERF: PDFDocument(url:) reads/parses the PDF file synchronously).
        // Re-use cached result if this path was already loaded.
        if let cached = pdfCache.document(for: path) {
            // Cache hit -- apply document immediately on main (no I/O).
            pdf.document = cached
            Self.applyPDFScrollRestore(pdf: pdf, doc: cached, saved: saved)
        } else {
            Task { [weak self, weak pdf] in
                let doc = await Task.detached(priority: .userInitiated) {
                    PDFDocument(url: url)
                }.value
                guard let self, self.filePath == path, let pdf else { return }
                if let doc {
                    self.pdfCache.store(path: path, document: doc)
                    pdf.document = doc
                    Self.applyPDFScrollRestore(pdf: pdf, doc: doc, saved: saved)
                } else {
                    // PDFDocument(url:) returned nil — show an error state instead
                    // of leaving a silently blank pane (P2 PDF-nil error state).
                    self.showPDFError(over: pdf)
                }
            }
        }
    }

    /// Overlay a simple error label on `pdfView` when the PDF fails to load.
    private func showPDFError(over pdfView: NSView) {
        let label = NSTextField(labelWithString: "Unable to load PDF")
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("filePreview.pdfError")
        pdfView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor)
        ])
    }

    @MainActor
    private static func applyPDFScrollRestore(pdf: PDFView, doc: PDFDocument?, saved: FilePreviewScrollCache.Entry) {
        guard saved.pdfPageIndex > 0,
              let doc,
              saved.pdfPageIndex < doc.pageCount,
              let page = doc.page(at: saved.pdfPageIndex) else { return }
        pdf.go(to: page)
    }

    private func renderText(path: String) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let tv = NSTextView()
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = .init(width: 8, height: 8)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        // Native Cmd+F find within the preview text via NSTextView's built-in find bar
        // (IMP-MAC_FILES-001). Selectable read-only text still supports find/search.
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.setAccessibilityIdentifier("filePreview.text")
        scroll.documentView = tv
        // Line-number ruler: mirrors the Files editor gutter pattern.
        // PreviewLineNumberRulerView is a read-only NSRulerView subclass defined below.
        let ruler = PreviewLineNumberRulerView(textView: tv)
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = ruler
        scroll.rulersVisible = true
        containerStack.addSubview(scroll)
        pin(scroll)
        let saved = scrollCache.entry(for: path)

        // Load text bytes off the main thread to avoid blocking the render path
        // (PERF: previewText reads up to 512KB synchronously via FileHandle).
        // Re-use cached result if this path was already loaded.
        if let cached = textCache.text(for: path) {
            // Cache hit -- apply text immediately on main (no I/O).
            tv.string = cached
            Self.applyTextScrollRestore(scroll: scroll, saved: saved)
        } else {
            Task { [weak self, weak tv, weak scroll] in
                let text = await Task.detached(priority: .userInitiated) {
                    Self.previewText(path: path)
                }.value
                guard let self, self.filePath == path, let tv, let scroll else { return }
                self.textCache.store(path: path, text: text)
                tv.string = text
                Self.applyTextScrollRestore(scroll: scroll, saved: saved)
            }
        }
    }

    @MainActor
    private static func applyTextScrollRestore(scroll: NSScrollView, saved: FilePreviewScrollCache.Entry) {
        guard saved.scrollOffsetY != 0 else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: saved.scrollOffsetY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Pure helper: count 1-based lines in `text`.
    /// A completely empty string has 1 line. A trailing newline adds one phantom empty line.
    /// Nonisolated -- no AppKit; callable from any isolation context or test.
    public nonisolated static func lineCount(for text: String) -> Int {
        if text.isEmpty { return 1 }
        var n = 1
        for c in text.utf16 where c == 0x0A { n += 1 }
        return n
    }

    /// Pure helper: return the 1-based line number that contains `charOffset` (UTF-16 offset).
    /// Scans the UTF-16 code units up to `charOffset` and counts newlines.
    /// Returns 1 for any offset in an empty string or when offset <= 0.
    /// Nonisolated -- no AppKit; callable from any isolation context or test.
    public nonisolated static func lineNumber(forCharacterOffset charOffset: Int, in text: String) -> Int {
        guard charOffset > 0 else { return 1 }
        let ns = text as NSString
        let length = min(charOffset, ns.length)
        var line = 1
        var i = 0
        while i < length {
            if ns.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        return line
    }

    nonisolated static func previewText(path: String, maxBytes: Int = FilePreviewSurface.maxTextPreviewBytes) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return "[unable to read file]"
        }
        defer { try? handle.close() }
        let limit = max(1, maxBytes)
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        let clipped = Data(data.prefix(limit))
        if var content = String(data: clipped, encoding: .utf8) {
            if data.count > limit {
                content += "\n\n[preview truncated after \(limit) bytes]"
            }
            return content
        }
        let suffix = data.count > limit ? "at least " : ""
        return "[binary file, \(suffix)\(data.count) bytes]"
    }

    private func renderQuickLook(path: String) {
        let ql = QLPreviewView()
        ql.previewItem = URL(fileURLWithPath: path) as QLPreviewItem
        ql.autostarts = true
        ql.translatesAutoresizingMaskIntoConstraints = false
        ql.setAccessibilityIdentifier("filePreview.quicklook")
        containerStack.addSubview(ql)
        pin(ql)
    }

    private func pin(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: containerStack.topAnchor),
            v.bottomAnchor.constraint(equalTo: containerStack.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: containerStack.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: containerStack.trailingAnchor)
        ])
    }

    public func focus() { view.window?.makeFirstResponder(view) }
    public func unfocus() {}
    public func didBecomeVisible() {
        guard !isVisible else { return }
        isVisible = true
        renderForFile(filePath)
    }
    public func didBecomeHidden() {
        guard isVisible else { return }
        isVisible = false
        if let path = filePath {
            var entry = FilePreviewScrollCache.Entry()
            for sub in containerStack.subviews {
                if let scroll = sub as? NSScrollView {
                    entry.scrollOffsetY = scroll.contentView.bounds.origin.y
                } else if let pdf = sub as? PDFView {
                    entry.pdfPageIndex = pdf.currentPage.flatMap { pdf.document?.index(for: $0) } ?? 0
                }
            }
            scrollCache.store(path: path, entry: entry)
        }
        for sub in containerStack.subviews { sub.removeFromSuperview() }
    }
    public func close() {}
    public func sendText(_ text: String) {}
    public func readText() -> String { filePath ?? "" }
    public func snapshot() -> [String: String] { ["path": filePath ?? ""] }
}

// MARK: - Line-number ruler for read-only text preview

/// Minimal NSRulerView subclass that draws 1-based line numbers aligned to the
/// NSTextView's line-fragment rects. Follows the same AppKit pattern as
/// CodeLineNumberRulerView in FilesSurface (AppShell), adapted for the read-only
/// preview context where the palette and edit callbacks are not needed.
///
/// Redraws only when the visible glyph range changes (coalesced via boundsChanged).
private final class PreviewLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lastVisibleGlyphRange = NSRange(location: NSNotFound, length: 0)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Redraw only when the set of visible lines actually changes (not on every
    // scroll tick / horizontal scroll / sub-pixel jitter).
    @objc private func boundsChanged() {
        guard let textView,
              let lm = textView.layoutManager,
              let tc = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView else {
            needsDisplay = true
            return
        }
        let gr = lm.glyphRange(forBoundingRect: clip.bounds, in: tc)
        guard !NSEqualRanges(gr, lastVisibleGlyphRange) else { return }
        lastVisibleGlyphRange = gr
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let lm = textView.layoutManager,
              let tc = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView else { return }

        // Background
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor: NSColor = isDark
            ? NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
            : NSColor(red: 0.91, green: 0.91, blue: 0.91, alpha: 1)
        let fgColor: NSColor = isDark
            ? NSColor(red: 0.45, green: 0.47, blue: 0.50, alpha: 1)
            : NSColor(red: 0.42, green: 0.44, blue: 0.47, alpha: 1)
        bgColor.setFill()
        bounds.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: fgColor
        ]
        let visibleRect = clip.bounds
        let glyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        guard glyphRange.location < lm.numberOfGlyphs else { return }

        // Compute 1-based line number for the first visible glyph by counting
        // newlines in the text before it (uses pure FilePreviewSurface.lineNumber helper).
        let firstCharIndex = lm.characterIndexForGlyph(at: glyphRange.location)
        var lineNumber = FilePreviewSurface.lineNumber(
            forCharacterOffset: firstCharIndex,
            in: textView.string
        )

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var lineRange = NSRange()
            let lineRect = lm.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineRange,
                withoutAdditionalLayout: true
            )
            let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + 1), withAttributes: attrs)
            glyphIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }
    }
}
