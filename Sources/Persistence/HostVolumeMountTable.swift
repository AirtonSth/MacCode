import Foundation
import Darwin

// MARK: - Network / non-local mounts (TCC-safe discovery)

/// Discovers non-local mount points without opening them through FileManager.
///
/// WHY: Prefetching `URLResourceKey`s (or even `fileExists`) on an NFS/SMB child
/// such as `~/OrbStack` triggers the macOS “access files on a network volume”
/// TCC dialog. `getmntinfo` reads the kernel mount table only, so listing a
/// local parent can skip network-class children without prompting.
///
/// Lives in Persistence so SocketServer and AppShell can share it without a
/// circular AppShell → SocketServer dependency.
public enum HostVolumeMountTable: Sendable {
    /// Filesystem types that always require Network Volumes TCC when accessed.
    public static let networkFileSystemTypes: Set<String> = [
        "nfs", "smbfs", "afpfs", "webdav", "autofs", "cifs", "nsmb",
    ]

    /// Absolute standardized mount-on paths that are non-local / network-class.
    public static func nonLocalMountPaths(
        getMountInfo: () -> [(on: String, type: String, isLocal: Bool)] = {
            var mntbuf: UnsafeMutablePointer<statfs>?
            let count = getmntinfo(&mntbuf, MNT_NOWAIT)
            guard let mntbuf, count > 0 else { return [] }
            var rows: [(on: String, type: String, isLocal: Bool)] = []
            rows.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                let fs = mntbuf[i]
                // Copy fixed-size C arrays out first — exclusive access rules forbid
                // taking &fs.f_mntonname while also reading other fs fields.
                var onName = fs.f_mntonname
                var fsType = fs.f_fstypename
                let on = withUnsafeBytes(of: &onName) { raw -> String in
                    let base = raw.bindMemory(to: CChar.self).baseAddress!
                    return String(cString: base)
                }
                let type = withUnsafeBytes(of: &fsType) { raw -> String in
                    let base = raw.bindMemory(to: CChar.self).baseAddress!
                    return String(cString: base)
                }
                let isLocal = (fs.f_flags & UInt32(MNT_LOCAL)) != 0
                rows.append((on: on, type: type, isLocal: isLocal))
            }
            return rows
        }
    ) -> [String] {
        getMountInfo().compactMap { row in
            let networkType = networkFileSystemTypes.contains(row.type.lowercased())
            guard !row.isLocal || networkType else { return nil }
            let on = (row.on as NSString).standardizingPath
            guard !on.isEmpty, on != "/" else { return nil }
            return on
        }
    }

    /// True when `path` is exactly a network mount root or lives under one.
    public static func isNetworkClassPath(_ path: String, mounts: [String]) -> Bool {
        let p = (path as NSString).standardizingPath
        guard !p.isEmpty else { return false }
        return mounts.contains { root in
            p == root || p.hasPrefix(root + "/")
        }
    }

    public static func isNetworkClassPath(_ path: String) -> Bool {
        isNetworkClassPath(path, mounts: nonLocalMountPaths())
    }
}

/// Directory listing that never prefetches resource keys on network-mount children
/// of a local parent (the common “home contains OrbStack NFS” case).
public enum HostSafeDirectoryListing: Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let path: String
        public let isDirectory: Bool
        public let isNetworkVolume: Bool
        public let fileSize: Int?
        public let contentModificationDate: Date?

        public init(
            name: String,
            path: String,
            isDirectory: Bool,
            isNetworkVolume: Bool,
            fileSize: Int? = nil,
            contentModificationDate: Date? = nil
        ) {
            self.name = name
            self.path = path
            self.isDirectory = isDirectory
            self.isNetworkVolume = isNetworkVolume
            self.fileSize = fileSize
            self.contentModificationDate = contentModificationDate
        }
    }

    /// Lists `path`. When the parent is local, network-mount children are returned
    /// as opaque directories without calling `resourceValues` / `fileExists` on them.
    public static func list(
        path: String,
        fileManager: FileManager = .default,
        networkMounts: [String]? = nil,
        includeNetworkChildren: Bool = true
    ) throws -> [Entry] {
        let standardized = (path as NSString).standardizingPath
        let mounts = networkMounts ?? HostVolumeMountTable.nonLocalMountPaths()
        let parentIsNetwork = HostVolumeMountTable.isNetworkClassPath(standardized, mounts: mounts)
        let names = try fileManager.contentsOfDirectory(atPath: standardized)
        var entries: [Entry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            if name == "." || name == ".." { continue }
            let childPath = ((standardized as NSString).appendingPathComponent(name) as NSString).standardizingPath
            // Direct mount root under a local parent (e.g. ~/OrbStack) — never touch it.
            if !parentIsNetwork && mounts.contains(childPath) {
                if includeNetworkChildren {
                    entries.append(Entry(
                        name: name,
                        path: childPath,
                        isDirectory: true,
                        isNetworkVolume: true
                    ))
                }
                continue
            }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: childPath, isDirectory: &isDir) else { continue }
            var fileSize: Int?
            var modified: Date?
            if let attrs = try? fileManager.attributesOfItem(atPath: childPath) {
                if let n = attrs[.size] as? NSNumber { fileSize = n.intValue }
                modified = attrs[.modificationDate] as? Date
            }
            entries.append(Entry(
                name: name,
                path: childPath,
                isDirectory: isDir.boolValue,
                isNetworkVolume: parentIsNetwork || HostVolumeMountTable.isNetworkClassPath(childPath, mounts: mounts),
                fileSize: isDir.boolValue ? nil : fileSize,
                contentModificationDate: modified
            ))
        }
        return entries
    }
}
