import Foundation
import CoreGraphics
import ImageIO

public enum BotScreenshotKind: String, Sendable {
    case normal
    case error
    case action
}

/// 1 screenshot per bot per interval. `error` and `action` are exempt and do not reset the window.
public final class BotScreenshotRateLimiter: @unchecked Sendable {
    public static let shared = BotScreenshotRateLimiter()
    public static let defaultInterval: TimeInterval = 30

    public enum Decision: Equatable, Sendable {
        case allowed
        case blocked(retryAfterSeconds: Int)

        public var message: String? {
            if case .blocked(let seconds) = self { return "rate limited, try again in \(seconds)s" }
            return nil
        }
    }

    private let lock = NSLock()
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private var lastNormal: [BotID: Date] = [:]

    public init(
        interval: TimeInterval = BotScreenshotRateLimiter.defaultInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.interval = interval
        self.now = now
    }

    /// Records the slot when allowed.
    public func acquire(botID: BotID, kind: BotScreenshotKind) -> Decision {
        guard kind == .normal else { return .allowed }
        return lock.withLock {
            let current = now()
            if let last = lastNormal[botID] {
                let remaining = interval - current.timeIntervalSince(last)
                if remaining > 0 { return .blocked(retryAfterSeconds: Int(remaining.rounded(.up))) }
            }
            lastNormal[botID] = current
            return .allowed
        }
    }
}

public enum BotScreenshotEncoderError: Error, Equatable, Sendable {
    case invalidImage
    case encodeFailed
}

public enum BotScreenshotEncoder {
    public static let defaultMaxWidth = 1280

    public static func jpeg(
        fromPNG png: Data,
        maxWidth: Int = defaultMaxWidth,
        quality: Double = 0.7
    ) throws -> (data: Data, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, maxWidth > 0 else {
            throw BotScreenshotEncoderError.invalidImage
        }
        let width = min(image.width, maxWidth)
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw BotScreenshotEncoderError.encodeFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw BotScreenshotEncoderError.encodeFailed }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw BotScreenshotEncoderError.encodeFailed
        }
        CGImageDestinationAddImage(
            destination,
            scaled,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw BotScreenshotEncoderError.encodeFailed }
        return (output as Data, width, height)
    }
}
