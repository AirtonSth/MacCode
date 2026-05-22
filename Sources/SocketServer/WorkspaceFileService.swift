import Foundation
import CryptoKit
import UniformTypeIdentifiers
import CoreModel

public enum WorkspaceFileLimits {
    public static let sampleBytes = 64 * 1024
    public static let readBytes = 2 * 1024 * 1024
    public static let editBytes = 2 * 1024 * 1024
}

public struct WorkspaceFileService: Sendable {
    public init() {}

    public func list(root: String, path: String?) throws -> JSONValue {
        let rootURL = try safeRoot(root)
        let directory = try resolve(root: rootURL, path: path, mustExist: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "not a directory", data: .string(directory.path))
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        let entries = children.map { child -> (Bool, String, JSONValue) in
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            let identity = (try? classify(root: rootURL, path: child.path)) ?? FileIdentity(
                kind: isDirectory ? "directory" : "unknown",
                mime: "application/octet-stream",
                uti: nil,
                ext: child.pathExtension.lowercased(),
                size: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate,
                isBinary: !isDirectory,
                isTextReadable: false,
                isEditable: false,
                editabilityReason: values?.isSymbolicLink == true ? "symlink outside workspace or unreadable" : "unreadable",
                language: nil
            )
            return (isDirectory, child.lastPathComponent, .object([
                "name": .string(child.lastPathComponent),
                "path": .string(child.path),
                "relative_path": .string(relativePath(root: rootURL, url: child)),
                "type": .string(isDirectory ? "directory" : "file"),
                "ext": .string(child.pathExtension.lowercased()),
                "size": .number(Double(identity.size)),
                "modified_at": identity.modifiedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                "is_hidden": .bool(child.lastPathComponent.hasPrefix(".")),
                "is_symlink": .bool(values?.isSymbolicLink == true),
                "identity": identity.json
            ]))
        }
        .sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 && !rhs.0 }
            return lhs.1.localizedCaseInsensitiveCompare(rhs.1) == .orderedAscending
        }
        .map { $0.2 }
        return .object([
            "root": .string(rootURL.path),
            "path": .string(directory.path),
            "relative_path": .string(relativePath(root: rootURL, url: directory)),
            "parent_path": parentPath(root: rootURL, url: directory).map { .string($0) } ?? .null,
            "entries": .array(entries)
        ])
    }

    public func read(root: String, path: String, maxBytes: Int? = nil) throws -> JSONValue {
        let rootURL = try safeRoot(root)
        let file = try resolve(root: rootURL, path: path, mustExist: true)
        let identity = try classify(root: rootURL, path: file.path)
        guard identity.kind != "directory" else {
            throw JSONRPCError(code: -32602, message: "not a file", data: .string(file.path))
        }
        guard identity.isTextReadable else {
            return .object([
                "path": .string(file.path),
                "relative_path": .string(relativePath(root: rootURL, url: file)),
                "kind": .string(identity.kind),
                "mime": .string(identity.mime),
                "size": .number(Double(identity.size)),
                "encoding": .null,
                "content": .null,
                "truncated": .bool(false),
                "identity": identity.json
            ])
        }
        let limit = max(0, min(maxBytes ?? WorkspaceFileLimits.readBytes, WorkspaceFileLimits.readBytes))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        let truncated = data.count > limit
        let clipped = truncated ? data.prefix(limit) : data[...]
        let decoded = try decodeText(Data(clipped))
        return .object([
            "path": .string(file.path),
            "relative_path": .string(relativePath(root: rootURL, url: file)),
            "kind": .string(identity.kind),
            "mime": .string(identity.mime),
            "size": .number(Double(identity.size)),
            "encoding": .string(decoded.encoding),
            "content": .string(decoded.text),
            "truncated": .bool(truncated),
            "identity": identity.json
        ])
    }

    public func previewURL(root: String, path: String) throws -> JSONValue {
        let rootURL = try safeRoot(root)
        let file = try resolve(root: rootURL, path: path, mustExist: true)
        let identity = try classify(root: rootURL, path: file.path)
        guard ["html", "image", "video", "pdf"].contains(identity.kind),
              let grant = DirectStaticFileRegistry.shared.register(fileURL: file) else {
            throw JSONRPCError(code: -32602, message: "preview unavailable", data: .string(file.path))
        }
        return .object([
            "url_path": .string(grant.routePath),
            "mime": .string(identity.mime),
            "expires_at": .number(Date().addingTimeInterval(60 * 60).timeIntervalSince1970)
        ])
    }

    public func classify(root: String, path: String) throws -> FileIdentity {
        try classify(root: try safeRoot(root), path: path)
    }

    public func resolvePath(root: String, path: String?, mustExist: Bool = true) throws -> String {
        try resolve(root: safeRoot(root), path: path, mustExist: mustExist).path
    }

    private func classify(root: URL, path: String) throws -> FileIdentity {
        let file = try resolve(root: root, path: path, mustExist: true)
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: file.path)
        let type = attrs[.type] as? FileAttributeType
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs[.modificationDate] as? Date
        let ext = file.pathExtension.lowercased()
        if type == .typeDirectory {
            return FileIdentity(kind: "directory", mime: "inode/directory", uti: "public.folder", ext: ext, size: size, modifiedAt: modified, isBinary: false, isTextReadable: false, isEditable: false, editabilityReason: "directory", language: nil)
        }
        let sample = try readSample(file: file)
        let probe = TextProbe(data: sample)
        let magic = MagicKind(data: sample, ext: ext)
        let uti = UTType(filenameExtension: ext)
        let language = languageName(ext: ext)
        let kind: String
        if let magicKind = magic.kind {
            kind = magicKind
        } else if ext == "md" || ext == "markdown" {
            kind = "markdown"
        } else if ext == "html" || ext == "htm" {
            kind = "html"
        } else if language != nil {
            kind = "code"
        } else if imageExtensions.contains(ext) {
            kind = "image"
        } else if videoExtensions.contains(ext) {
            kind = "video"
        } else if ext == "pdf" {
            kind = "pdf"
        } else if probe.isText || sample.isEmpty {
            kind = "text"
        } else {
            kind = "binary"
        }
        let isText = ["markdown", "html", "code", "text"].contains(kind) && probe.canDecode
        let writable = fm.isWritableFile(atPath: file.path)
        let isEditable = isText && size <= Int64(WorkspaceFileLimits.editBytes) && writable
        let reason: String
        if isEditable {
            reason = "editable \(kind)"
        } else if !isText {
            reason = kind == "binary" ? "binary or unknown file" : "\(kind) preview is read-only"
        } else if size > Int64(WorkspaceFileLimits.editBytes) {
            reason = "file is too large to edit"
        } else if !writable {
            reason = "file is not writable"
        } else {
            reason = "not editable"
        }
        return FileIdentity(
            kind: kind,
            mime: magic.mime ?? uti?.preferredMIMEType ?? fallbackMIME(ext: ext, kind: kind),
            uti: uti?.identifier,
            ext: ext,
            size: size,
            modifiedAt: modified,
            isBinary: !isText && kind != "directory",
            isTextReadable: isText,
            isEditable: isEditable,
            editabilityReason: reason,
            language: kind == "markdown" ? "markdown" : (kind == "html" ? "html" : language)
        )
    }

    private func safeRoot(_ root: String) throws -> URL {
        let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "workspace root not found", data: .string(root))
        }
        return url
    }

    private func resolve(root: URL, path: String?, mustExist: Bool) throws -> URL {
        let requested = path?.isEmpty == false ? path! : root.path
        let candidate: URL
        if requested.hasPrefix("/") || requested.hasPrefix("~") {
            candidate = URL(fileURLWithPath: (requested as NSString).expandingTildeInPath)
        } else {
            candidate = root.appendingPathComponent(requested)
        }
        let standardized = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path
        guard standardized.path == rootPath || standardized.path.hasPrefix(rootPath + "/") else {
            throw JSONRPCError(code: -32602, message: "path escapes workspace", data: .string(requested))
        }
        if mustExist && !FileManager.default.fileExists(atPath: standardized.path) {
            throw JSONRPCError(code: -32602, message: "not found", data: .string(standardized.path))
        }
        return standardized
    }

    private func readSample(file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: WorkspaceFileLimits.sampleBytes) ?? Data()
    }

    private func relativePath(root: URL, url: URL) -> String {
        let rootPath = root.path
        guard url.path != rootPath else { return "" }
        return String(url.path.dropFirst(rootPath.count + 1))
    }

    private func parentPath(root: URL, url: URL) -> String? {
        guard url.path != root.path else { return nil }
        return relativePath(root: root, url: url.deletingLastPathComponent())
    }
}

public struct FileIdentity: Sendable, Equatable {
    public let kind: String
    public let mime: String
    public let uti: String?
    public let ext: String
    public let size: Int64
    public let modifiedAt: Date?
    public let isBinary: Bool
    public let isTextReadable: Bool
    public let isEditable: Bool
    public let editabilityReason: String
    public let language: String?

    public var json: JSONValue {
        .object([
            "kind": .string(kind),
            "mime": .string(mime),
            "uti": uti.map { .string($0) } ?? .null,
            "ext": .string(ext),
            "size": .number(Double(size)),
            "modified_at": modifiedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
            "is_binary": .bool(isBinary),
            "is_text_readable": .bool(isTextReadable),
            "is_editable": .bool(isEditable),
            "editability_reason": .string(editabilityReason),
            "language": language.map { .string($0) } ?? .null
        ])
    }
}

public final class FileEditSessionStore: @unchecked Sendable {
    public static let shared = FileEditSessionStore()

    private struct Session {
        var id: String
        var surfaceID: SurfaceID
        var workspaceID: WorkspaceID
        var root: String
        var path: String
        var relativePath: String
        var baseHash: String
        var baseModifiedAt: Date?
        var draftRevision: Int
        var draftText: String
        var encoding: String
        var language: String?
        var dirty: Bool
        var activeWriterDevice: String?
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private let service = WorkspaceFileService()

    public func open(surfaceID: SurfaceID, workspaceID: WorkspaceID, root: String, path: String) throws -> JSONValue {
        let read = try service.read(root: root, path: path, maxBytes: WorkspaceFileLimits.editBytes)
        guard let body = read.objectValue,
              let identity = body["identity"]?.objectValue,
              identity["is_editable"]?.boolValue == true,
              let content = body["content"]?.stringValue,
              let absPath = body["path"]?.stringValue,
              let relPath = body["relative_path"]?.stringValue else {
            let reason = read.objectValue?["identity"]?.objectValue?["editability_reason"]?.stringValue ?? "file is not editable"
            throw JSONRPCError(code: -32602, message: reason, data: read)
        }
        let encoding = body["encoding"]?.stringValue ?? "utf-8"
        let data = try readEditableFileData(path: absPath)
        let id = UUID().uuidString
        let session = Session(
            id: id,
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            root: root,
            path: absPath,
            relativePath: relPath,
            baseHash: hash(data),
            baseModifiedAt: (try? FileManager.default.attributesOfItem(atPath: absPath)[.modificationDate]) as? Date,
            draftRevision: 1,
            draftText: content,
            encoding: encoding,
            language: identity["language"]?.stringValue,
            dirty: false,
            activeWriterDevice: nil
        )
        lock.lock()
        sessions[id] = session
        lock.unlock()
        let payload = sessionJSON(session, includeContent: true)
        EventBus.shared.publish(kind: "files.edit.opened", payload: .object(payload))
        return .object(payload)
    }

    public func applyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue {
        lock.lock()
        guard var session = sessions[sessionID] else {
            lock.unlock()
            throw JSONRPCError(code: -32602, message: "edit session not found", data: .string(sessionID))
        }
        guard session.draftRevision == baseDraftRevision else {
            let payload = sessionJSON(session, includeContent: true)
            lock.unlock()
            throw JSONRPCError(code: -32012, message: "draft revision conflict", data: .object(payload))
        }
        guard let range = Range(NSRange(location: rangeLocation, length: rangeLength), in: session.draftText) else {
            lock.unlock()
            throw JSONRPCError.invalidParams
        }
        session.draftText.replaceSubrange(range, with: replacement)
        session.draftRevision += 1
        session.dirty = true
        session.activeWriterDevice = deviceID
        sessions[sessionID] = session
        let payload = sessionJSON(session, includeContent: true, patch: [
            "range_utf16": .object(["location": .number(Double(rangeLocation)), "length": .number(Double(rangeLength))]),
            "replacement": .string(replacement)
        ], updatedBy: deviceID)
        lock.unlock()
        EventBus.shared.publish(kind: "files.edit.patch_applied", payload: .object(payload))
        return .object(payload)
    }

    public func save(sessionID: String) throws -> JSONValue {
        lock.lock()
        guard var session = sessions[sessionID] else {
            lock.unlock()
            throw JSONRPCError(code: -32602, message: "edit session not found", data: .string(sessionID))
        }
        do {
            let currentData = try readEditableFileData(path: session.path)
            guard hash(currentData) == session.baseHash else {
                let payload = sessionJSON(session, includeContent: true)
                lock.unlock()
                EventBus.shared.publish(kind: "files.edit.conflict", payload: .object(payload.merging(["reason": .string("disk_changed")]) { _, new in new }))
                throw JSONRPCError(code: -32013, message: "disk changed", data: .object(payload))
            }
            let data = encodeText(session.draftText, encoding: session.encoding)
            try atomicWrite(data, to: URL(fileURLWithPath: session.path))
            session.baseHash = hash(data)
            session.baseModifiedAt = (try? FileManager.default.attributesOfItem(atPath: session.path)[.modificationDate]) as? Date
            session.dirty = false
            sessions[sessionID] = session
            let payload = sessionJSON(session, includeContent: true).merging(["disk_hash": .string("sha256:\(session.baseHash)")]) { _, new in new }
            lock.unlock()
            EventBus.shared.publish(kind: "files.edit.saved", payload: .object(payload))
            return .object(payload)
        } catch {
            lock.unlock()
            throw error
        }
    }

    public func discard(sessionID: String) throws -> JSONValue {
        lock.lock()
        guard var session = sessions[sessionID] else {
            lock.unlock()
            throw JSONRPCError(code: -32602, message: "edit session not found", data: .string(sessionID))
        }
        do {
            let data = try readEditableFileData(path: session.path)
            let decoded = try decodeText(data)
            session.draftText = decoded.text
            session.encoding = decoded.encoding
            session.baseHash = hash(data)
            session.draftRevision += 1
            session.dirty = false
            sessions[sessionID] = session
            let payload = sessionJSON(session, includeContent: true)
            lock.unlock()
            EventBus.shared.publish(kind: "files.edit.discarded", payload: .object(payload))
            return .object(payload)
        } catch {
            lock.unlock()
            throw error
        }
    }

    public func close(sessionID: String) throws -> JSONValue {
        lock.lock()
        let removed = sessions.removeValue(forKey: sessionID)
        lock.unlock()
        guard let removed else {
            throw JSONRPCError(code: -32602, message: "edit session not found", data: .string(sessionID))
        }
        let payload = sessionJSON(removed, includeContent: false)
        EventBus.shared.publish(kind: "files.edit.closed", payload: .object(payload))
        return .object(payload)
    }

    public func session(sessionID: String) -> JSONValue? {
        lock.lock()
        let session = sessions[sessionID]
        lock.unlock()
        return session.map { .object(sessionJSON($0, includeContent: true)) }
    }

    private func readEditableFileData(path: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: WorkspaceFileLimits.editBytes + 1) ?? Data()
        guard data.count <= WorkspaceFileLimits.editBytes else {
            throw JSONRPCError(code: -32602, message: "file is too large to edit", data: .string(path))
        }
        return data
    }

    private func sessionJSON(_ s: Session, includeContent: Bool, patch: [String: JSONValue]? = nil, updatedBy: String? = nil) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "session_id": .string(s.id),
            "surface_id": .string(s.surfaceID.value.uuidString),
            "workspace_id": .string(s.workspaceID.value.uuidString),
            "path": .string(s.relativePath),
            "absolute_path": .string(s.path),
            "draft_revision": .number(Double(s.draftRevision)),
            "dirty": .bool(s.dirty),
            "encoding": .string(s.encoding),
            "language": s.language.map { .string($0) } ?? .null
        ]
        if includeContent { payload["content"] = .string(s.draftText) }
        if let patch { payload["patch"] = .object(patch) }
        if let updatedBy { payload["updated_by_device"] = .string(updatedBy) }
        return payload
    }
}

private struct MagicKind {
    let kind: String?
    let mime: String?

    init(data: Data, ext: String) {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { kind = "image"; mime = "image/png"; return }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { kind = "image"; mime = "image/jpeg"; return }
        if data.prefix(6) == Data("GIF87a".utf8) || data.prefix(6) == Data("GIF89a".utf8) { kind = "image"; mime = "image/gif"; return }
        if data.prefix(4) == Data("%PDF".utf8) { kind = "pdf"; mime = "application/pdf"; return }
        if data.count >= 12, data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
            kind = "image"; mime = "image/webp"; return
        }
        if data.count >= 12, String(data: data[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(data: data[8..<min(data.count, 16)], encoding: .ascii) ?? ""
            if brand.contains("heic") || brand.contains("avif") {
                kind = "image"; mime = ext == "avif" ? "image/avif" : "image/heic"; return
            }
            kind = "video"; mime = ext == "mov" ? "video/quicktime" : "video/mp4"; return
        }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { kind = "video"; mime = "video/webm"; return }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) || bytes.starts(with: [0x1F, 0x8B]) {
            kind = "binary"; mime = "application/octet-stream"; return
        }
        kind = nil
        mime = nil
    }
}

private struct TextProbe {
    let isText: Bool
    let canDecode: Bool

    init(data: Data) {
        guard !data.isEmpty else {
            isText = true
            canDecode = true
            return
        }
        let nulCount = data.filter { $0 == 0 }.count
        if nulCount > max(2, data.count / 10) {
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) || decodeLikelyUTF16(data) != nil {
                isText = true
                canDecode = true
            } else {
                isText = false
                canDecode = false
            }
            return
        }
        guard String(data: data, encoding: .utf8) != nil else {
            isText = false
            canDecode = false
            return
        }
        let printable = data.filter { byte in
            byte == 0x09 || byte == 0x0A || byte == 0x0D || (byte >= 0x20 && byte != 0x7F)
        }.count
        isText = Double(printable) / Double(max(data.count, 1)) > 0.85
        canDecode = isText
    }
}

private let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp", "svg", "avif"])
private let videoExtensions = Set(["mp4", "mov", "m4v", "webm"])

private func languageName(ext: String) -> String? {
    [
        "swift": "swift", "ts": "typescript", "tsx": "typescript", "js": "javascript", "jsx": "javascript",
        "py": "python", "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml",
        "xml": "xml", "css": "css", "scss": "scss", "sh": "shell", "bash": "shell",
        "zsh": "shell", "sql": "sql", "log": "log", "txt": "text", "c": "c", "h": "c",
        "cpp": "cpp", "hpp": "cpp", "rs": "rust", "go": "go", "rb": "ruby", "php": "php"
    ][ext]
}

private func fallbackMIME(ext: String, kind: String) -> String {
    switch kind {
    case "markdown": return "text/markdown; charset=utf-8"
    case "html": return "text/html; charset=utf-8"
    case "code", "text": return "text/plain; charset=utf-8"
    case "image": return "image/\(ext == "jpg" ? "jpeg" : ext)"
    case "video": return ext == "mov" ? "video/quicktime" : "video/\(ext)"
    case "pdf": return "application/pdf"
    default: return "application/octet-stream"
    }
}

private func decodeText(_ data: Data) throws -> (text: String, encoding: String) {
    if data.starts(with: [0xFF, 0xFE]) {
        let body = data.dropFirst(2)
        if let s = String(data: body, encoding: .utf16LittleEndian) { return (s, "utf-16le") }
    }
    if data.starts(with: [0xFE, 0xFF]) {
        let body = data.dropFirst(2)
        if let s = String(data: body, encoding: .utf16BigEndian) { return (s, "utf-16be") }
    }
    if let decoded = decodeLikelyUTF16(data) { return decoded }
    if let s = String(data: data, encoding: .utf8) { return (s, "utf-8") }
    throw JSONRPCError(code: -32602, message: "text decoding failed")
}

private func decodeLikelyUTF16(_ data: Data) -> (text: String, encoding: String)? {
    guard data.count >= 4 else { return nil }
    let bytes = [UInt8](data.prefix(WorkspaceFileLimits.sampleBytes))
    let evenNuls = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
    let oddNuls = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
    let pairs = max(bytes.count / 2, 1)
    if Double(oddNuls) / Double(pairs) > 0.6,
       let text = String(data: data, encoding: .utf16LittleEndian),
       utf16PrintableRatio(text) > 0.85 {
        return (text, "utf-16le")
    }
    if Double(evenNuls) / Double(pairs) > 0.6,
       let text = String(data: data, encoding: .utf16BigEndian),
       utf16PrintableRatio(text) > 0.85 {
        return (text, "utf-16be")
    }
    return nil
}

private func utf16PrintableRatio(_ text: String) -> Double {
    guard !text.isEmpty else { return 1 }
    let printable = text.unicodeScalars.filter { scalar in
        scalar == "\t" || scalar == "\n" || scalar == "\r" || (!CharacterSet.controlCharacters.contains(scalar) && scalar.value >= 0x20)
    }.count
    return Double(printable) / Double(max(text.unicodeScalars.count, 1))
}

private func encodeText(_ text: String, encoding: String) -> Data {
    switch encoding {
    case "utf-16le":
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian) ?? Data())
        return data
    case "utf-16be":
        var data = Data([0xFE, 0xFF])
        data.append(text.data(using: .utf16BigEndian) ?? Data())
        return data
    default:
        return text.data(using: .utf8) ?? Data()
    }
}

private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func atomicWrite(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: tmp, options: .atomic)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
}
