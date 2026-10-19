import XCTest
@testable import AppShell
import CoreModel
import SocketServer

/// Drives the shipped `FilesViewModel` tab behavior through the same router
/// calls the real Files surface uses when a row is activated.
@MainActor
final class FilesOpenTabsTests: XCTestCase {
    private final class FakeRouter: FilesSurfaceRouting {
        var state: [String: JSONValue] = [
            "current_directory": .string(""),
            "reader_mode": .string("source"),
            "dirty_paths": .array([]),
        ]
        var listings: [String: [JSONValue]] = [:]
        var contents: [String: String] = [:]
        var operations: [String] = []
        var sessionPaths: [String: String] = [:]

        func filesEditClose(sessionID: String) throws -> JSONValue {
            operations.append("close:\(sessionID)")
            return .object(["ok": .bool(true)])
        }

        func filesStateGet(surface: SurfaceID) throws -> JSONValue { .object(state) }

        func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue {
            let relative = path ?? ""
            return .object([
                "relative_path": .string(relative),
                "entries": .array(listings[relative] ?? []),
            ])
        }

        func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue {
            for (key, value) in patch { state[key] = value }
            state["revision"] = .number(Double((state["revision"]?.intValue ?? 0) + 1))
            return .object(state)
        }

        func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue {
            let id = "session-\(path)"
            sessionPaths[id] = path
            return .object([
                "surface_id": .string(surface.value.uuidString),
                "path": .string(path),
                "session_id": .string(id),
                "draft_revision": .number(1),
                "dirty": .bool(false),
                "content": .string(contents[path] ?? ""),
            ])
        }

        func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue {
            .object(["content": .string(contents[path] ?? "")])
        }

        func filesEditSave(sessionID: String) throws -> JSONValue {
            let path = sessionPaths[sessionID] ?? ""
            operations.append("save:\(path)")
            return .object([
                "session_id": .string(sessionID),
                "path": .string(path),
                "draft_revision": .number(2),
                "dirty": .bool(false),
                "content": .string(contents[path] ?? ""),
            ])
        }

        func filesEditDiscard(sessionID: String) throws -> JSONValue {
            .object(["session_id": .string(sessionID), "dirty": .bool(false)])
        }

        func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue {
            operations.append("create:\(path)")
            contents[path] = content
            return Self.fileEntry(path)
        }

        func fsWorkspaceCreateDirectory(workspace: WorkspaceID, path: String) throws -> JSONValue {
            operations.append("create:\(path)")
            return Self.fileEntry(path, isDirectory: true)
        }

        func fsWorkspaceMoveItem(workspace: WorkspaceID, sourcePath: String, destinationDirectoryPath: String) throws -> JSONValue {
            .object(["ok": .bool(true)])
        }

        func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue {
            let renamedPath = (path as NSString).deletingLastPathComponent.isEmpty
                ? newName
                : "\((path as NSString).deletingLastPathComponent)/\(newName)"
            operations.append("rename:\(path)->\(renamedPath)")
            contents[renamedPath] = contents.removeValue(forKey: path)
            return Self.fileEntry(renamedPath)
        }

        func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor {
            SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent)
        }

        func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor {
            SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent)
        }

        func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue {
            let path = sessionPaths[sessionID] ?? ""
            let ns = (contents[path] ?? "") as NSString
            contents[path] = ns.replacingCharacters(in: NSRange(location: rangeLocation, length: rangeLength), with: replacement)
            return .object([
                "session_id": .string(sessionID),
                "path": .string(path),
                "draft_revision": .number(Double(baseDraftRevision + 1)),
                "dirty": .bool(true),
                "content": .string(contents[path] ?? ""),
            ])
        }

        static func fileEntry(_ relativePath: String, isDirectory: Bool = false) -> JSONValue {
            fileEntry(relativePath: relativePath, absolutePath: "/workspace/\(relativePath)", isDirectory: isDirectory)
        }

        static func fileEntry(relativePath: String, absolutePath: String, isDirectory: Bool = false) -> JSONValue {
            let name = (relativePath as NSString).lastPathComponent
            return .object([
                "name": .string(name),
                "path": .string(absolutePath),
                "relative_path": .string(relativePath),
                "type": .string(isDirectory ? "directory" : "file"),
                "size": .number(0),
                "is_hidden": .bool(name.hasPrefix(".")),
                "identity": .object([
                    "kind": .string(isDirectory ? "directory" : "text"),
                    "mime": .string(isDirectory ? "inode/directory" : "text/plain"),
                    "is_editable": .bool(!isDirectory),
                    "editability_reason": .string("editable"),
                    "language": .string("swift"),
                ]),
            ])
        }
    }

    private func makeModel(router: FakeRouter, provider: (any InlineCompletionProviding)? = nil) -> FilesViewModel {
        FilesViewModel(
            surfaceID: SurfaceID(),
            workspaceID: WorkspaceID(),
            root: "/workspace",
            router: router,
            inlineCompletionProvider: provider
        )
    }

    private func prepare(_ router: FakeRouter) -> [FileEntry] {
        let a = FakeRouter.fileEntry("a.swift")
        let b = FakeRouter.fileEntry("b.swift")
        router.listings[""] = [a, b]
        router.contents["a.swift"] = "let a = 1"
        router.contents["b.swift"] = "let b = 2"
        return [a, b].compactMap(FileEntry.init(value:))
    }

    func test_explorerActivationAddsAndFocusesTabs() {
        let router = FakeRouter()
        let entries = prepare(router)
        let model = makeModel(router: router)
        defer { model.close() }
        model.loadDirectory("")

        model.select(entries[0])
        model.select(entries[1])

        XCTAssertEqual(model.openTabs.map(\.relativePath), ["a.swift", "b.swift"],
            "opening two files from the explorer must create two tabs in order")
        XCTAssertEqual(model.selectedPath, "b.swift",
            "the most recently activated file must be the active tab")
        XCTAssertEqual(model.draftText, "let b = 2",
            "the active tab must show that file's content")
        XCTAssertEqual(router.state["open_tabs"], .array([.string("a.swift"), .string("b.swift")]),
            "open tabs must be persisted for reopen")
    }

    func test_activatingAnEarlierTabRestoresItsDraft() {
        let router = FakeRouter()
        let entries = prepare(router)
        let model = makeModel(router: router)
        defer { model.close() }
        model.loadDirectory("")
        model.select(entries[0])
        model.select(entries[1])

        model.activateTab(entries[0])

        XCTAssertEqual(model.selectedPath, "a.swift")
        XCTAssertEqual(model.draftText, "let a = 1",
            "switching tabs must restore that file's content, not leave the other tab's text")
    }

    // MARK: Explorer actions on the shipped model

    func test_createFileCreatesUnderCurrentDirectoryAndOpensIt() {
        let router = FakeRouter()
        _ = prepare(router)
        let model = makeModel(router: router)
        defer { model.close() }
        model.loadDirectory("")

        model.createFile(named: " New.swift ")

        XCTAssertTrue(router.operations.contains("create:New.swift"),
            "the explorer New File action must create the trimmed name in the current directory")
        XCTAssertEqual(model.openTabs.map(\.relativePath), ["New.swift"],
            "a newly created file opens in a tab like VS Code")
        XCTAssertEqual(model.selectedPath, "New.swift")
    }

    func test_createFolderCreatesDirectoryWithoutOpeningATab() {
        let router = FakeRouter()
        _ = prepare(router)
        let model = makeModel(router: router)
        defer { model.close() }
        model.loadDirectory("")

        model.createFolder(named: "Sources")

        XCTAssertTrue(router.operations.contains("create:Sources"),
            "the explorer New Folder action must reach the directory RPC")
        XCTAssertTrue(model.openTabs.isEmpty, "creating a folder must not open an editor tab")
    }

    func test_expandAndCollapseFetchesChildrenLazily() {
        let router = FakeRouter()
        router.listings[""] = [FakeRouter.fileEntry("src", isDirectory: true)]
        router.listings["src"] = [FakeRouter.fileEntry("src/App.swift")]
        let model = makeModel(router: router)
        defer { model.close() }
        model.loadDirectory("")
        let directory = model.entries[0]

        model.toggleExpand(directory)
        XCTAssertTrue(model.isExpanded(directory))
        XCTAssertEqual(model.childEntries(for: directory).map(\.relativePath), ["src/App.swift"],
            "expanding a folder must show its children from the directory listing")

        model.toggleExpand(directory)
        XCTAssertFalse(model.isExpanded(directory),
            "clicking the disclosure again must collapse the folder")
    }

    func test_renameOpenFileUpdatesItsTabAndSelection() {
        let router = FakeRouter()
        let entries = prepare(router)
        let model = makeModel(router: router)
        defer { model.close() }
        model.loadDirectory("")
        model.select(entries[0])

        model.rename(entries[0], to: "renamed.swift")

        XCTAssertTrue(router.operations.contains("rename:a.swift->renamed.swift"))
        XCTAssertEqual(model.openTabs.map(\.relativePath), ["renamed.swift"],
            "renaming the active file must rename its tab, not leave a stale path")
        XCTAssertEqual(model.selectedPath, "renamed.swift")
    }

    func test_deleteOpenFileRemovesItsTabAndTheFileFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-explorer-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("gone.swift")
        try "let gone = true".write(to: file, atomically: true, encoding: .utf8)

        let router = FakeRouter()
        router.listings[""] = [FakeRouter.fileEntry(relativePath: "gone.swift", absolutePath: file.path)]
        router.contents["gone.swift"] = "let gone = true"
        let model = FilesViewModel(surfaceID: SurfaceID(), workspaceID: WorkspaceID(), root: directory.path, router: router)
        defer { model.close() }
        model.loadDirectory("")
        model.select(model.entries[0])

        model.delete([model.entries[0]])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        XCTAssertTrue(model.openTabs.isEmpty,
            "deleting the open file must close its editor tab")
        XCTAssertNil(model.selectedEntry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
            "the explorer Delete action moves the file out of the workspace")
    }

    func test_editingAndSavingTheActiveTabWritesTheNewContentThroughTheSession() {
        let router = FakeRouter()
        let entries = prepare(router)
        let model = makeModel(router: router)
        defer { model.close() }
        model.loadDirectory("")
        model.select(entries[0])

        model.draftText = "let a = 42"
        model.editorChanged(model.draftText)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(router.contents["a.swift"], "let a = 42",
            "editing must stream the draft to the open session")
        XCTAssertTrue(model.isDirty)

        model.save()
        XCTAssertTrue(router.operations.contains("save:a.swift"),
            "Save must reach the host session for the active file")
        XCTAssertFalse(model.isDirty, "a successful save clears the dirty state")
        XCTAssertEqual(router.contents["a.swift"], "let a = 42",
            "the saved content must round-trip on disk through the session")
    }

    func test_closingActiveTabActivatesTheNeighbour() {
        let router = FakeRouter()
        let entries = prepare(router)
        let model = makeModel(router: router)
        defer { model.close() }
        model.loadDirectory("")
        model.select(entries[0])
        model.select(entries[1])

        model.closeTab(entries[1])

        XCTAssertEqual(model.openTabs.map(\.relativePath), ["a.swift"])
        XCTAssertEqual(model.selectedPath, "a.swift",
            "closing the active tab must focus the remaining neighbour instead of an empty reader")
        XCTAssertEqual(model.draftText, "let a = 1")
    }

    func test_closingLastTabClearsTheReader() {
        let router = FakeRouter()
        let entries = prepare(router)
        let model = makeModel(router: router)
        defer { model.close() }
        model.loadDirectory("")
        model.select(entries[0])

        model.closeTab(entries[0])

        XCTAssertTrue(model.openTabs.isEmpty)
        XCTAssertNil(model.selectedEntry)
        XCTAssertEqual(model.draftText, "")
    }

    func test_persistedTabsAreRestoredOnLaunch() {
        let router = FakeRouter()
        _ = prepare(router)
        router.state["open_tabs"] = .array([.string("a.swift"), .string("b.swift")])
        router.state["selected_path"] = .string("b.swift")
        let model = makeModel(router: router)
        defer { model.close() }

        model.loadInitialState()

        XCTAssertEqual(model.openTabs.map(\.relativePath), ["a.swift", "b.swift"],
            "tabs persisted in files state must come back after reopening MacCode")
        XCTAssertEqual(model.selectedPath, "b.swift")
        XCTAssertEqual(model.draftText, "let b = 2")
    }
}
