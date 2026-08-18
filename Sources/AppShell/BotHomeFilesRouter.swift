import Foundation
import CoreModel
import Persistence
import SocketServer
import Surfaces

/// FilesSurfaceRouting adapter that points FilesViewModel at a bot home.
/// Does not register a workspace, so fsWorkspace* cannot edit the advertised cwd.
@MainActor
final class BotHomeFilesRouter: FilesSurfaceRouting {
    let root: String
    let workspaceID: WorkspaceID
    var onDidSave: ((String, String) -> Void)?
    private(set) var lastOpenTabPath: String?
    private var state: [String: JSONValue] = [
        "current_directory": .string(""),
        "reader_mode": .string("source"),
        "dirty_paths": .array([])
    ]
    private let files = WorkspaceFileService()

    init(root: String, workspaceID: WorkspaceID) {
        self.root = root
        self.workspaceID = workspaceID
    }

    func filesEditClose(sessionID: String) throws -> JSONValue {
        try FileEditSessionStore.shared.close(sessionID: sessionID)
    }

    func filesStateGet(surface: SurfaceID) throws -> JSONValue {
        var next = state
        next["surface_id"] = .string(surface.value.uuidString)
        next["workspace_id"] = .string(workspaceID.value.uuidString)
        return .object(next)
    }

    func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue {
        Self.lockProjections(try files.list(root: root, path: path))
    }

    func filesStateUpdate(
        surface: SurfaceID,
        patch: [String: JSONValue],
        baseRevision: Int?,
        deviceID: String?
    ) throws -> JSONValue {
        for (key, value) in patch { state[key] = value }
        let revision = (state["revision"]?.intValue ?? 0) + 1
        state["revision"] = .number(Double(revision))
        state["surface_id"] = .string(surface.value.uuidString)
        state["updated_by_device"] = deviceID.map { .string($0) } ?? .null
        return .object(state)
    }

    func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue {
        try Self.rejectProjectionEdit(path)
        return try FileEditSessionStore.shared.open(
            surfaceID: surface,
            workspaceID: workspaceID,
            root: root,
            path: path
        )
    }

    func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue {
        try files.read(root: root, path: path, maxBytes: maxBytes)
    }

    func filesEditSave(sessionID: String) throws -> JSONValue {
        let result = try FileEditSessionStore.shared.save(sessionID: sessionID)
        if let body = result.objectValue,
           let path = body["path"]?.stringValue,
           let content = body["content"]?.stringValue {
            onDidSave?(path, content)
        }
        return result
    }

    func filesEditDiscard(sessionID: String) throws -> JSONValue {
        try FileEditSessionStore.shared.discard(sessionID: sessionID)
    }

    func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue {
        try files.createFile(root: root, path: path, content: content)
    }

    func fsWorkspaceCreateDirectory(workspace: WorkspaceID, path: String) throws -> JSONValue {
        try files.createDirectory(root: root, path: path)
    }

    func fsWorkspaceMoveItem(
        workspace: WorkspaceID,
        sourcePath: String,
        destinationDirectoryPath: String
    ) throws -> JSONValue {
        try files.moveItem(
            root: root,
            sourcePath: sourcePath,
            destinationDirectoryPath: destinationDirectoryPath
        )
    }

    func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue {
        try files.rename(root: root, path: path, newName: newName)
    }

    func filesOpenTab(
        workspace: WorkspaceID,
        sourceSurface: SurfaceID?,
        paneID: PaneID?,
        path: String
    ) throws -> SurfaceDescriptor {
        lastOpenTabPath = path
        return SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent)
    }

    func filesSplitTab(
        workspace: WorkspaceID,
        sourceSurface: SurfaceID?,
        paneID: PaneID?,
        direction: SplitDirection,
        path: String
    ) throws -> SurfaceDescriptor {
        return SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent)
    }

    func filesEditApplyPatch(
        sessionID: String,
        baseDraftRevision: Int,
        rangeLocation: Int,
        rangeLength: Int,
        replacement: String,
        deviceID: String?
    ) throws -> JSONValue {
        try FileEditSessionStore.shared.applyPatch(
            sessionID: sessionID,
            baseDraftRevision: baseDraftRevision,
            rangeLocation: rangeLocation,
            rangeLength: rangeLength,
            replacement: replacement,
            deviceID: deviceID
        )
    }

    static func lockProjections(_ value: JSONValue) -> JSONValue {
        guard var object = value.objectValue,
              var entries = object["entries"]?.arrayValue else { return value }
        entries = entries.map { entry in
            guard var body = entry.objectValue,
                  let relative = body["relative_path"]?.stringValue,
                  Self.isProjection(relative),
                  var identity = body["identity"]?.objectValue else { return entry }
            identity["is_editable"] = .bool(false)
            identity["editability_reason"] = .string("Generated projection")
            body["identity"] = .object(identity)
            return .object(body)
        }
        object["entries"] = .array(entries)
        return .object(object)
    }

    static func isProjection(_ relativePath: String) -> Bool {
        relativePath == BotHome.identityName || relativePath == BotHome.memoryName
    }

    static func rejectProjectionEdit(_ path: String) throws {
        guard isProjection(path) else { return }
        throw JSONRPCError(code: -32602, message: "Generated projection", data: .string(path))
    }
}
