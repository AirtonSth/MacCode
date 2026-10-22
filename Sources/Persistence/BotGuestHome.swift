import Foundation
import CoreModel

public enum BotGuestHome {
    public static func url(appSupport: URL, botID: BotID) -> URL {
        BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: botID)
    }

    @discardableResult
    public static func ensure(appSupport: URL, botID: BotID) throws -> URL {
        let home = url(appSupport: appSupport, botID: botID)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: home.path
        )
        return home
    }

    /// Copies Mac files into the guest's ~/Downloads. The home is a host bind
    /// mount, so no container call is needed. Returns the guest paths.
    public static func importFiles(_ urls: [URL], appSupport: URL, botID: BotID) throws -> [String] {
        let fileManager = FileManager.default
        let downloads = try ensure(appSupport: appSupport, botID: botID).appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        return try urls.map { url in
            let name = url.lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var target = downloads.appendingPathComponent(name)
            var copy = 2
            while fileManager.fileExists(atPath: target.path) {
                target = downloads.appendingPathComponent(ext.isEmpty ? "\(stem) \(copy)" : "\(stem) \(copy).\(ext)")
                copy += 1
            }
            try fileManager.copyItem(at: url, to: target)
            return "\(BotComputerGuestSpec.guestUserHome)/Downloads/\(target.lastPathComponent)"
        }
    }

    public static func wipe(appSupport: URL, botID: BotID) throws {
        let root = BotComputerGuestSpec.guestBotRootURL(appSupport: appSupport, botID: botID)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }
}
