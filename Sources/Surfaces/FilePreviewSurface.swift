import Foundation
import AppKit
import ImageIO
import Quartz
import CoreModel

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

@MainActor
public final class FilePreviewSurface: NSObject, Surface {
    private nonisolated static let maxTextPreviewBytes = 512 * 1024

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public private(set) var filePath: String?
    private let containerStack: NSView
    private var isVisible = true
    var scrollCache = FilePreviewScrollCache()

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
            containerStack.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: containerStack.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: containerStack.centerYAnchor)
            ])
            return
        }
        let ext = (p as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp"].contains(ext) {
            renderImage(path: p)
        } else if ext == "pdf" {
            renderPDF(path: p)
        } else {
            renderText(path: p)
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
        pdf.document = PDFDocument(url: URL(fileURLWithPath: path))
        pdf.autoScales = true
        pdf.translatesAutoresizingMaskIntoConstraints = false
        pdf.setAccessibilityIdentifier("filePreview.pdf")
        containerStack.addSubview(pdf)
        pin(pdf)
        let saved = scrollCache.entry(for: path)
        if saved.pdfPageIndex > 0,
           let doc = pdf.document,
           saved.pdfPageIndex < doc.pageCount,
           let page = doc.page(at: saved.pdfPageIndex) {
            pdf.go(to: page)
        }
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
        tv.string = Self.previewText(path: path)
        containerStack.addSubview(scroll)
        pin(scroll)
        let saved = scrollCache.entry(for: path)
        if saved.scrollOffsetY != 0 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: saved.scrollOffsetY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    static func previewText(path: String, maxBytes: Int = FilePreviewSurface.maxTextPreviewBytes) -> String {
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
