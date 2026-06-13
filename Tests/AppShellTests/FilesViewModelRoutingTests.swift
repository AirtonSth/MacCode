import XCTest
@testable import AppShell
import CoreModel
import SocketServer

@MainActor
final class FilesViewModelRoutingTests: XCTestCase {
    private final class FakeFilesRouter: FilesSurfaceRouting {
        var state: [String: JSONValue] = [
            "current_directory": .string(""),
            "reader_mode": .string("source"),
            "dirty_paths": .array([])
        ]
        var listings: [String: [JSONValue]] = [:]
        var contents: [String: String] = [:]
        var operations: [String] = []
        var sessionPathByID: [String: String] = [:]

        func filesEditClose(sessionID: String) throws -> JSONValue {
            operations.append("close:\(sessionID)")
            return .object(["ok": .bool(true)])
        }

        func filesStateGet(surface: SurfaceID) throws -> JSONValue {
            .object(state)
        }

        func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue {
            let relativePath = path ?? ""
            return .object([
                "relative_path": .string(relativePath),
                "entries": .array(listings[relativePath] ?? [])
            ])
        }

        func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue {
            operations.append("state:\(patch.keys.sorted().joined(separator: ","))")
            for (key, value) in patch { state[key] = value }
            state["surface_id"] = .string(surface.value.uuidString)
            state["revision"] = .number(Double((state["revision"]?.intValue ?? 0) + 1))
            return .object(state)
        }

        func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue {
            operations.append("open:\(path)")
            sessionPathByID["session-\(path)"] = path
            return .object([
                "surface_id": .string(surface.value.uuidString),
                "path": .string(path),
                "session_id": .string("session-\(path)"),
                "draft_revision": .number(1),
                "dirty": .bool(false),
                "content": .string(contents[path] ?? "")
            ])
        }

        func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue {
            .object(["content": .string(contents[path] ?? "")])
        }

        func filesEditSave(sessionID: String) throws -> JSONValue {
            .object(["session_id": .string(sessionID), "dirty": .bool(false)])
        }

        func filesEditDiscard(sessionID: String) throws -> JSONValue {
            .object(["session_id": .string(sessionID), "dirty": .bool(false)])
        }

        func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue {
            operations.append("create:\(path)")
            contents[path] = content
            let parent = parentPath(for: path)
            let created = Self.fileEntry(path)
            listings[parent, default: []].append(created)
            return created
        }

        func fsWorkspaceCreateDirectory(workspace: WorkspaceID, path: String) throws -> JSONValue {
            let created = Self.fileEntry(path, isDirectory: true)
            listings[parentPath(for: path), default: []].append(created)
            listings[path] = []
            return created
        }

        func fsWorkspaceMoveItem(workspace: WorkspaceID, sourcePath: String, destinationDirectoryPath: String) throws -> JSONValue {
            operations.append("move:\(sourcePath)->\(destinationDirectoryPath)")
            return .object(["ok": .bool(true)])
        }

        func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue {
            let parent = parentPath(for: path)
            let renamedPath = parent.isEmpty ? newName : "\(parent)/\(newName)"
            operations.append("rename:\(path)->\(renamedPath)")
            listings[parent] = (listings[parent] ?? []).filter { value in
                value.objectValue?["relative_path"]?.stringValue != path
            }
            let renamed = Self.fileEntry(renamedPath)
            listings[parent, default: []].append(renamed)
            contents[renamedPath] = contents.removeValue(forKey: path) ?? ""
            return renamed
        }

        func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor {
            SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent)
        }

        func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor {
            SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent)
        }

        func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue {
            let path = sessionPathByID[sessionID] ?? ""
            return .object([
                "session_id": .string(sessionID),
                "path": .string(path),
                "draft_revision": .number(Double(baseDraftRevision + 1)),
                "dirty": .bool(true)
            ])
        }

        private func parentPath(for path: String) -> String {
            let parent = (path as NSString).deletingLastPathComponent
            return parent == "." ? "" : parent
        }

        static func fileEntry(_ relativePath: String, isDirectory: Bool = false) -> JSONValue {
            let name = (relativePath as NSString).lastPathComponent
            return .object([
                "name": .string(name),
                "path": .string("/workspace/\(relativePath)"),
                "relative_path": .string(relativePath),
                "type": .string(isDirectory ? "directory" : "file"),
                "size": .number(0),
                "is_hidden": .bool(name.hasPrefix(".")),
                "identity": .object([
                    "kind": .string(isDirectory ? "directory" : "text"),
                    "mime": .string(isDirectory ? "inode/directory" : "text/plain"),
                    "is_editable": .bool(!isDirectory),
                    "editability_reason": .string(isDirectory ? "directory" : "editable"),
                    "language": .string("text")
                ])
            ])
        }
    }

    private func makeModel(router: FakeFilesRouter) -> FilesViewModel {
        FilesViewModel(surfaceID: SurfaceID(), workspaceID: WorkspaceID(), root: "/workspace", router: router)
    }

    func test_loadDirectoryRendersEntriesAndPersistsCurrentDirectory() {
        let router = FakeFilesRouter()
        router.listings["src"] = [FakeFilesRouter.fileEntry("src/App.swift")]
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("src")

        XCTAssertEqual(model.currentDirectory, "src",
            "directory load must update the visible Files sidebar directory")
        XCTAssertEqual(model.entries.map(\.relativePath), ["src/App.swift"],
            "directory load must render entries returned by the router")
        XCTAssertEqual(router.state["current_directory"]?.stringValue, "src",
            "directory load must persist current_directory for restore/mirror clients")
    }

    func test_loadInitialStateDerivesParentDirectoryAndOpensSelectedFile() {
        let router = FakeFilesRouter()
        router.state["selected_path"] = .string("a/b/c.txt")
        router.listings["a/b"] = [FakeFilesRouter.fileEntry("a/b/c.txt")]
        router.contents["a/b/c.txt"] = "selected"
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadInitialState()

        XCTAssertEqual(model.currentDirectory, "a/b",
            "empty current_directory must restore from selected_path parent")
        XCTAssertEqual(model.selectedPath, "a/b/c.txt",
            "initial state must select the restored file entry")
        XCTAssertEqual(model.draftText, "selected",
            "initial state must open the selected editable file session")
    }

    func test_createFileTrimsNameCreatesUnderCurrentDirectoryAndOpensIt() {
        let router = FakeFilesRouter()
        router.listings["docs"] = []
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("docs")
        model.createFile(named: " notes.md ")

        XCTAssertTrue(router.operations.contains("create:docs/notes.md"),
            "createFile must trim dialog input and call create under currentDirectory")
        XCTAssertEqual(model.selectedPath, "docs/notes.md",
            "created files should become selected and opened")
        XCTAssertTrue(model.entries.contains { $0.relativePath == "docs/notes.md" },
            "directory entries should refresh after createFile")
    }

    func test_renameOpenFileClosesSessionBeforeRenameAndReopensRenamedEntry() {
        let router = FakeFilesRouter()
        router.listings[""] = [FakeFilesRouter.fileEntry("old.txt")]
        router.contents["old.txt"] = "old"
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("")
        let entry = model.entries[0]
        model.selectedEntry = entry
        model.loadFile(entry)
        router.operations.removeAll()
        model.rename(entry, to: "new.txt")

        XCTAssertEqual(Array(router.operations.prefix(2)), ["close:session-old.txt", "rename:old.txt->new.txt"],
            "renaming the open file must close its edit session before filesystem rename")
        XCTAssertEqual(model.selectedPath, "new.txt",
            "renamed open file should be reselected")
        XCTAssertTrue(router.operations.contains("open:new.txt"),
            "renamed open file should open a fresh edit session")
    }

    func test_dirtySessionCacheRestoresDraftWithoutReopeningHostSession() {
        let router = FakeFilesRouter()
        router.listings[""] = [
            FakeFilesRouter.fileEntry("a.txt"),
            FakeFilesRouter.fileEntry("b.txt")
        ]
        router.contents["a.txt"] = "clean a"
        router.contents["b.txt"] = "clean b"
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadDirectory("")
        let a = model.entries[0]
        let b = model.entries[1]
        model.loadFile(a)
        model.draftText = "dirty a"
        model.editorChanged("dirty a")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        model.loadFile(b)
        router.operations.removeAll()
        model.loadFile(a)

        XCTAssertEqual(model.draftText, "dirty a",
            "reselecting a dirty file must restore the cached local draft")
        XCTAssertFalse(router.operations.contains("open:a.txt"),
            "dirty cached sessions must not reopen from host and lose local draft state")
    }
}
