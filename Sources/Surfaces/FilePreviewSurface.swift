import Foundation
import AppKit
import Quartz
import CoreModel

@MainActor
public final class FilePreviewSurface: NSObject, Surface {
    private nonisolated static let maxTextPreviewBytes = 512 * 1024

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public private(set) var filePath: String?
    private let containerStack: NSView
    private var isVisible = true

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
        iv.image = NSImage(contentsOfFile: path)
        iv.translatesAutoresizingMaskIntoConstraints = false
        containerStack.addSubview(iv)
        pin(iv)
    }

    private func renderPDF(path: String) {
        let pdf = PDFView()
        pdf.document = PDFDocument(url: URL(fileURLWithPath: path))
        pdf.autoScales = true
        pdf.translatesAutoresizingMaskIntoConstraints = false
        containerStack.addSubview(pdf)
        pin(pdf)
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
        scroll.documentView = tv
        tv.string = Self.previewText(path: path)
        containerStack.addSubview(scroll)
        pin(scroll)
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
        for sub in containerStack.subviews { sub.removeFromSuperview() }
    }
    public func close() {}
    public func sendText(_ text: String) {}
    public func readText() -> String { filePath ?? "" }
    public func snapshot() -> [String: String] { ["path": filePath ?? ""] }
}
