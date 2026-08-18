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

    public static func wipe(appSupport: URL, botID: BotID) throws {
        let home = url(appSupport: appSupport, botID: botID)
        if FileManager.default.fileExists(atPath: home.path) {
            try FileManager.default.removeItem(at: home)
        }
    }
}
