import Foundation
import CryptoKit

public enum BotComputerGuestObserve {
    public static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])
    public static let maxActSteps = 24

    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    public static func validatePNG(_ data: Data) throws -> String {
        guard data.count >= 8, data.prefix(4) == pngSignature else {
            throw BotComputerGuestError.observeFailed
        }
        let digest = SHA256.hash(data: data)
        // PERF: nibble table avoids 32 String(format:) calls; same lowercase hex.
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for b in digest {
            out.append(Self.hexAlphabet[Int(b >> 4)])
            out.append(Self.hexAlphabet[Int(b & 0x0F)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
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

public struct BotComputerActStep: Codable, Equatable, Sendable {
    public var action: String
    public var x: Int?
    public var y: Int?
    public var text: String?
    public var key: String?

    public init(action: String, x: Int? = nil, y: Int? = nil, text: String? = nil, key: String? = nil) {
        self.action = action
        self.x = x
        self.y = y
        self.text = text
        self.key = key
    }

    public func execCommand() throws -> [String] {
        switch action {
        case "click":
            guard let x, let y, (0...1600).contains(x), (0...1200).contains(y) else {
                throw BotComputerGuestError.observeFailed
            }
            return ["env", "DISPLAY=:1", "xdotool", "mousemove", "\(x)", "\(y)", "click", "1"]
        case "type":
            let typed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty, typed.count <= 2000 else {
                throw BotComputerGuestError.observeFailed
            }
            return ["env", "DISPLAY=:1", "xdotool", "type", "--delay", "10", "--", typed]
        case "key":
            let name = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.range(of: "^[A-Za-z0-9+_]+$", options: .regularExpression) != nil else {
                throw BotComputerGuestError.observeFailed
            }
            return ["env", "DISPLAY=:1", "xdotool", "key", "--", name]
        default:
            throw BotComputerGuestError.observeFailed
        }
    }
}
