import Foundation
import AppKit
import ImageIO
import SwiftUI
import WebKit
import AVKit
import CoreModel
import SocketServer
import Surfaces
import DesignSystemKit
import os

// Structured telemetry for the Files surface. Logs operation + error code + coarse size bucket
// only — never paths or file contents — so field save/conflict/decode failures are visible
// without leaking PII (QA-MAC_FILES-008).
private let filesLog = Logger(subsystem: "io.remotecode.appshell", category: "files")

private func sizeBucket(_ bytes: Int) -> String {
    switch bytes {
    case ..<0: return "unknown"
    case 0..<16_384: return "<16KB"
    case 16_384..<262_144: return "16KB-256KB"
    case 262_144..<2_097_152: return "256KB-2MB"
    case 2_097_152..<67_108_864: return "2MB-64MB"
    default: return ">64MB"
    }
}

@MainActor
final class FilesSurface: NSObject, Surface {
    private(set) var descriptor: SurfaceDescriptor
    let view: NSView
    private let model: FilesViewModel

    init(workspaceID: WorkspaceID, cwd: String, title: String = "Files", router: AppCommandRouter, initialState: String?, selectedPath: String? = nil) {
        var metadata = ["workspace": workspaceID.value.uuidString, "cwd": cwd]
        if let initialState { metadata["files_state"] = initialState }
        if let selectedPath {
            metadata["selected_path"] = selectedPath
            metadata["selected_relative_path"] = selectedPath
        }
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

private struct FileTabDragPayload {
    static let prefix = "rc-file-tab|"
    let workspaceID: String
    let sourceSurfaceID: String
    let path: String

    static func encode(workspaceID: WorkspaceID, sourceSurfaceID: SurfaceID, path: String) -> String {
        let encodedPath = Data(path.utf8).base64EncodedString()
        return "\(prefix)\(workspaceID.value.uuidString)|\(sourceSurfaceID.value.uuidString)|\(encodedPath)"
    }

    static func decode(_ value: String) -> FileTabDragPayload? {
        guard value.hasPrefix(prefix) else { return nil }
        let raw = String(value.dropFirst(prefix.count))
        let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let data = Data(base64Encoded: parts[2]),
              let path = String(data: data, encoding: .utf8),
              !path.isEmpty else { return nil }
        return FileTabDragPayload(workspaceID: parts[0], sourceSurfaceID: parts[1], path: path)
    }
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
    let isHidden: Bool
    let isEditable: Bool
    let editabilityReason: String
    let language: String?
    // Precomputed once per entry so List rows don't recompute the icon or re-encode the base64
    // drag payload on every redraw (PERF-MAC_FILES-010). `dragPayload` is filled in by the VM,
    // which holds the workspace/surface IDs the payload needs.
    let icon: String
    var dragPayload: String?

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
        let isDirectory = object["type"]?.stringValue == "directory"
        self.isDirectory = isDirectory
        let kind = identity["kind"]?.stringValue ?? (isDirectory ? "directory" : "unknown")
        self.kind = kind
        self.mime = identity["mime"]?.stringValue ?? "application/octet-stream"
        self.size = object["size"]?.intValue ?? 0
        self.modifiedAt = object["modified_at"]?.doubleValue
        self.isHidden = object["is_hidden"]?.boolValue == true
        self.isEditable = identity["is_editable"]?.boolValue == true
        self.editabilityReason = identity["editability_reason"]?.stringValue ?? "not editable"
        self.language = identity["language"]?.stringValue
        self.icon = Self.icon(isDirectory: isDirectory, kind: kind)
    }

    static func icon(isDirectory: Bool, kind: String) -> String {
        if isDirectory { return "folder" }
        switch kind {
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

private struct FileTabDragModifier: ViewModifier {
    let payload: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let payload {
            content.draggable(payload)
        } else {
            content
        }
    }
}

private extension View {
    func fileTabDragPayload(_ payload: String?) -> some View {
        modifier(FileTabDragModifier(payload: payload))
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
    @Published var syncLabel = "Up to date"
    @Published var syncDetail = ""
    @Published var conflictActive = false

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
    private var sessionCache: [String: EditSessionSnapshot] = [:]
    private var sessionPath: String?

    private struct EditSessionSnapshot {
        var sessionID: String
        var draftText: String
        var draftRevision: Int
        var lastSyncedText: String
        var isDirty: Bool
    }

    var selectedPath: String? { selectedEntry?.relativePath }
    var visibleText: String { draftText.isEmpty ? renderedText : draftText }

    init(surfaceID: SurfaceID, workspaceID: WorkspaceID, root: String, router: AppCommandRouter) {
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.root = root
        self.router = router
        // Subscribe from the current head, not `nil` (which replays the entire retained
        // backlog into this surface on the main thread). This surface loads its own state
        // explicitly via loadInitialState()/filesStateGet (PERF-MAC_FILES-003).
        let head = EventBus.shared.snapshot().lastSeq
        eventToken = EventBus.shared.subscribe(since: head) { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
    }

    func close() {
        if let eventToken { EventBus.shared.unsubscribe(eventToken) }
        if let sessionID { _ = try? router?.filesEditClose(sessionID: sessionID) }
    }

    func loadInitialState() {
        do {
            var initialSelectedPath: String?
            if let state = try router?.filesStateGet(surface: surfaceID).objectValue {
                initialSelectedPath = state["selected_path"]?.stringValue
                let stateDirectory = state["current_directory"]?.stringValue ?? ""
                if stateDirectory.isEmpty, let initialSelectedPath {
                    let parent = (initialSelectedPath as NSString).deletingLastPathComponent
                    currentDirectory = parent == "." ? "" : parent
                } else {
                    currentDirectory = stateDirectory
                }
                readerMode = state["reader_mode"]?.stringValue ?? "source"
                dirtyPaths = Self.dirtyPaths(from: state)
            }
            loadDirectory(currentDirectory)
            if let initialSelectedPath,
               let entry = entries.first(where: { !$0.isDirectory && $0.relativePath == initialSelectedPath }) {
                selectedEntry = entry
                loadFile(entry)
            }
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
            entries = values.compactMap(FileEntry.init(value:)).map { entry in
                var entry = entry
                if !entry.isDirectory {
                    entry.dragPayload = FileTabDragPayload.encode(workspaceID: workspaceID, sourceSurfaceID: surfaceID, path: entry.relativePath)
                }
                return entry
            }
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
        snapshotCurrentSession()
        do {
            _ = try router?.filesStateUpdate(surface: surfaceID, patch: [
                "selected_path": .string(entry.relativePath),
                "reader_mode": .string(readerMode)
            ], baseRevision: nil, deviceID: "mac-local")
            previewURL = URL(fileURLWithPath: entry.path)
            if entry.isEditable {
                if let cached = sessionCache[entry.relativePath], cached.isDirty {
                    restoreSession(cached)
                } else {
                    let opened = try router?.filesEditOpen(surface: surfaceID, path: entry.relativePath)
                    applyEditPayload(opened?.objectValue ?? [:], remote: false)
                }
                sessionPath = entry.relativePath
            } else {
                sessionID = nil
                sessionPath = nil
                isDirty = false
                let read = try router?.fsWorkspaceRead(workspace: workspaceID, path: entry.relativePath, maxBytes: WorkspaceFileLimits.readBytes)
                let content = read?.objectValue?["content"]?.stringValue ?? ""
                setDraft(content)
                renderedText = content
            }
            setSyncLabel("Up to date", revision: draftRevision)
        } catch {
            logFailure("open", error: error)
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
            logFailure("save", error: error)
            errorText = String(describing: error)
        }
    }

    func discard() {
        guard let sessionID else { return }
        do {
            let result = try router?.filesEditDiscard(sessionID: sessionID)
            applyEditPayload(result?.objectValue ?? [:], remote: false)
        } catch {
            logFailure("discard", error: error)
            errorText = String(describing: error)
        }
    }

    func createFile(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let path = currentDirectory.isEmpty ? name : "\(currentDirectory)/\(name)"
        do {
            let result = try router?.fsWorkspaceCreateFile(workspace: workspaceID, path: path, content: "")
            let created = result.flatMap(FileEntry.init(value:))
            loadDirectory(currentDirectory)
            if let created {
                selectedEntry = created
                loadFile(created)
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    func rename(_ entry: FileEntry, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        closeSessionIfSelected(path: entry.relativePath)
        do {
            let result = try router?.fsWorkspaceRename(workspace: workspaceID, path: entry.relativePath, newName: name)
            let renamed = result.flatMap(FileEntry.init(value:))
            loadDirectory(currentDirectory)
            if selectedEntry?.id == entry.id, let renamed {
                selectedEntry = renamed
                loadFile(renamed)
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    func delete(_ entries: [FileEntry]) {
        let targets = entries.map(\.relativePath)
        guard !targets.isEmpty else { return }
        if let selectedPath, targets.contains(selectedPath) {
            closeSessionIfSelected(path: selectedPath)
            selectedEntry = nil
            setDraft("")
            renderedText = ""
            isDirty = false
        }
        do {
            _ = try router?.fsWorkspaceDelete(workspace: workspaceID, paths: targets)
            dirtyPaths.subtract(targets)
            loadDirectory(currentDirectory)
        } catch {
            errorText = String(describing: error)
        }
    }

    func openInNewTab(_ entry: FileEntry) {
        guard !entry.isDirectory else { return }
        do {
            _ = try router?.filesOpenTab(workspace: workspaceID, sourceSurface: surfaceID, paneID: nil, path: entry.relativePath)
        } catch {
            errorText = String(describing: error)
        }
    }

    func splitFileTab(path: String, direction: SplitDirection) {
        do {
            _ = try router?.filesSplitTab(workspace: workspaceID, sourceSurface: surfaceID, paneID: nil, direction: direction, path: path)
        } catch {
            errorText = String(describing: error)
        }
    }

    func handleFileDropPayload(_ rawPayload: String, location: CGPoint, size: CGSize) -> Bool {
        guard let payload = FileTabDragPayload.decode(rawPayload),
              payload.workspaceID == workspaceID.value.uuidString else { return false }
        let direction: SplitDirection = location.y >= size.height * 0.68 ? .down : .right
        splitFileTab(path: payload.path, direction: direction)
        return true
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
        let delta = Self.minimalEdit(from: lastSyncedText, to: newText)
        applying = true
        do {
            let result = try router?.filesEditApplyPatch(
                sessionID: sessionID,
                baseDraftRevision: draftRevision,
                rangeLocation: delta.location,
                rangeLength: delta.length,
                replacement: delta.replacement,
                deviceID: "mac-local"
            )
            applyEditPayload(result?.objectValue ?? [:], remote: false)
        } catch {
            logFailure("patch", error: error)
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

    /// Minimal changed range as a UTF-16 NSRange over `old` plus the UTF-16 replacement,
    /// found by trimming the common prefix and suffix between `old` and `new`.
    private static func minimalEdit(from old: String, to new: String) -> (location: Int, length: Int, replacement: String) {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        var prefix = 0
        let maxPrefix = min(oldUnits.count, newUnits.count)
        while prefix < maxPrefix && oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }
        var suffix = 0
        let maxSuffix = min(oldUnits.count, newUnits.count) - prefix
        while suffix < maxSuffix && oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
            suffix += 1
        }
        let location = prefix
        let length = oldUnits.count - prefix - suffix
        let replacement = String(utf16CodeUnits: Array(newUnits[prefix..<(newUnits.count - suffix)]), count: newUnits.count - prefix - suffix)
        return (location, length, replacement)
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
            setSyncLabel(isDirty ? "Unsaved" : "Up to date", revision: state["revision"]?.intValue ?? 0)
        case "files.edit.opened", "files.edit.patch_applied", "files.edit.saved", "files.edit.discarded":
            guard payload["surface_id"]?.stringValue == surfaceID.value.uuidString else { return }
            applyEditPayload(payload, remote: payload["updated_by_device"]?.stringValue != "mac-local")
        case "files.edit.conflict":
            guard payload["surface_id"]?.stringValue == surfaceID.value.uuidString else { return }
            conflictActive = true
            filesLog.notice("files.conflict kind=\(self.selectedEntry?.kind ?? "none", privacy: .public) size=\(sizeBucket(self.selectedEntry?.size ?? -1), privacy: .public)")
        case "files.edit.closed":
            // A session closed elsewhere (e.g. another device or a server-side cleanup) must clear
            // our local session/dirty state for that path; otherwise we'd keep editing against a
            // session the host no longer has (QA-MAC_FILES-007).
            guard payload["surface_id"]?.stringValue == surfaceID.value.uuidString,
                  let closedID = payload["session_id"]?.stringValue else { return }
            if let path = payload["path"]?.stringValue {
                dirtyPaths.remove(path)
                sessionCache.removeValue(forKey: path)
            }
            if sessionID == closedID {
                sessionID = nil
                sessionPath = nil
                isDirty = false
            }
        default:
            break
        }
    }

    private func applyEditPayload(_ payload: [String: JSONValue], remote: Bool) {
        conflictActive = false
        if let id = payload["session_id"]?.stringValue { sessionID = id }
        if let revision = payload["draft_revision"]?.intValue { draftRevision = revision }
        if let dirty = payload["dirty"]?.boolValue {
            isDirty = dirty
            if let path = payload["path"]?.stringValue {
                if dirty {
                    dirtyPaths.insert(path)
                } else {
                    dirtyPaths.remove(path)
                    sessionCache.removeValue(forKey: path)
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
        if remote {
            setSyncLabel("Edited on another device", revision: draftRevision)
        } else if isDirty {
            setSyncLabel("Unsaved", revision: draftRevision)
        } else {
            setSyncLabel("Saved", revision: draftRevision)
        }
    }

    /// Human-readable sync status with the internal revision kept only as a tooltip detail
    /// (UX-MAC_FILES-006).
    private func setSyncLabel(_ label: String, revision: Int) {
        syncLabel = label
        syncDetail = "Revision \(revision)"
    }

    /// Record an operation failure with its RPC error code, file kind, and a coarse size bucket —
    /// no paths or contents — so flaky save/conflict/decode reports are reproducible (QA-MAC_FILES-008).
    private func logFailure(_ operation: String, error: Error) {
        let kind = selectedEntry?.kind ?? "none"
        let bucket = sizeBucket(selectedEntry?.size ?? -1)
        if let rpc = error as? JSONRPCError {
            filesLog.error("files.\(operation, privacy: .public) failed code=\(rpc.code, privacy: .public) kind=\(kind, privacy: .public) size=\(bucket, privacy: .public)")
        } else {
            filesLog.error("files.\(operation, privacy: .public) failed kind=\(kind, privacy: .public) size=\(bucket, privacy: .public)")
        }
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

    private func closeSessionIfSelected(path: String) {
        guard selectedPath == path, let sessionID else { return }
        _ = try? router?.filesEditClose(sessionID: sessionID)
        self.sessionID = nil
        if sessionPath == path { sessionPath = nil }
        sessionCache.removeValue(forKey: path)
    }

    /// Persist the currently open edit session so reselecting its path restores the draft
    /// instead of reopening from disk (UX-MAC_FILES-004/005). Keyed by the live session's
    /// own path (`sessionPath`), not `selectedPath`, since selection is updated before loadFile.
    private func snapshotCurrentSession() {
        guard let sessionID, let path = sessionPath else { return }
        sessionCache[path] = EditSessionSnapshot(
            sessionID: sessionID,
            draftText: draftText,
            draftRevision: draftRevision,
            lastSyncedText: lastSyncedText,
            isDirty: isDirty
        )
    }

    private func restoreSession(_ snapshot: EditSessionSnapshot) {
        sessionID = snapshot.sessionID
        draftRevision = snapshot.draftRevision
        isDirty = snapshot.isDirty
        setDraft(snapshot.draftText)
        lastSyncedText = snapshot.lastSyncedText
        renderedText = snapshot.draftText
        setSyncLabel(isDirty ? "Unsaved" : "Up to date", revision: draftRevision)
    }
}

private struct FilesSurfaceRoot: View {
    @ObservedObject var model: FilesViewModel
    @AppStorage("files.sidebar.width.v2") private var sidebarWidth: Double = 260
    @AppStorage("files.sidebar.intent.v1") private var sidebarIntentRaw = AdaptiveSidebarIntent.auto.rawValue
    @AppStorage("files.sidebar.showHidden.v1") private var showHidden = false
    @State private var sidebarVisible = true
    @State private var lastAutomaticSidebarChange: TimeInterval?
    @State private var selectedFileIDs: Set<String> = []
    @State private var pathInput = ""
    @State private var confirmDiscard = false
    @State private var showNewFileDialog = false
    @State private var newFileName = ""
    @State private var renamingEntry: FileEntry?
    @State private var renameText = ""
    @State private var deleteTargets: [FileEntry] = []
    @State private var confirmDelete = false
    @State private var pathInvalid = false
    @State private var dropTargeted = false
    @FocusState private var newFileFieldFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar
                        .frame(width: sidebarWidth)
                    DSResizeDivider(axis: .vertical, help: "Resize file list") { delta in
                        sidebarWidth = min(560, max(240, sidebarWidth + Double(delta)))
                    }
                }
                reader
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { applyAdaptiveSidebar(width: proxy.size.width, event: .structural) }
            .onChange(of: proxy.size.width) { width in
                applyAdaptiveSidebar(width: width, event: .resize)
            }
            .onChange(of: model.readerMode) { _ in
                applyAdaptiveSidebar(width: proxy.size.width, event: .structural)
            }
        }
        .background(DS.Palette.bg)
        .foregroundStyle(DS.Palette.text)
        .alert("Discard unsaved changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { model.discard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This reverts the current draft to the last saved version.")
        }
        .alert("New File", isPresented: $showNewFileDialog) {
            TextField("File name", text: $newFileName)
                .focused($newFileFieldFocused)
                .onSubmit { createNewFile() }
                .accessibilityIdentifier("files.newFile.field")
            Button("Create") { createNewFile() }
                .accessibilityIdentifier("files.newFile.create")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.currentDirectory.isEmpty ? "Create in workspace root." : "Create in \(model.currentDirectory).")
        }
        // Focus the name field as soon as the New File dialog appears so keyboard users can
        // type immediately without clicking first (UX-MAC_FILES-001).
        .onChange(of: showNewFileDialog) { presented in
            if presented { newFileFieldFocused = true }
        }
        .alert("Rename", isPresented: Binding(
            get: { renamingEntry != nil },
            set: { if !$0 { renamingEntry = nil } }
        )) {
            TextField("File name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renamingEntry = nil }
        }
        .alert(deleteTitle, isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteTargets.count == 1 ? deleteTargets[0].relativePath : "\(deleteTargets.count) selected items will be deleted from the workspace.")
        }
        .onAppear { pathInput = displayPath }
        .onChange(of: model.currentDirectory) { _ in
            pathInput = displayPath
            selectedFileIDs = []
        }
        .onChange(of: selectedFileIDs) { ids in
            guard ids.count == 1,
                  let id = ids.first,
                  let entry = model.entries.first(where: { $0.id == id }) else { return }
            model.select(entry)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Files")
                        .font(DS.Font.title3)
                    Spacer()
                    DSIconButton("sidebar.left", help: "Hide file sidebar") {
                        sidebarIntent = .forcedHidden
                        sidebarVisible = false
                    }
                    .accessibilityLabel("Hide file sidebar")
                    // Toggle dotfile visibility; off by default so common dev clutter (.git, .DS_Store)
                    // stays hidden until asked for (IMP-MAC_FILES-014).
                    DSIconButton(showHidden ? "eye" : "eye.slash", help: showHidden ? "Hide hidden files" : "Show hidden files") {
                        showHidden.toggle()
                    }
                    .accessibilityLabel(showHidden ? "Hide hidden files" : "Show hidden files")
                    .accessibilityIdentifier("files.showHidden.toggle")
                    DSIconButton("plus", help: "New file") {
                        newFileName = ""
                        showNewFileDialog = true
                    }
                    .accessibilityLabel("New file")
                    .accessibilityIdentifier("files.newFile.button")
                }
                TextField("Path", text: $pathInput)
                    .font(DS.Font.monoSmall)
                    .textFieldStyle(.plain)
                    .foregroundStyle(pathInvalid ? DS.Palette.danger : DS.Palette.textSecondary)
                    .lineLimit(1)
                    .onSubmit { submitPath() }
                    .help("Type a workspace path and press Return")
                    .accessibilityLabel("Workspace path")
                    .accessibilityIdentifier("files.path.field")
                breadcrumb
            }
            List(selection: $selectedFileIDs) {
                if !model.currentDirectory.isEmpty {
                    Button {
                        navigateToParent()
                    } label: {
                        row(icon: "arrow.turn.up.left", name: "..", detail: "Parent", active: false)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowBackground(Color.clear)
                    // Cmd+Up navigates up a level for keyboard users, since the ".." row is not part
                    // of the List selection set and arrow keys never reach it (UX-MAC_FILES-012).
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .help("Go to parent folder (⌘↑)")
                    .accessibilityIdentifier("files.parent.button")
                }
                ForEach(visibleEntries) { entry in
                    row(icon: entry.icon, name: entry.name, detail: entry.kind, active: model.selectedEntry?.id == entry.id || selectedFileIDs.contains(entry.id), dirty: model.dirtyPaths.contains(entry.relativePath), dirtyPath: entry.relativePath)
                        .tag(entry.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                        .listRowBackground(Color.clear)
                        .contextMenu { fileContextMenu(for: entry) }
                        .fileTabDragPayload(entry.dragPayload)
                        .help(entry.relativePath.isEmpty ? entry.name : entry.relativePath)
                        .accessibilityIdentifier("files.row.\(entry.relativePath)")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("files.sidebar.list")
            if model.isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityIdentifier("files.sidebar.loading")
            }
        }
        .padding(12)
        .background(DS.Palette.surface)
    }

    private var displayPath: String {
        guard !model.currentDirectory.isEmpty else { return model.root }
        return (model.root as NSString).appendingPathComponent(model.currentDirectory)
    }

    // Dotfiles are hidden unless the user opts in via the sidebar toggle (IMP-MAC_FILES-014).
    private var visibleEntries: [FileEntry] {
        showHidden ? model.entries : model.entries.filter { !$0.isHidden }
    }

    // Language badge, size, and modified-ago for the selected text file so users get context
    // that previously only appeared in the binary view (UX-MAC_FILES-007).
    private func fileMetaSubtitle(_ entry: FileEntry) -> String? {
        var parts: [String] = []
        if let language = entry.language, !language.isEmpty {
            parts.append(language)
        } else if !entry.kind.isEmpty {
            parts.append(entry.kind)
        }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
        if let modified = entry.modifiedAt {
            let date = Date(timeIntervalSince1970: modified)
            parts.append(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // Map developer-facing error descriptions (raw JSONRPCError) to friendly copy so that
    // "workspace root not found" vs "path escapes workspace" no longer look identical and
    // unfriendly, and offer a recovery path where it makes sense (UX-MAC_FILES-017).
    private static func friendlyError(_ raw: String) -> (title: String, symbol: String, detail: String, offerRoot: Bool) {
        let lower = raw.lowercased()
        if lower.contains("escapes workspace") {
            return ("Outside the workspace", "lock.shield", "That path is outside this workspace. Files stay scoped to the workspace root.", true)
        }
        if lower.contains("workspace root not found") {
            return ("Workspace unavailable", "folder.badge.questionmark", "The workspace folder could not be found. It may have been moved or deleted.", false)
        }
        if lower.contains("not found") {
            return ("Not found", "questionmark.folder", "This path no longer exists in the workspace.", true)
        }
        if lower.contains("permission") || lower.contains("not permitted") {
            return ("Permission denied", "hand.raised", "RemoteCode can't access this path.", true)
        }
        return ("Files error", "exclamationmark.triangle", raw, true)
    }

    // Clickable breadcrumb so users can jump to any ancestor without typing full paths or
    // clicking up through ".." repeatedly (UX-MAC_FILES-014).
    private var breadcrumb: some View {
        let segments = model.currentDirectory.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button("root") { model.loadDirectory("") }
                    .buttonStyle(.plain)
                    .foregroundStyle(segments.isEmpty ? DS.Palette.text : DS.Palette.accent)
                    .accessibilityIdentifier("files.breadcrumb.root")
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(DS.Palette.textTertiary)
                    Button(segment) {
                        model.loadDirectory(segments[0...index].joined(separator: "/"))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == segments.count - 1 ? DS.Palette.text : DS.Palette.accent)
                    .accessibilityIdentifier("files.breadcrumb.\(segment)")
                }
            }
            .font(DS.Font.caption2)
            .lineLimit(1)
        }
    }

    private func navigateToParent() {
        let parent = (model.currentDirectory as NSString).deletingLastPathComponent
        model.loadDirectory(parent == "." ? "" : parent)
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
        // On a bad path the error surfaces far away in the reader; flag the field red and restore
        // the last valid path so the input doesn't silently keep invalid text (UX-MAC_FILES-013).
        if model.errorText != nil {
            pathInvalid = true
            pathInput = displayPath
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { pathInvalid = false }
        } else {
            pathInvalid = false
        }
    }

    private var selectedEntries: [FileEntry] {
        model.entries.filter { selectedFileIDs.contains($0.id) }
    }

    private var deleteTitle: String {
        deleteTargets.count == 1 ? "Delete \(deleteTargets[0].name)?" : "Delete \(deleteTargets.count) items?"
    }

    @ViewBuilder
    private func fileContextMenu(for entry: FileEntry) -> some View {
        let targets = selectedFileIDs.contains(entry.id) && selectedEntries.count > 1 ? selectedEntries : [entry]
        if targets.count == 1 {
            if !entry.isDirectory {
                Button("Open in New Tab") { model.openInNewTab(entry) }
                Divider()
            }
            Button("Reveal in Finder") { revealInFinder(entry) }
            if !entry.isDirectory {
                Button("Open with Default App") { openWithDefaultApp(entry) }
            }
            Divider()
            Button("Rename...") { beginRename(entry) }
            Divider()
            Button("Delete", role: .destructive) { beginDelete(targets) }
        } else {
            Button("Delete \(targets.count) Items", role: .destructive) { beginDelete(targets) }
        }
    }

    private func createNewFile() {
        model.createFile(named: newFileName)
        newFileName = ""
    }

    // Escape hatches to the real file via Finder / default app, for binaries and large media
    // that RemoteCode can't render usefully (UX-MAC_FILES-009).
    private func revealInFinder(_ entry: FileEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    private func openWithDefaultApp(_ entry: FileEntry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
    }

    private func beginRename(_ entry: FileEntry) {
        selectedFileIDs = [entry.id]
        renamingEntry = entry
        renameText = entry.name
    }

    private func commitRename() {
        guard let entry = renamingEntry else { return }
        model.rename(entry, to: renameText)
        selectedFileIDs = []
        renamingEntry = nil
    }

    private func beginDelete(_ entries: [FileEntry]) {
        deleteTargets = entries
        confirmDelete = true
    }

    private func commitDelete() {
        model.delete(deleteTargets)
        selectedFileIDs.subtract(deleteTargets.map(\.id))
        deleteTargets = []
    }

    private var reader: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                readerHeader
                Divider().overlay(DS.Palette.line)
                if model.conflictActive {
                    conflictBanner
                    Divider().overlay(DS.Palette.line)
                }
                if let error = model.errorText {
                    let mapped = Self.friendlyError(error)
                    FilesEmptyState(title: mapped.title, symbol: mapped.symbol, detail: mapped.detail) {
                        if mapped.offerRoot {
                            Button("Go to Workspace Root") { model.loadDirectory("") }
                                .accessibilityIdentifier("files.error.goRoot")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("files.emptyState.error")
                } else if model.selectedEntry == nil {
                    FilesEmptyState(title: "Select a file", symbol: "doc.text.magnifyingglass", detail: "Workspace files stay scoped to this root.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("files.emptyState.select")
                } else {
                    previewBody
                }
            }
            .dropDestination(for: String.self) { values, location in
                dropTargeted = false
                guard let payload = values.first else { return false }
                return model.handleFileDropPayload(payload, location: location, size: proxy.size)
            } isTargeted: { targeted in
                dropTargeted = targeted
            }
            // Show where a dragged file tab will land so the user isn't guessing right-vs-bottom
            // split until release (UX-MAC_FILES-018). The destination computes direction by the
            // drop's y-position; the overlay mirrors that split affordance during drag-over.
            .overlay {
                if dropTargeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: DS.Radius.control)
                            .stroke(DS.Palette.accent, lineWidth: 2)
                        Text("Drop to split")
                            .font(DS.Font.captionStrong)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(DS.Palette.surfaceRaised, in: Capsule())
                            .foregroundStyle(DS.Palette.accent)
                    }
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("files.split.dropIndicator")
                }
            }
            .background(DS.Palette.bg)
        }
    }

    // Conflict is rendered as an actionable banner instead of a dead-end sentence in errorText,
    // so the named actions actually exist inline (UX-MAC_FILES-016). "Reload from Disk" is the
    // host-backed resolution (discard re-reads disk); "Keep Editing" hides the banner so the user
    // can continue with their draft. A force-save ("Keep My Changes") needs a host change and is
    // intentionally not offered here, since filesEditSave rejects a save over a changed disk.
    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("File changed outside RemoteCode")
                    .font(DS.Font.bodyStrong)
                Text("Saving is blocked until you reload. Reloading replaces your draft with the on-disk version.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Keep Editing") { model.conflictActive = false }
                .help("Dismiss this notice and keep your unsaved draft")
                .accessibilityIdentifier("files.conflict.keepEditing")
            Button("Reload from Disk") { model.discard() }
                .help("Replace your draft with the current file on disk")
                .accessibilityIdentifier("files.conflict.reload")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.Palette.surfaceRaised)
    }

    private var readerHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if !sidebarVisible {
                        DSIconButton("sidebar.left", help: "Show file sidebar") {
                            sidebarIntent = .forcedVisible
                            sidebarVisible = true
                        }
                        .accessibilityLabel("Show file sidebar")
                    }
                    Text(model.selectedEntry?.name ?? "No file selected")
                        .font(DS.Font.bodyStrong)
                        .lineLimit(1)
                }
                Text(model.selectedEntry?.relativePath ?? model.root)
                    .font(DS.Font.monoSmall)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let entry = model.selectedEntry, !entry.isDirectory, let detail = fileMetaSubtitle(entry) {
                    Text(detail)
                        .font(DS.Font.caption2)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                        .accessibilityIdentifier("files.header.meta")
                }
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
                .help(model.syncDetail)
                .accessibilityIdentifier("files.sync.label")
            Picker("", selection: $model.readerMode) {
                Text("Source").tag("source")
                Text("Preview").tag("preview")
                Text("Split").tag("split")
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .onChange(of: model.readerMode) { newValue in model.setReaderMode(newValue) }
            .accessibilityIdentifier("files.readerMode.picker")
            Button { model.save() } label: {
                DisketteIcon()
                    .frame(width: 16, height: 16)
            }
                .help("Save")
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.isDirty)
                .accessibilityIdentifier("files.save.button")
            Button { confirmDiscard = true } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Discard")
                .disabled(!model.isDirty)
                .accessibilityIdentifier("files.discard.button")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.Palette.surfaceRaised)
    }

    private var sidebarIntent: AdaptiveSidebarIntent {
        get { AdaptiveSidebarIntent(rawValue: sidebarIntentRaw) ?? .auto }
        nonmutating set { sidebarIntentRaw = newValue.rawValue }
    }

    private var readerMinimumWidth: CGFloat {
        model.readerMode == "split" ? 700 : 520
    }

    private func applyAdaptiveSidebar(width: CGFloat, event: AdaptiveSidebarLayoutEvent) {
        let now = Date().timeIntervalSinceReferenceDate
        let decision = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: width,
            contentMinimumExtent: readerMinimumWidth,
            sidebarExtent: CGFloat(sidebarWidth) + DS.ResizeDivider.thickness,
            currentVisible: sidebarVisible,
            intent: sidebarIntent,
            event: event,
            now: now,
            lastAutomaticChange: lastAutomaticSidebarChange
        )
        guard decision.isVisible != sidebarVisible else { return }
        sidebarVisible = decision.isVisible
        if decision.didChangeAutomatically {
            lastAutomaticSidebarChange = now
        }
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
                LargeMediaGuard(entry: entry, url: model.previewURL) { url in ImagePreview(url: url) }
            case "video":
                LargeMediaGuard(entry: entry, url: model.previewURL) { url in VideoPreview(url: url) }
            case "pdf":
                LargeMediaGuard(entry: entry, url: model.previewURL) { url in WebFileView(url: url) }
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
            PreviewWebView(html: preview, baseURL: model.previewURL?.deletingLastPathComponent())
        } else if model.readerMode == "split" {
            HStack(spacing: 0) {
                editor
                Divider().overlay(DS.Palette.line)
                PreviewWebView(html: preview, baseURL: model.previewURL?.deletingLastPathComponent())
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

    private func row(icon: String, name: String, detail: String, active: Bool, dirty: Bool = false, dirtyPath: String? = nil) -> some View {
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
                    .accessibilityIdentifier("files.dirtyDot.\(dirtyPath ?? "")")
            }
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 34)
        .background(active ? DS.Palette.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        .contentShape(Rectangle())
    }
}

/// Gate large media (image/video/PDF) behind an explicit confirmation so selecting a multi-GB
/// video or huge image does not stall/spike memory by decoding/streaming it immediately. Text
/// reads are already byte-capped; media previews load straight from disk (UX-MAC_FILES-008).
private struct LargeMediaGuard<Content: View>: View {
    static var threshold: Int { 64 * 1024 * 1024 }
    let entry: FileEntry
    let url: URL?
    @ViewBuilder let content: (URL?) -> Content
    @State private var loadAnyway = false

    var body: some View {
        if entry.size > Self.threshold && !loadAnyway {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(DS.Palette.textTertiary)
                Text("Large file")
                    .font(DS.Font.title3)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)) — loading it in RemoteCode may be slow.")
                    .font(DS.Font.bodyDense)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                HStack(spacing: 8) {
                    Button("Open Externally") {
                        if let url { NSWorkspace.shared.open(url) }
                    }
                    .accessibilityIdentifier("files.largeMedia.openExternal")
                    Button("Load Anyway") { loadAnyway = true }
                        .accessibilityIdentifier("files.largeMedia.loadAnyway")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Palette.bg)
            .onChange(of: entry.id) { _ in loadAnyway = false }
        } else {
            content(url)
                .onChange(of: entry.id) { _ in loadAnyway = false }
        }
    }
}

private struct ImagePreview: View {
    let url: URL?
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(DS.Palette.bg)
            } else if failed {
                FilesEmptyState(title: "Image unavailable", symbol: "photo", detail: "")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.Palette.bg)
            }
        }
        // Decode once off the main thread into a downsampled image instead of re-decoding the
        // full-resolution NSImage on every layout pass (resize, sidebar drag) (PERF-MAC_FILES-005).
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { failed = true; return }
            let decoded = await Self.decodeDownsampled(url: url)
            guard !Task.isCancelled else { return }
            if let decoded { image = decoded } else { failed = true }
        }
    }

    private static func decodeDownsampled(url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
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
    @StateObject private var holder = VideoPlayerHolder()

    var body: some View {
        Group {
            if url != nil {
                VideoPlayer(player: holder.player)
                    .background(DS.Palette.bg)
            } else {
                FilesEmptyState(title: "Video unavailable", symbol: "play.rectangle", detail: "")
            }
        }
        // Reuse a single AVPlayer across layout passes and swap its item only when the URL
        // changes, instead of allocating a fresh player on every body eval (PERF-MAC_FILES-011).
        .onChange(of: url) { newValue in holder.load(newValue) }
        .onAppear { holder.load(url) }
        .onDisappear { holder.teardown() }
    }
}

/// Owns the AVPlayer for VideoPreview so it survives SwiftUI body re-evaluations and is
/// paused/cleared when the preview disappears, preventing background decode/buffer drain
/// (PERF-MAC_FILES-011).
@MainActor
private final class VideoPlayerHolder: ObservableObject {
    let player = AVPlayer()
    private var currentURL: URL?

    func load(_ url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        if let url {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        } else {
            player.replaceCurrentItem(with: nil)
        }
    }

    func teardown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
    }
}

private struct FilesEmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

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
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.bg)
    }
}

extension FilesEmptyState where Actions == EmptyView {
    init(title: String, symbol: String, detail: String) {
        self.init(title: title, symbol: symbol, detail: detail, actions: { EmptyView() })
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
            // Escape hatch to the real file for binaries RemoteCode can't render (UX-MAC_FILES-009).
            HStack(spacing: 8) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                }
                .accessibilityIdentifier("files.binary.reveal")
                Button("Open with Default App") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
                }
                .accessibilityIdentifier("files.binary.openExternal")
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Palette.bg)
    }
}

// Light placeholder while the web view first paints, so large markdown/HTML previews don't show
// a blank pane that then pops in (UX-MAC_FILES-015).
private struct PreviewWebView: View {
    let html: String
    let baseURL: URL?
    @State private var firstPaintDone = false

    var body: some View {
        ZStack {
            WebHTMLView(html: html, baseURL: baseURL) { firstPaintDone = true }
            if !firstPaintDone {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.Palette.bg)
                    .accessibilityIdentifier("files.preview.loading")
            }
        }
    }
}

private struct WebHTMLView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    var onFirstPaint: (() -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }

    // Only reload when the HTML actually changes. Previously every unrelated @Published change
    // (sync label, dirty flag) re-ran updateNSView and reloaded the web view, causing a full
    // reflow/flash and CPU spike — amplified in split mode while typing (PERF-MAC_FILES-006).
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        view.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFirstPaint: onFirstPaint) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        private let onFirstPaint: (() -> Void)?
        private var firstPaintReported = false

        init(onFirstPaint: (() -> Void)?) {
            self.onFirstPaint = onFirstPaint
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !firstPaintReported else { return }
            firstPaintReported = true
            onFirstPaint?()
        }
    }
}

private struct WebFileView: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    // Skip the reload when the URL is unchanged so unrelated state updates don't reload the PDF
    // (PERF-MAC_FILES-006).
    func updateNSView(_ view: WKWebView, context: Context) {
        guard let url, context.coordinator.lastURL != url else { return }
        context.coordinator.lastURL = url
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
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
        // Native Cmd+F find-in-file over the editor via NSTextView's built-in find bar
        // (IMP-MAC_FILES-001). The responder chain routes Cmd+F to performTextFinderAction:
        // automatically once the find bar is enabled.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
        let ruler = CodeLineNumberRulerView(textView: textView)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = ruler
        context.coordinator.lineNumberRuler = ruler
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            context.coordinator.applyHighlight(to: textView)
            textView.selectedRanges = selectedRanges
            context.coordinator.lineNumberRuler?.needsDisplay = true
        }
        // When text is unchanged the edit originated from the text view itself and was
        // already highlighted in textDidChange; re-highlighting here is redundant (PERF-MAC_FILES-001/008).
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: (String) -> Void
        weak var textView: NSTextView?
        weak var lineNumberRuler: CodeLineNumberRulerView?
        private var applyingHighlight = false

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onChange(textView.string)
            highlightEditedRange(in: textView)
            lineNumberRuler?.needsDisplay = true
        }

        /// Re-highlight only the paragraph(s) touched by the last edit instead of the whole
        /// document, keeping per-keystroke cost bounded for large files (PERF-MAC_FILES-001).
        /// Mutates attributes in place over the changed range; never touches characters.
        private func highlightEditedRange(in textView: NSTextView) {
            guard !applyingHighlight, let storage = textView.textStorage else { return }
            applyingHighlight = true
            defer { applyingHighlight = false }
            let nsText = storage.string as NSString
            // editedRange covers the just-changed characters; expand to whole paragraphs so
            // multi-line tokens (strings/comments) re-tokenize cleanly.
            let edited = storage.editedRange.location == NSNotFound
                ? NSRange(location: 0, length: nsText.length)
                : storage.editedRange
            let clampedLocation = min(edited.location, nsText.length)
            let safeEdited = NSRange(location: clampedLocation,
                                     length: min(edited.length, nsText.length - clampedLocation))
            let paragraphRange = nsText.paragraphRange(for: safeEdited)
            storage.beginEditing()
            storage.setAttributes(codeBaseAttributes, range: paragraphRange)
            nsText.enumerateSubstrings(in: paragraphRange, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
                let lineText = nsText.substring(with: range)
                applyHighlightSpans(highlightCodeLine(lineText), lineRange: range, to: storage)
            }
            storage.endEditing()
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
            lineNumberRuler?.needsDisplay = true
            applyingHighlight = false
        }
    }
}

private final class CodeLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lastVisibleGlyphRange = NSRange(location: NSNotFound, length: 0)
    private let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(red: 0.45, green: 0.47, blue: 0.50, alpha: 1)
    ]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Coalesce scroll-driven redraws: only repaint when the set of visible lines actually changes,
    // not on every bounds tick (e.g. horizontal scroll, sub-pixel jitter) (PERF-MAC_FILES-012).
    @objc private func boundsChanged() {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let clipView = textView.enclosingScrollView?.contentView else {
            needsDisplay = true
            return
        }
        let glyphRange = layoutManager.glyphRange(forBoundingRect: clipView.bounds, in: textContainer)
        guard !NSEqualRanges(glyphRange, lastVisibleGlyphRange) else { return }
        lastVisibleGlyphRange = glyphRange
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let clipView = textView.enclosingScrollView?.contentView else { return }
        NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1).setFill()
        bounds.fill()

        let visibleRect = clipView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        guard glyphRange.location < layoutManager.numberOfGlyphs else { return }
        let text = textView.string as NSString
        var lineNumber = text.substring(to: layoutManager.characterIndexForGlyph(at: glyphRange.location))
            .filter { $0 == "\n" }
            .count + 1
        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var lineRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange, withoutAdditionalLayout: true)
            let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY
            let value = "\(lineNumber)" as NSString
            let size = value.size(withAttributes: attributes)
            value.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + 1), withAttributes: attributes)
            glyphIndex = NSMaxRange(lineRange)
            lineNumber += 1
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
