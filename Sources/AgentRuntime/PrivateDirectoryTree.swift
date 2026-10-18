import CryptoKit
import Darwin
import Foundation

public enum PrivateDirectoryTree {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let isDirectory: Bool
        public let byteCount: Int64
        public let sha256: String?

        public init(path: String, isDirectory: Bool, byteCount: Int64, sha256: String?) {
            self.path = path
            self.isDirectory = isDirectory
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    private static let maximumDepth = 64
    private static let maximumEntries = 100_000
    private static let bufferSize = 64 * 1024

    private static func fail(_ operation: String, _ path: String, _ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "\(operation) failed for \(path)"])
    }

    private static func component(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw fail("invalid path component", name, EINVAL)
        }
    }

    private static func identity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode && lhs.st_size == rhs.st_size && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func statChild(_ name: String, at fd: Int32) throws -> stat {
        try component(name)
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw fail("stat", name) }
        return info
    }

    private static func names(_ fd: Int32) throws -> [String] {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw fail("open directory", "") }
        guard let directory = fdopendir(copy) else {
            let code = errno
            Darwin.close(copy)
            throw fail("open directory stream", "", code)
        }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let item = readdir(directory) else {
                if errno != 0 { throw fail("read directory", "") }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer -> String in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                guard result.count < maximumEntries else { throw fail("maximum entry count exceeded", "", EOVERFLOW) }
                result.append(name)
            }
        }
        return result.sorted()
    }

    public static func childNames(_ directory: PrivateDirectory) throws -> [String] {
        try names(directory.descriptor)
    }

    private static func regular(_ info: stat, _ path: String) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else {
            throw fail("unsupported file", path, EINVAL)
        }
    }

    private static func scan(_ directory: PrivateDirectory, prefix: String, depth: Int, excluding: Set<String>, count: inout Int, into result: inout [Entry]) throws {
        guard depth <= maximumDepth else { throw fail("maximum depth exceeded", prefix, EOVERFLOW) }
        for name in try names(directory.descriptor) {
            if depth == 0 && excluding.contains(name) { continue }
            try component(name)
            count += 1
            guard count <= maximumEntries else { throw fail("maximum entry count exceeded", prefix, EOVERFLOW) }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let info = try statChild(name, at: directory.descriptor)
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                let child = try directory.child(name, create: false)
                defer { child.close() }
                var opened = stat()
                guard fstat(child.descriptor, &opened) == 0, identity(info, opened) else { throw fail("directory changed", path, EBUSY) }
                try scan(child, prefix: path, depth: depth + 1, excluding: [], count: &count, into: &result)
                var after = stat()
                var entryAfter = stat()
                guard fstat(child.descriptor, &after) == 0, fstatat(directory.descriptor, name, &entryAfter, AT_SYMLINK_NOFOLLOW) == 0, identity(opened, after), identity(opened, entryAfter) else { throw fail("directory changed", path, EBUSY) }
                result.append(Entry(path: path, isDirectory: true, byteCount: 0, sha256: nil))
            } else {
                try regular(info, path)
                let fd = openat(directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw fail("open file", path) }
                defer { Darwin.close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, identity(info, opened) else { throw fail("file changed", path, EBUSY) }
                var hasher = SHA256()
                var remaining = info.st_size
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while remaining > 0 {
                    let amount = min(remaining, Int64(buffer.count))
                    let readCount = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, min(bufferSize, Int(amount))) }
                    guard readCount > 0 else { throw fail("read file", path) }
                    hasher.update(data: Data(buffer.prefix(readCount)))
                    remaining -= Int64(readCount)
                }
                var after = stat()
                var entryAfter = stat()
                guard fstat(fd, &after) == 0, fstatat(directory.descriptor, name, &entryAfter, AT_SYMLINK_NOFOLLOW) == 0, identity(opened, after), identity(opened, entryAfter) else { throw fail("file changed", path, EBUSY) }
                result.append(Entry(path: path, isDirectory: false, byteCount: info.st_size, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()))
            }
        }
    }

    public static func inventory(_ directory: PrivateDirectory, excludingRootNames: Set<String> = []) throws -> [Entry] {
        let before = try names(directory.descriptor)
        var rootBefore = stat()
        guard fstat(directory.descriptor, &rootBefore) == 0 else { throw fail("stat directory", directory.path) }
        var result: [Entry] = []
        var count = 0
        try scan(directory, prefix: "", depth: 0, excluding: excludingRootNames, count: &count, into: &result)
        let after = try names(directory.descriptor)
        var rootAfter = stat()
        guard before == after, fstat(directory.descriptor, &rootAfter) == 0, identity(rootBefore, rootAfter) else { throw fail("directory changed", directory.path, EBUSY) }
        return result.sorted { $0.path < $1.path }
    }

    private static func copyTree(_ source: PrivateDirectory, _ destination: PrivateDirectory, prefix: String, depth: Int, count: inout Int, result: inout [Entry]) throws {
        guard depth <= maximumDepth else { throw fail("maximum depth exceeded", prefix, EOVERFLOW) }
        let before = try names(source.descriptor)
        var rootBefore = stat()
        guard fstat(source.descriptor, &rootBefore) == 0 else { throw fail("stat source directory", prefix) }
        for name in before {
            try copyChild(name, from: source, to: destination, prefix: prefix, depth: depth, count: &count, result: &result)
        }
        let after = try names(source.descriptor)
        var rootAfter = stat()
        guard before == after, fstat(source.descriptor, &rootAfter) == 0, identity(rootBefore, rootAfter) else { throw fail("directory changed", prefix, EBUSY) }
        try destination.synchronize()
    }

    public static func copy(from source: PrivateDirectory, to destination: PrivateDirectory, excludingRootNames: Set<String> = []) throws -> [Entry] {
        guard try names(destination.descriptor).isEmpty else { throw fail("destination not empty", destination.path, EEXIST) }
        do {
            var result: [Entry] = []
            var count = 0
            let before = try names(source.descriptor)
            var rootBefore = stat()
            guard fstat(source.descriptor, &rootBefore) == 0 else { throw fail("stat source directory", source.path) }
            for name in before where !excludingRootNames.contains(name) {
                try copyChild(name, from: source, to: destination, prefix: "", depth: 0, count: &count, result: &result)
            }
            let after = try names(source.descriptor)
            var rootAfter = stat()
            guard before == after, fstat(source.descriptor, &rootAfter) == 0, identity(rootBefore, rootAfter) else { throw fail("directory changed", source.path, EBUSY) }
            try destination.synchronize()
            return result.sorted { $0.path < $1.path }
        } catch {
            try removeContents(destination)
            throw error
        }
    }

    private static func copyChild(_ name: String, from source: PrivateDirectory, to destination: PrivateDirectory, prefix: String, depth: Int, count: inout Int, result: inout [Entry]) throws {
        try component(name)
        guard depth <= maximumDepth else { throw fail("maximum depth exceeded", prefix, EOVERFLOW) }
        count += 1
        guard count <= maximumEntries else { throw fail("maximum entry count exceeded", prefix, EOVERFLOW) }
        let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
        let info = try statChild(name, at: source.descriptor)
        if (info.st_mode & S_IFMT) == S_IFDIR {
            guard mkdirat(destination.descriptor, name, 0o700) == 0 else { throw fail("create directory", path) }
            let s = try source.child(name, create: false)
            let d = try destination.child(name, create: false)
            defer { s.close(); d.close() }
            var opened = stat()
            guard fstat(s.descriptor, &opened) == 0, identity(info, opened) else { throw fail("source directory changed", path, EBUSY) }
            try copyTree(s, d, prefix: path, depth: depth + 1, count: &count, result: &result)
            var after = stat()
            var entryAfter = stat()
            guard fstat(s.descriptor, &after) == 0, fstatat(source.descriptor, name, &entryAfter, AT_SYMLINK_NOFOLLOW) == 0, identity(info, after), identity(info, entryAfter) else { throw fail("directory changed", path, EBUSY) }
            result.append(Entry(path: path, isDirectory: true, byteCount: 0, sha256: nil))
            return
        }
        try regular(info, path)
        let sfd = openat(source.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sfd >= 0 else { throw fail("open source", path) }
        defer { Darwin.close(sfd) }
        var opened = stat()
        guard fstat(sfd, &opened) == 0, identity(info, opened) else { throw fail("source changed", path, EBUSY) }
        let dfd = openat(destination.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard dfd >= 0 else { throw fail("create file", path) }
        defer { Darwin.close(dfd) }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var remaining = info.st_size
        while remaining > 0 {
            let amount = buffer.withUnsafeMutableBytes { read(sfd, $0.baseAddress, min(bufferSize, Int(remaining))) }
            guard amount > 0 else { throw fail("read source", path) }
            hasher.update(data: Data(buffer.prefix(amount)))
            var written = 0
            while written < amount {
                let n = buffer.withUnsafeBytes { write(dfd, $0.baseAddress!.advanced(by: written), amount - written) }
                guard n > 0 else { throw fail("write destination", path) }
                written += n
            }
            total += Int64(amount)
            remaining -= Int64(amount)
        }
        var after = stat()
        var entryAfter = stat()
        guard fstat(sfd, &after) == 0, fstatat(source.descriptor, name, &entryAfter, AT_SYMLINK_NOFOLLOW) == 0, identity(opened, after), identity(opened, entryAfter) else { throw fail("source changed", path, EBUSY) }
        guard total == info.st_size, fsync(dfd) == 0 else { throw fail("sync destination", path) }
        result.append(Entry(path: path, isDirectory: false, byteCount: total, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()))
    }

    private static func removeContents(_ directory: PrivateDirectory) throws {
        for name in try names(directory.descriptor) { try removeChild(name, from: directory) }
        try directory.synchronize()
    }

    public static func readFile(_ name: String, in directory: PrivateDirectory, maximumBytes: Int) throws -> Data {
        try component(name)
        guard maximumBytes >= 0 else { throw fail("invalid byte limit", name, EINVAL) }
        let info = try statChild(name, at: directory.descriptor)
        try regular(info, name)
        guard info.st_size <= maximumBytes else { throw fail("file exceeds byte limit", name, EFBIG) }
        let fd = openat(directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw fail("open file", name) }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, identity(info, opened) else { throw fail("file changed", name, EBUSY) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let amount = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, bufferSize) }
            guard amount >= 0 else { throw fail("read file", name) }
            if amount == 0 { break }
            guard data.count <= maximumBytes - amount else { throw fail("file exceeds byte limit", name, EFBIG) }
            data.append(contentsOf: buffer.prefix(amount))
        }
        var after = stat()
        var entryAfter = stat()
        guard Int64(data.count) == info.st_size, fstat(fd, &after) == 0, fstatat(directory.descriptor, name, &entryAfter, AT_SYMLINK_NOFOLLOW) == 0, identity(opened, after), identity(opened, entryAfter) else { throw fail("file changed", name, EBUSY) }
        return data
    }

    public static func writeFile(_ name: String, data: Data, in directory: PrivateDirectory) throws {
        try component(name)
        let fd = openat(directory.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw fail("create file", name) }
        var success = false
        defer { Darwin.close(fd); if !success { _ = unlinkat(directory.descriptor, name, 0) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard amount > 0 else { throw fail("write file", name) }
                offset += amount
            }
        }
        guard fsync(fd) == 0 else { throw fail("sync file", name) }
        try directory.synchronize()
        success = true
    }

    public static func renameChild(_ name: String, from source: PrivateDirectory, to destination: PrivateDirectory, as newName: String) throws {
        try component(name); try component(newName)
        guard renameatx_np(source.descriptor, name, destination.descriptor, newName, UInt32(RENAME_EXCL)) == 0 else { throw fail("rename child", "\(name) -> \(newName)") }
        try source.synchronize()
        if source.descriptor != destination.descriptor { try destination.synchronize() }
    }

    public static func removeChild(_ name: String, from directory: PrivateDirectory) throws {
        try component(name)
        let info = try statChild(name, at: directory.descriptor)
        if (info.st_mode & S_IFMT) == S_IFDIR {
            let child = try directory.child(name, create: false)
            defer { child.close() }
            var opened = stat()
            guard fstat(child.descriptor, &opened) == 0, identity(info, opened) else { throw fail("directory changed before removal", name, EBUSY) }
            try removeContents(child)
            var entryAfter = stat()
            guard fstatat(directory.descriptor, name, &entryAfter, AT_SYMLINK_NOFOLLOW) == 0,
                  entryAfter.st_dev == opened.st_dev, entryAfter.st_ino == opened.st_ino else { throw fail("directory changed during removal", name, EBUSY) }
            guard unlinkat(directory.descriptor, name, AT_REMOVEDIR) == 0 else { throw fail("remove directory", name) }
        } else {
            try regular(info, name)
            guard unlinkat(directory.descriptor, name, 0) == 0 else { throw fail("remove file", name) }
        }
        try directory.synchronize()
        var remaining = stat()
        guard fstatat(directory.descriptor, name, &remaining, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw fail("verify removal", name, EBUSY) }
    }
}
