import Foundation
import CryptoKit

public enum BotComputerGuestObserve {
    public static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])
    public static let maxActSteps = 24

    public static func validatePNG(_ data: Data) throws -> String {
        guard data.count >= 8, data.prefix(4) == pngSignature else {
            throw BotComputerGuestError.observeFailed
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func assertActStepCount(_ count: Int) throws {
        guard count > 0, count <= maxActSteps else {
            throw BotComputerGuestError.observeFailed
        }
    }

    public static func assertGuestRelativePath(_ path: String) throws {
        guard !path.contains(".."), !path.hasPrefix("/") else {
            throw BotComputerGuestError.invalidHomePath
        }
    }
}
