import Foundation
import AppKit
import SwiftUI
import WebKit
import AVKit
import CoreModel
import SocketServer
import Surfaces
import DesignSystemKit

@MainActor
final class FilesSurface: NSObject, Surface {
    private(set) var descriptor: SurfaceDescriptor
    let view: NSView
    private let model: FilesViewModel

    init(workspaceID: WorkspaceID, cwd: String, title: String = "Files", router: AppCommandRouter, initialState: String?) {
        var metadata = ["workspace": workspaceID.value.uuidString, "cwd": cwd]
        if let initialState { metadata["files_state"] = initialState }
        self.descriptor = SurfaceDescriptor(type: .files, title: title, iconName: "folder", metadata: metadata)
        self.model = FilesViewModel(surfaceID: descriptor.id, workspaceID: workspaceID, root: cwd, router: router)
        self.view = NSHostingView(rootView: FilesSurfaceRoot(model: model))
        super.init()
        DispatchQueue.main.async { [model] in model.loadInitialState() }
    }

    func focus() { view.window?.makeFirstResponder(view) }
    func unfocus() {}
    func close() { model.close() }
    func sendText(_ text: String) { model.insertText(text) }
    func readText() -> String { model.visibleText }
    func snapshot() -> [String: String] { ["selected_path": model.selectedPath ?? ""] }
}

private struct FileEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let relativePath: String
    let isDirectory: Bool
    let kind: String
    let mime: String
    let size: Int
    let modifiedAt: Double?
    let isEditable: Bool
    let editabilityReason: String
    let language: String?

    init?(value: JSONValue) {
        guard let object = value.objectValue,
              let name = object["name"]?.stringValue,
              let path = object["path"]?.stringValue,
              let relative = object["relative_path"]?.stringValue,
              let identity = object["identity"]?.objectValue else { return nil }
        self.name = name
        self.path = path
        self.relativePath = relative
        self.id = path
        self.isDirectory = object["type"]?.stringValue == "directory"
        self.kind = identity["kind"]?.stringValue ?? (isDirectory ? "directory" : "unknown")
        self.mime = identity["mime"]?.stringValue ?? "application/octet-stream"
        self.size = object["size"]?.intValue ?? 0
        self.modifiedAt = object["modified_at"]?.doubleValue
        self.isEditable = identity["is_editable"]?.boolValue == true
        self.editabilityReason = identity["editability_reason"]?.stringValue ?? "not editable"
        self.language = identity["language"]?.stringValue
    }
}

@MainActor
private final class FilesViewModel: ObservableObject {
    @Published var currentDirectory = ""
    @Published var entries: [FileEntry] = []
    @Published var selectedEntry: FileEntry?
    @Published var draftText = ""
    @Published var renderedText = ""
    @Published var errorText: String?
    @Published var isLoading = false
    @Published var isDirty = false
    @Published var dirtyPaths: Set<String> = []
    @Published var readerMode = "source"
    @Published var previewURL: URL?
    @Published var syncLabel = "Host synced"

    let surfaceID: SurfaceID
    let workspaceID: WorkspaceID
    let root: String
    weak var router: AppCommandRouter?
    private var sessionID: String?
    private var draftRevision = 0
    private var lastSyncedText = ""
    private var applying = false
    private var pendingText: String?
    private var suppressEditorChange = false
    private var eventToken: UUID?

    var selectedPath: String? { selectedEntry?.relativePath }
    var visibleText: String { draftText.isEmpty ? renderedText : draftText }

    init(surfaceID: SurfaceID, workspaceID: WorkspaceID, root: String, router: AppCommandRouter) {
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.root = root
        self.router = router
        eventToken = EventBus.shared.subscribe(since: nil) { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
    }

    func close() {
        if let eventToken { EventBus.shared.unsubscribe(eventToken) }
        if let sessionID { _ = try? router?.filesEditClose(sessionID: sessionID) }
    }

    func loadInitialState() {
        do {
            if let state = try router?.filesStateGet(surface: surfaceID).objectValue {
                currentDirectory = state["current_directory"]?.stringValue ?? ""
                readerMode = state["reader_mode"]?.stringValue ?? "source"
                dirtyPaths = Self.dirtyPaths(from: state)
            }
            loadDirectory(currentDirectory)
        } catch {
            errorText = String(describing: error)
        }
    }

    func loadDirectory(_ relativePath: String) {
        isLoading = true
        errorText = nil
        do {
            let result = try router?.fsWorkspaceList(workspace: workspaceID, path: relativePath)
            let values = result?.objectValue?["entries"]?.arrayValue ?? []
            entries = values.compactMap(FileEntry.init(value:))
            currentDirectory = result?.objectValue?["relative_path"]?.stringValue ?? relativePath
            isLoading = false
            _ = try? router?.filesStateUpdate(surface: surfaceID, patch: [
                "current_directory": .string(currentDirectory)
            ], baseRevision: nil, deviceID: "mac-local")
        } catch {
            isLoading = false
            errorText = String(describing: error)
        }
    }

    func select(_ entry: FileEntry) {
        selectedEntry = entry
        errorText = nil
        if entry.isDirectory {
            loadDirectory(entry.relativePath)
            return
        }
        loadFile(entry)
    }

    func loadFile(_ entry: FileEntry) {
        do {
            _ = try router?.filesStateUpdate(surface: surfaceID, patch: [
                "selected_path": .string(entry.relativePath),
                "reader_mode": .string(readerMode)
            ], baseRevision: nil, deviceID: "mac-local")
            previewURL = URL(fileURLWithPath: entry.path)
            if entry.isEditable {
                let opened = try router?.filesEditOpen(surface: surfaceID, path: entry.relativePath)
                applyEditPayload(opened?.objectValue ?? [:], remote: false)
            } else {
                sessionID = nil
                isDirty = false
                let read = try router?.fsWorkspaceRead(workspace: workspaceID, path: entry.relativePath, maxBytes: WorkspaceFileLimits.readBytes)
                let content = read?.objectValue?["content"]?.stringValue ?? ""
                setDraft(content)
                renderedText = content
            }
            syncLabel = "Synced r\(draftRevision)"
        } catch {
            errorText = String(describing: error)
        }
    }

    func editorChanged(_ value: String) {
        guard !suppressEditorChange, sessionID != nil, value != lastSyncedText else { return }
        if applying {
            pendingText = value
            return
        }
        applyFullDraft(value)
    }

    func save() {
        guard let sessionID else { return }
        do {
            let result = try router?.filesEditSave(sessionID: sessionID)
            applyEditPayload(result?.objectValue ?? [:], remote: false)
        } catch {
            errorText = String(describing: error)
        }
    }

    func discard() {
        guard let sessionID else { return }
        do {
            let result = try router?.filesEditDiscard(sessionID: sessionID)
            applyEditPayload(result?.objectValue ?? [:], remote: false)
        } catch {
            errorText = String(describing: error)
        }
    }

    func insertText(_ text: String) {
        draftText += text
        editorChanged(draftText)
    }

    func setReaderMode(_ mode: String) {
        guard ["source", "preview", "split"].contains(mode) else { return }
        readerMode = mode
        _ = try? router?.filesStateUpdate(surface: surfaceID, patch: [
            "reader_mode": .string(mode)
        ], baseRevision: nil, deviceID: "mac-local")
    }

    private func applyFullDraft(_ newText: String) {
        guard let sessionID else { return }
        applying = true
        do {
            let result = try router?.filesEditApplyPatch(
                sessionID: sessionID,
                baseDraftRevision: draftRevision,
                rangeLocation: 0,
                rangeLength: lastSyncedText.utf16.count,
                replacement: newText,
                deviceID: "mac-local"
            )
            applyEditPayload(result?.objectValue ?? [:], remote: false)
        } catch {
            errorText = String(describing: error)
        }
        applying = false
        if let pendingText, pendingText != lastSyncedText {
            self.pendingText = nil
            applyFullDraft(pendingText)
        } else {
            pendingText = nil
        }
    }

    private func receive(_ event: EventBus.Event) {
        guard let payload = event.payload.objectValue else { return }
        switch event.kind {
        case "files.state.updated":
            guard payload["surface_id"]?.stringValue == surfaceID.value.uuidString,
                  let state = payload["state"]?.objectValue else { return }
            currentDirectory = state["current_directory"]?.stringValue ?? currentDirectory
            readerMode = state["reader_mode"]?.stringValue ?? readerMode
            dirtyPaths = Self.dirtyPaths(from: state)
            isDirty = selectedPath.map { dirtyPaths.contains($0) } ?? isDirty
            syncLabel = "State r\(state["revision"]?.intValue ?? 0)"
        case "files.edit.opened", "files.edit.patch_applied", "files.edit.saved", "files.edit.discarded":
            guard payload["surface_id"]?.stringValue == surfaceID.value.uuidString else { return }
            applyEditPayload(payload, remote: payload["updated_by_device"]?.stringValue != "mac-local")
        case "files.edit.conflict":
            guard payload["surface_id"]?.stringValue == surfaceID.value.uuidString else { return }
            errorText = "Disk changed outside RemoteCode. Keep the draft, discard, or reload before saving."
        default:
            break
        }
    }

    private func applyEditPayload(_ payload: [String: JSONValue], remote: Bool) {
        if let id = payload["session_id"]?.stringValue { sessionID = id }
        if let revision = payload["draft_revision"]?.intValue { draftRevision = revision }
        if let dirty = payload["dirty"]?.boolValue {
            isDirty = dirty
            if let path = payload["path"]?.stringValue {
                if dirty {
                    dirtyPaths.insert(path)
                } else {
                    dirtyPaths.remove(path)
                }
            }
        }
        if let content = payload["content"]?.stringValue {
            if remote || draftText != content {
                setDraft(content)
            } else {
                lastSyncedText = content
            }
            renderedText = content
        }
        syncLabel = remote ? "Edited on other device r\(draftRevision)" : "Synced r\(draftRevision)"
    }

    private static func dirtyPaths(from state: [String: JSONValue]) -> Set<String> {
        guard case .array(let values) = state["dirty_paths"] ?? .array([]) else { return [] }
        return Set(values.compactMap(\.stringValue))
    }

    private func setDraft(_ text: String) {
        suppressEditorChange = true
        draftText = text
        lastSyncedText = text
        suppressEditorChange = false
    }
}

private struct FilesSurfaceRoot: View {
    @ObservedObject var model: FilesViewModel
    @AppStorage("files.sidebar.width.v2") private var sidebarWidth: Double = 260
    @State private var pathInput = ""
    @State private var confirmDiscard = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
            DSResizeDivider(axis: .vertical, help: "Resize file list") { delta in
                sidebarWidth = min(560, max(240, sidebarWidth + Double(delta)))
            }
            reader
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Palette.bg)
        .foregroundStyle(DS.Palette.text)
        .alert("Discard unsaved changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { model.discard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This reverts the current draft to the last saved version.")
        }
        .onAppear { pathInput = displayPath }
        .onChange(of: model.currentDirectory) { _ in pathInput = displayPath }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Files")
                    .font(DS.Font.title3)
                TextField("Path", text: $pathInput)
                    .font(DS.Font.monoSmall)
                    .textFieldStyle(.plain)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .onSubmit { submitPath() }
                    .help("Type a workspace path and press Return")
                    .accessibilityLabel("Workspace path")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !model.currentDirectory.isEmpty {
                        Button {
                            let parent = (model.currentDirectory as NSString).deletingLastPathComponent
                            model.loadDirectory(parent == "." ? "" : parent)
                        } label: {
                            row(icon: "arrow.turn.up.left", name: "..", detail: "Parent", active: false)
                        }
                        .buttonStyle(.plain)
                        .help("Go to parent folder")
                    }
                    ForEach(model.entries) { entry in
                        Button { model.select(entry) } label: {
                            row(icon: icon(for: entry), name: entry.name, detail: entry.kind, active: model.selectedEntry?.id == entry.id, dirty: model.dirtyPaths.contains(entry.relativePath))
                        }
                        .buttonStyle(.plain)
                        .help(entry.relativePath.isEmpty ? entry.name : entry.relativePath)
                    }
                }
            }
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(DS.Palette.surface)
    }

    private var displayPath: String {
        guard !model.currentDirectory.isEmpty else { return model.root }
        return (model.root as NSString).appendingPathComponent(model.currentDirectory)
    }

    private func submitPath() {
        let raw = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { pathInput = displayPath; return }
        let relative: String
        if raw == model.root || raw == "/" {
            relative = ""
        } else if raw.hasPrefix(model.root + "/") {
            relative = String(raw.dropFirst(model.root.count + 1))
        } else {
            relative = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        model.loadDirectory(relative)
    }

    private var reader: some View {
        VStack(spacing: 0) {
            readerHeader
            Divider().overlay(DS.Palette.line)
            if let error = model.errorText {
                FilesEmptyState(title: "Files error", symbol: "exclamationmark.triangle", detail: error)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selectedEntry == nil {
                FilesEmptyState(title: "Select a file", symbol: "doc.text.magnifyingglass", detail: "Workspace files stay scoped to this root.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                previewBody
            }
        }
        .background(DS.Palette.bg)
    }

    private var readerHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedEntry?.name ?? "No file selected")
                    .font(DS.Font.bodyStrong)
                    .lineLimit(1)
                Text(model.selectedEntry?.relativePath ?? model.root)
                    .font(DS.Font.monoSmall)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.isDirty {
                Label("Unsaved", systemImage: "circle.fill")
                    .font(DS.Font.captionStrong)
                    .foregroundStyle(DS.Palette.warning)
            }
            Text(model.syncLabel)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
            Picker("", selection: $model.readerMode) {
                Text("Source").tag("source")
                Text("Preview").tag("preview")
                Text("Split").tag("split")
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .onChange(of: model.readerMode) { newValue in model.setReaderMode(newValue) }
            Button { model.save() } label: {
                DisketteIcon()
                    .frame(width: 16, height: 16)
            }
                .help("Save")
                .disabled(!model.isDirty)
            Button { confirmDiscard = true } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Discard")
                .disabled(!model.isDirty)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.Palette.surfaceRaised)
    }

    @ViewBuilder
    private var previewBody: some View {
        if let entry = model.selectedEntry {
            switch entry.kind {
            case "markdown":
                sourcePreview(markdown: true)
            case "html":
                sourcePreview(markdown: false)
            case "image":
                ImagePreview(url: model.previewURL)
            case "video":
                VideoPreview(url: model.previewURL)
            case "pdf":
                WebFileView(url: model.previewURL)
            case "code", "text":
                sourcePreview(markdown: false)
            default:
                BinaryMetadataView(entry: entry)
            }
        }
    }

    @ViewBuilder
    private func sourcePreview(markdown: Bool) -> some View {
        let preview = markdown
            ? MarkdownSurface.renderHTML(markdown: model.draftText)
            : (model.selectedEntry?.kind == "html" ? model.draftText : highlightedHTML(text: model.draftText, language: model.selectedEntry?.language))
        if model.readerMode == "preview" {
            WebHTMLView(html: preview, baseURL: model.previewURL?.deletingLastPathComponent())
        } else if model.readerMode == "split" {
            HStack(spacing: 0) {
                editor
                Divider().overlay(DS.Palette.line)
                WebHTMLView(html: preview, baseURL: model.previewURL?.deletingLastPathComponent())
            }
        } else {
            editor
        }
    }

    private var editor: some View {
        CodeTextEditor(text: $model.draftText) { newValue in
            model.editorChanged(newValue)
        }
    }

    private func row(icon: String, name: String, detail: String, active: Bool, dirty: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(active ? DS.Palette.accent : DS.Palette.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(DS.Font.bodyDense).lineLimit(1)
                Text(detail).font(DS.Font.caption2).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if dirty {
                Circle()
                    .fill(DS.Palette.warning)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Unsaved changes")
            }
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 34)
        .background(active ? DS.Palette.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        .contentShape(Rectangle())
    }

    private func icon(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder" }
        switch entry.kind {
        case "markdown": return "doc.richtext"
        case "html": return "globe"
        case "image": return "photo"
        case "video": return "play.rectangle"
        case "pdf": return "doc.text.magnifyingglass"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

private struct ImagePreview: View {
    let url: URL?
    var body: some View {
        GeometryReader { proxy in
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(DS.Palette.bg)
            } else {
                FilesEmptyState(title: "Image unavailable", symbol: "photo", detail: "")
            }
        }
    }
}

private struct DisketteIcon: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let rect = CGRect(x: (proxy.size.width - size) / 2, y: (proxy.size.height - size) / 2, width: size, height: size)
            let line = max(1.6, size * 0.13)
            ZStack {
                DisketteOutline()
                    .stroke(.primary, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                DisketteShutter()
                    .stroke(.primary, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                RoundedRectangle(cornerRadius: size * 0.04)
                    .stroke(.primary, lineWidth: line)
                    .frame(width: size * 0.45, height: size * 0.23)
                    .offset(y: size * 0.25)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
        .accessibilityLabel("Save")
    }
}

private struct DisketteOutline: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.18, 0.08))
        path.addLine(to: point(0.72, 0.08))
        path.addLine(to: point(0.92, 0.28))
        path.addLine(to: point(0.92, 0.82))
        path.addQuadCurve(to: point(0.82, 0.92), control: point(0.92, 0.92))
        path.addLine(to: point(0.18, 0.92))
        path.addQuadCurve(to: point(0.08, 0.82), control: point(0.08, 0.92))
        path.addLine(to: point(0.08, 0.18))
        path.addQuadCurve(to: point(0.18, 0.08), control: point(0.08, 0.08))
        path.closeSubpath()
        return path
    }
}

private struct DisketteShutter: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.28, 0.08))
        path.addLine(to: point(0.28, 0.40))
        path.addQuadCurve(to: point(0.38, 0.50), control: point(0.28, 0.50))
        path.addLine(to: point(0.62, 0.50))
        path.addQuadCurve(to: point(0.72, 0.40), control: point(0.72, 0.50))
        path.addLine(to: point(0.72, 0.08))
        path.move(to: point(0.50, 0.08))
        path.addLine(to: point(0.50, 0.32))
        return path
    }
}

private struct VideoPreview: View {
    let url: URL?
    var body: some View {
        if let url {
            VideoPlayer(player: AVPlayer(url: url))
                .background(DS.Palette.bg)
        } else {
            FilesEmptyState(title: "Video unavailable", symbol: "play.rectangle", detail: "")
        }
    }
}

private struct FilesEmptyState: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(DS.Palette.textTertiary)
            Text(title)
                .font(DS.Font.title3)
            if !detail.isEmpty {
                Text(detail)
                    .font(DS.Font.bodyDense)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.bg)
    }
}

private struct BinaryMetadataView: View {
    let entry: FileEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(entry.kind.capitalized, systemImage: "lock.doc")
                .font(DS.Font.title3)
            Text(entry.editabilityReason)
                .foregroundStyle(DS.Palette.textSecondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { Text("Path"); Text(entry.relativePath).font(DS.Font.monoSmall) }
                GridRow { Text("MIME"); Text(entry.mime).font(DS.Font.monoSmall) }
                GridRow { Text("Size"); Text("\(entry.size) bytes").font(DS.Font.monoSmall) }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Palette.bg)
    }
}

private struct WebHTMLView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(html, baseURL: baseURL)
    }
}

private struct WebFileView: NSViewRepresentable {
    let url: URL?
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        if let url { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
    }
}

private struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        textView.textColor = NSColor(red: 0.83, green: 0.83, blue: 0.83, alpha: 1)
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.applyHighlight(to: textView)
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            context.coordinator.applyHighlight(to: textView)
            textView.selectedRanges = selectedRanges
        } else {
            context.coordinator.applyHighlight(to: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: (String) -> Void
        weak var textView: NSTextView?
        private var applyingHighlight = false

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onChange(textView.string)
            applyHighlight(to: textView)
        }

        func applyHighlight(to textView: NSTextView) {
            guard !applyingHighlight else { return }
            applyingHighlight = true
            let selectedRanges = textView.selectedRanges
            let scrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin
            let text = textView.string
            let attributed = NSMutableAttributedString(string: text, attributes: codeBaseAttributes)
            highlightCode(text, in: attributed)
            textView.textStorage?.setAttributedString(attributed)
            textView.selectedRanges = selectedRanges
            if let scrollOrigin {
                textView.enclosingScrollView?.contentView.scroll(to: scrollOrigin)
                textView.enclosingScrollView?.reflectScrolledClipView(textView.enclosingScrollView!.contentView)
            }
            applyingHighlight = false
        }
    }
}

private func highlightedHTML(text: String, language: String?) -> String {
    let html = text
        .components(separatedBy: "\n")
        .map(highlightCodeLine)
        .joined(separator: "\n")
    let css = """
    body { margin:0; background:#1e1e1e; color:#d4d4d4; font:12px ui-monospace, SFMono-Regular, Menlo, monospace; }
    pre { margin:0; padding:14px; white-space:pre-wrap; word-break:break-word; }
    ::selection { background:#264f78; }
    .comment { color:#6a9955; }
    .kw { color:#569cd6; }
    .control { color:#c586c0; }
    .type { color:#4ec9b0; }
    .str { color:#ce9178; }
    .num { color:#b5cea8; }
    .tag { color:#569cd6; }
    .attr, .prop { color:#9cdcfe; }
    .selector { color:#d7ba7d; }
    .punct { color:#808080; }
    """
    return "<!doctype html><html><head><meta charset=\"utf-8\"><style>\(css)</style></head><body><pre data-language=\"\(language ?? "text")\">\(html)</pre></body></html>"
}

private let codeBaseAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor(red: 0.83, green: 0.83, blue: 0.83, alpha: 1),
    .backgroundColor: NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
]

private func highlightCode(_ text: String, in attributed: NSMutableAttributedString) {
    let nsText = text as NSString
    nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
        let line = nsText.substring(with: range)
        applyHighlightSpans(highlightCodeLine(line), lineRange: range, to: attributed)
    }
}

private func applyHighlightSpans(_ html: String, lineRange: NSRange, to attributed: NSMutableAttributedString) {
    var sourceIndex = html.startIndex
    var plainOffset = 0
    var activeClass: String?

    while sourceIndex < html.endIndex {
        if html[sourceIndex...].hasPrefix("<span class=\"") {
            let classStart = html.index(sourceIndex, offsetBy: 13)
            guard let classEnd = html[classStart...].firstIndex(of: "\""),
                  let tagEnd = html[classEnd...].firstIndex(of: ">") else { break }
            activeClass = String(html[classStart..<classEnd])
            sourceIndex = html.index(after: tagEnd)
            continue
        }
        if html[sourceIndex...].hasPrefix("</span>") {
            activeClass = nil
            sourceIndex = html.index(sourceIndex, offsetBy: 7)
            continue
        }

        let decoded: String
        if html[sourceIndex...].hasPrefix("&lt;") {
            decoded = "<"
            sourceIndex = html.index(sourceIndex, offsetBy: 4)
        } else if html[sourceIndex...].hasPrefix("&gt;") {
            decoded = ">"
            sourceIndex = html.index(sourceIndex, offsetBy: 4)
        } else if html[sourceIndex...].hasPrefix("&amp;") {
            decoded = "&"
            sourceIndex = html.index(sourceIndex, offsetBy: 5)
        } else {
            decoded = String(html[sourceIndex])
            sourceIndex = html.index(after: sourceIndex)
        }

        let length = (decoded as NSString).length
        if let activeClass, let color = codeColor(for: activeClass), length > 0 {
            attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: lineRange.location + plainOffset, length: length))
        }
        plainOffset += length
    }
}

private func codeColor(for tokenClass: String) -> NSColor? {
    switch tokenClass {
    case "comment": return NSColor(red: 0.42, green: 0.60, blue: 0.33, alpha: 1)
    case "kw", "tag": return NSColor(red: 0.34, green: 0.61, blue: 0.84, alpha: 1)
    case "control": return NSColor(red: 0.77, green: 0.53, blue: 0.75, alpha: 1)
    case "type": return NSColor(red: 0.31, green: 0.79, blue: 0.69, alpha: 1)
    case "str": return NSColor(red: 0.81, green: 0.57, blue: 0.47, alpha: 1)
    case "num": return NSColor(red: 0.71, green: 0.81, blue: 0.66, alpha: 1)
    case "attr", "prop": return NSColor(red: 0.61, green: 0.86, blue: 1.0, alpha: 1)
    case "selector": return NSColor(red: 0.84, green: 0.73, blue: 0.49, alpha: 1)
    case "punct": return NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    default: return nil
    }
}

private let codeKeywords = Set(["class", "struct", "enum", "func", "let", "var", "import", "public", "private", "final", "async", "await", "throws", "try", "catch", "do", "in", "extension", "protocol", "init", "self", "static", "const", "function", "def", "from", "as", "nil", "null", "true", "false"])
private let controlKeywords = Set(["return", "if", "else", "for", "while", "guard", "case", "switch", "break", "continue", "throw"])

private func highlightCodeLine(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("<") {
        return highlightMarkupLine(line)
    }
    if looksLikeStyleLine(line) {
        return highlightStyleLine(line)
    }
    return highlightGeneralLine(line, hashStartsComment: true)
}

private func highlightMarkupLine(_ line: String) -> String {
    var output = ""
    var index = line.startIndex
    var inTag = false

    while index < line.endIndex {
        let char = line[index]
        let next = line.index(after: index)
        if line[index...].hasPrefix("<!--") {
            output += "<span class=\"comment\">\(htmlEscape(String(line[index...])))</span>"
            return output
        }
        if char == "<" {
            inTag = true
            output += "<span class=\"punct\">&lt;</span>"
            index = next
            if index < line.endIndex, line[index] == "/" {
                output += "<span class=\"punct\">/</span>"
                index = line.index(after: index)
            }
            if index < line.endIndex, isIdentifierStart(line[index]) {
                let end = scanIdentifier(in: line, from: index)
                output += "<span class=\"tag\">\(htmlEscape(String(line[index..<end])))</span>"
                index = end
            }
            continue
        }
        if char == ">" {
            inTag = false
            output += "<span class=\"punct\">&gt;</span>"
            index = next
            continue
        }
        if inTag, char == "\"" || char == "'" {
            let end = stringEnd(in: line, from: index, quote: char)
            output += "<span class=\"str\">\(htmlEscape(String(line[index..<end])))</span>"
            index = end
            continue
        }
        if inTag, isIdentifierStart(char) {
            let end = scanIdentifier(in: line, from: index)
            output += "<span class=\"attr\">\(htmlEscape(String(line[index..<end])))</span>"
            index = end
            continue
        }
        if inTag, char == "=" || char == "/" {
            output += "<span class=\"punct\">\(htmlEscape(String(char)))</span>"
            index = next
            continue
        }
        output += htmlEscape(String(char))
        index = next
    }
    return output
}

private func highlightStyleLine(_ line: String) -> String {
    if let open = line.firstIndex(of: "{") {
        let before = String(line[..<open])
        let after = String(line[line.index(after: open)...])
        return "<span class=\"selector\">\(htmlEscape(before))</span><span class=\"punct\">{</span>\(highlightStyleLine(after))"
    }
    if let close = line.firstIndex(of: "}") {
        let before = String(line[..<close])
        let after = String(line[line.index(after: close)...])
        return "\(highlightStyleLine(before))<span class=\"punct\">}</span>\(highlightStyleLine(after))"
    }
    if let colon = line.firstIndex(of: ":") {
        let before = String(line[..<colon])
        let after = String(line[line.index(after: colon)...])
        return "<span class=\"prop\">\(htmlEscape(before))</span><span class=\"punct\">:</span>\(highlightGeneralLine(after, hashStartsComment: false))"
    }
    return highlightGeneralLine(line, hashStartsComment: false)
}

private func highlightGeneralLine(_ line: String, hashStartsComment: Bool) -> String {
    var output = ""
    var index = line.startIndex
    var sawNonWhitespace = false

    while index < line.endIndex {
        let char = line[index]
        let next = line.index(after: index)
        if char == "/" && next < line.endIndex && line[next] == "/" {
            output += "<span class=\"comment\">\(htmlEscape(String(line[index...])))</span>"
            break
        }
        if hashStartsComment, char == "#" && !sawNonWhitespace {
            output += "<span class=\"comment\">\(htmlEscape(String(line[index...])))</span>"
            break
        }
        if char == "\"" || char == "'" {
            let end = stringEnd(in: line, from: index, quote: char)
            output += "<span class=\"str\">\(htmlEscape(String(line[index..<end])))</span>"
            index = end
            sawNonWhitespace = true
            continue
        }
        if isIdentifierStart(char) {
            let end = scanIdentifier(in: line, from: index)
            let word = String(line[index..<end])
            if controlKeywords.contains(word) {
                output += "<span class=\"control\">\(word)</span>"
            } else if codeKeywords.contains(word) {
                output += "<span class=\"kw\">\(word)</span>"
            } else if word.first?.isUppercase == true {
                output += "<span class=\"type\">\(word)</span>"
            } else {
                output += htmlEscape(word)
            }
            index = end
            sawNonWhitespace = true
            continue
        }
        if char.isNumber {
            var end = next
            while end < line.endIndex && (line[end].isNumber || line[end] == "." || line[end] == "_") {
                end = line.index(after: end)
            }
            output += "<span class=\"num\">\(htmlEscape(String(line[index..<end])))</span>"
            index = end
            sawNonWhitespace = true
            continue
        }
        output += htmlEscape(String(char))
        if !char.isWhitespace { sawNonWhitespace = true }
        index = next
    }
    return output
}

private func looksLikeStyleLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#") else { return false }
    return trimmed.contains("{") || trimmed.contains("}") || (trimmed.contains(":") && trimmed.hasSuffix(";"))
}

private func scanIdentifier(in line: String, from start: String.Index) -> String.Index {
    var end = line.index(after: start)
    while end < line.endIndex && isIdentifierPart(line[end]) {
        end = line.index(after: end)
    }
    return end
}

private func stringEnd(in line: String, from start: String.Index, quote: Character) -> String.Index {
    var index = line.index(after: start)
    var escaped = false
    while index < line.endIndex {
        let char = line[index]
        if escaped {
            escaped = false
        } else if char == "\\" {
            escaped = true
        } else if char == quote {
            return line.index(after: index)
        }
        index = line.index(after: index)
    }
    return line.endIndex
}

private func isIdentifierStart(_ char: Character) -> Bool {
    char == "_" || char.isLetter
}

private func isIdentifierPart(_ char: Character) -> Bool {
    char == "_" || char.isLetter || char.isNumber
}

private func htmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
