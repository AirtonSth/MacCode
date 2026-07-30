import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

enum BrowserScreenshotInlineV1Error: Error, Equatable {
    case invalidLimits
    case invalidSource
    case sourceTooLarge
    case encodingFailed
}

/// Bounded, opt-in wire representation for an iOS-renderable browser screenshot.
///
/// The existing authenticated JSON-RPC transport carries this small response.
/// Source files are opened without following symlinks and are byte-capped before
/// ImageIO sees them. The returned base64 is derived only from a capped JPEG.
enum BrowserScreenshotInlineV1 {
    static let version = 1
    static let mimeType = "image/jpeg"
    static let maximumSourceBytes = 32 * 1_024 * 1_024
    static let maximumSourcePixelDimension = 16_384
    static let maximumSourcePixelCount = 40_000_000
    static let maximumResponseBytes = 160 * 1_024
    static let maximumPixelDimension = 1_280
    static let maximumPixelCount = 1_048_576

    static func boundedPositiveInteger(
        _ value: JSONValue?,
        maximum: Int
    ) -> Int? {
        guard case .number(let number)? = value,
              number.isFinite,
              number > 0,
              number <= Double(maximum),
              number.rounded(.towardZero) == number else {
            return nil
        }
        return Int(number)
    }

    static func makeResponse(
        fileURL: URL,
        requestedMaxBytes: Int,
        requestedMaxPixelDimension: Int
    ) throws -> [String: JSONValue] {
        try validateLimits(
            maxBytes: requestedMaxBytes,
            maxPixelDimension: requestedMaxPixelDimension
        )
        let sourceData = try readBoundedRegularFile(at: fileURL)
        return try makeResponse(
            sourceData: sourceData,
            requestedMaxBytes: requestedMaxBytes,
            requestedMaxPixelDimension: requestedMaxPixelDimension
        )
    }

    static func makeResponse(
        sourceData: Data,
        requestedMaxBytes: Int,
        requestedMaxPixelDimension: Int
    ) throws -> [String: JSONValue] {
        try validateLimits(
            maxBytes: requestedMaxBytes,
            maxPixelDimension: requestedMaxPixelDimension
        )
        guard !sourceData.isEmpty,
              sourceData.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(
              sourceData as CFData,
              [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1,
              (CGImageSourceGetType(source) as String?) == "public.png",
              let sourceDimensions = dimensions(of: source),
              sourceDimensions.width <= maximumSourcePixelDimension,
              sourceDimensions.height <= maximumSourcePixelDimension,
              sourceDimensions.height > 0,
              sourceDimensions.width <= maximumSourcePixelCount / sourceDimensions.height
        else {
            throw BrowserScreenshotInlineV1Error.invalidSource
        }

        let sourceMaximumDimension = max(
            sourceDimensions.width,
            sourceDimensions.height
        )
        let sourcePixelCount =
            sourceDimensions.width * sourceDimensions.height
        let pixelScale = min(
            1,
            sqrt(Double(maximumPixelCount) / Double(sourcePixelCount))
        )
        let pixelLimitedDimension = max(
            1,
            Int(floor(Double(sourceMaximumDimension) * pixelScale))
        )
        let initialDimension = min(
            requestedMaxPixelDimension,
            maximumPixelDimension,
            pixelLimitedDimension
        )

        for dimension in dimensionCandidates(startingAt: initialDimension) {
            guard let image = thumbnail(
                from: source,
                maximumPixelDimension: dimension
            ) else {
                throw BrowserScreenshotInlineV1Error.invalidSource
            }
            guard image.width > 0,
                  image.height > 0,
                  image.width <= requestedMaxPixelDimension,
                  image.height <= requestedMaxPixelDimension,
                  image.width <= maximumPixelDimension,
                  image.height <= maximumPixelDimension,
                  image.height <= maximumPixelCount,
                  image.width <= maximumPixelCount / image.height
            else {
                throw BrowserScreenshotInlineV1Error.invalidSource
            }

            for quality in [0.72, 0.56, 0.40, 0.28] {
                guard let jpeg = encodeJPEG(image, quality: quality) else {
                    throw BrowserScreenshotInlineV1Error.encodingFailed
                }
                guard jpeg.count <= requestedMaxBytes,
                      jpeg.count <= maximumResponseBytes else {
                    continue
                }
                let base64 = jpeg.base64EncodedString()
                guard base64.utf8.count <= maximumBase64Characters(
                    for: jpeg.count
                ) else {
                    throw BrowserScreenshotInlineV1Error.encodingFailed
                }
                let sha256 = SHA256.hash(data: jpeg)
                    .map { String(format: "%02x", $0) }
                    .joined()
                return [
                    "version": .number(Double(version)),
                    "mime_type": .string(mimeType),
                    "data_base64": .string(base64),
                    "byte_count": .number(Double(jpeg.count)),
                    "pixel_width": .number(Double(image.width)),
                    "pixel_height": .number(Double(image.height)),
                    "sha256": .string(sha256),
                ]
            }
        }
        throw BrowserScreenshotInlineV1Error.encodingFailed
    }

    private static func validateLimits(
        maxBytes: Int,
        maxPixelDimension: Int
    ) throws {
        guard maxBytes > 0,
              maxBytes <= maximumResponseBytes,
              maxPixelDimension > 0,
              maxPixelDimension <= maximumPixelDimension else {
            throw BrowserScreenshotInlineV1Error.invalidLimits
        }
    }

    private static func readBoundedRegularFile(at url: URL) throws -> Data {
        guard url.isFileURL else {
            throw BrowserScreenshotInlineV1Error.invalidSource
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw BrowserScreenshotInlineV1Error.invalidSource
        }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0 else {
            Darwin.close(descriptor)
            throw BrowserScreenshotInlineV1Error.invalidSource
        }
        guard metadata.st_size <= off_t(maximumSourceBytes) else {
            Darwin.close(descriptor)
            throw BrowserScreenshotInlineV1Error.sourceTooLarge
        }

        let expectedSize = Int(metadata.st_size)
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maximumSourceBytes + 1) ?? Data()
        } catch {
            throw BrowserScreenshotInlineV1Error.invalidSource
        }
        guard data.count == expectedSize,
              data.count <= maximumSourceBytes else {
            throw BrowserScreenshotInlineV1Error.invalidSource
        }
        return data
    }

    private static func dimensions(
        of source: CGImageSource
    ) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any],
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
            .intValue,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
            .intValue,
        width > 0,
        height > 0 else {
            return nil
        }
        return (width, height)
    }

    private static func thumbnail(
        from source: CGImageSource,
        maximumPixelDimension: Int
    ) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        )
    }

    private static func encodeJPEG(
        _ image: CGImage,
        quality: Double
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    private static func dimensionCandidates(
        startingAt initial: Int
    ) -> [Int] {
        let factors = [1.0, 0.80, 0.64, 0.50, 0.40, 0.32, 0.25, 0.125]
        var result: [Int] = []
        for factor in factors {
            let candidate = max(1, Int(floor(Double(initial) * factor)))
            if result.last != candidate {
                result.append(candidate)
            }
        }
        if result.last != 1 {
            result.append(1)
        }
        return result
    }

    private static func maximumBase64Characters(for byteCount: Int) -> Int {
        ((byteCount + 2) / 3) * 4
    }
}
