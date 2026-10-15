import CoreModel
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `agent.message.image.get` (host capability `agent.message_image_get_v1`):
/// a downsampled copy of one Mac-local image that an assistant message
/// references. See AgentMessageImageGetContracts.swift.
public enum AgentMessageImageGetWire {
    public static let notFoundCode = -32069
    /// Same reply ceiling as `agent.attachment.get` (bytes before base64).
    public static let maxBytes = AgentAttachmentGetWire.maxBytesCeiling
    public static let allowedMaxPixels: Set<Int> = [512, 1_024, 2_048]
    public static let defaultMaxPixel = 1_024
    /// Source files above this are refused before ImageIO touches them.
    public static let maxSourceFileBytes: Int64 = 128 * 1_024 * 1_024
    static let smallestPixel = 96

    public struct Request: Equatable, Sendable {
        public let threadID: AgentThreadID
        public let messageID: AgentMessageID
        public let ref: String
        public let maxPixel: Int
    }

    /// Validates params before any lookup. Missing or mistyped fields are -32602.
    public static func request(from params: [String: JSONValue]) throws -> Request {
        guard let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
              let messageID = params["message_id"]?.stringValue.flatMap(UUID.init).map(AgentMessageID.init),
              let ref = params["ref"]?.stringValue,
              !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JSONRPCError.invalidParams
        }
        var maxPixel = defaultMaxPixel
        if let value = params["max_pixel"], value != .null {
            guard let pixels = value.intValue, allowedMaxPixels.contains(pixels) else {
                throw invalid("max_pixel")
            }
            maxPixel = pixels
        }
        return Request(threadID: threadID, messageID: messageID, ref: ref, maxPixel: maxPixel)
    }

    /// Reads, downsamples and encodes the image `request.ref` names. `message`
    /// is nil when it does not exist. Blocking file and image work: call it off
    /// the main actor.
    public static func load(
        _ request: Request,
        message: AgentMessage?,
        homeDirectory: String = NSHomeDirectory()
    ) throws -> JSONValue {
        guard let message, message.threadId == request.threadID, message.role == .assistant else {
            throw notFound("message")
        }
        guard message.content.contains(request.ref) else { throw notFound("ref") }
        guard let source = AgentMessageImageRefs.source(forReference: request.ref, homeDirectory: homeDirectory),
              case .localPath(let path) = source else {
            throw invalid("not_local_image_ref")
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path) else {
            throw notFound("file")
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { throw invalid("not_regular_file") }
        if let size = attributes[.size] as? NSNumber, size.int64Value > maxSourceFileBytes {
            throw invalid("too_large")
        }
        guard let imageSource = CGImageSourceCreateWithURL(resolved as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw invalid("not_image")
        }
        guard let encoded = encodeUnderCap(imageSource, maxPixel: request.maxPixel) else {
            throw invalid("not_image")
        }
        return .object([
            "mime": .string(encoded.mime),
            "width": .number(Double(encoded.width)),
            "height": .number(Double(encoded.height)),
            "sha256": .string(SHA256.hash(data: encoded.data).map { String(format: "%02x", $0) }.joined()),
            "data_base64": .string(encoded.data.base64EncodedString()),
        ])
    }

    /// PNG for images with alpha when it fits, otherwise JPEG; the long edge
    /// shrinks until the bytes fit under `maxBytes`.
    static func encodeUnderCap(
        _ source: CGImageSource,
        maxPixel: Int
    ) -> (data: Data, mime: String, width: Int, height: Int)? {
        var pixel = maxPixel
        while pixel >= smallestPixel {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixel,
            ] as CFDictionary) else {
                return nil
            }
            if hasAlpha(image), let png = encode(image, type: .png, quality: nil), png.count <= maxBytes {
                return (png, "image/png", image.width, image.height)
            }
            for quality in [0.8, 0.6] {
                if let jpeg = encode(image, type: .jpeg, quality: quality), jpeg.count <= maxBytes {
                    return (jpeg, "image/jpeg", image.width, image.height)
                }
            }
            pixel = Int(Double(min(pixel, max(image.width, image.height))) * 0.75)
        }
        return nil
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func notFound(_ what: String) -> JSONRPCError {
        JSONRPCError(
            code: notFoundCode,
            message: "Image not found in this thread's message.",
            data: .object([
                "domain": .string("message_image"),
                "kind": .string("not_found"),
                "missing": .string(what),
            ])
        )
    }

    static func invalid(_ reason: String) -> JSONRPCError {
        JSONRPCError(
            code: JSONRPCError.invalidParams.code,
            message: "Invalid params",
            data: .object([
                "domain": .string("message_image"),
                "reason": .string(reason),
            ])
        )
    }
}
