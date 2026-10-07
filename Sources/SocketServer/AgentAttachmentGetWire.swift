import CoreModel
import Foundation
import ImageIO
import Persistence
import UniformTypeIdentifiers

/// `agent.attachment.get` (host capability `agent.attachment_get_v1`): the
/// bytes of one attachment on one message, for paired devices that only
/// receive path-free attachment references. See AgentAttachmentGetContracts.swift.
public enum AgentAttachmentGetWire {
    public static let notFoundCode = -32066
    public static let tooLargeCode = -32067
    public static let unavailableCode = -32068

    /// Ceiling for the returned bytes (before base64), and the default
    /// `max_bytes`. Keeps one response well inside the paired socket's
    /// outbound budget (1 MiB cold start).
    public static let maxBytesCeiling = 256 * 1_024
    public static let defaultThumbnailMaxPixels = 512
    public static let thumbnailMaxPixelsRange = 64...2_048
    static let thumbnailJPEGQuality = 0.7

    public struct Request: Equatable, Sendable {
        public let threadID: AgentThreadID
        public let messageID: AgentMessageID
        public let attachmentID: String
        /// nil: the original bytes; otherwise a JPEG whose long edge is at most this.
        public let thumbnailMaxPixels: Int?
        public let maxBytes: Int
    }

    /// Validates params before any lookup. Missing or mistyped fields are -32602.
    public static func request(from params: [String: JSONValue]) throws -> Request {
        guard let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
              let messageID = params["message_id"]?.stringValue.flatMap(UUID.init).map(AgentMessageID.init),
              let attachmentID = params["attachment_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !attachmentID.isEmpty else {
            throw JSONRPCError.invalidParams
        }
        var thumbnail = false
        if let value = params["thumbnail"], value != .null {
            guard case .bool(let flag) = value else { throw JSONRPCError.invalidParams }
            thumbnail = flag
        }
        var maxPixels = defaultThumbnailMaxPixels
        if let value = params["thumbnail_max_pixels"], value != .null {
            guard let pixels = value.intValue else { throw JSONRPCError.invalidParams }
            maxPixels = min(max(pixels, thumbnailMaxPixelsRange.lowerBound), thumbnailMaxPixelsRange.upperBound)
        }
        var maxBytes = maxBytesCeiling
        if let value = params["max_bytes"], value != .null {
            guard let bytes = value.intValue, bytes > 0 else { throw JSONRPCError.invalidParams }
            maxBytes = min(bytes, maxBytesCeiling)
        }
        return Request(
            threadID: threadID,
            messageID: messageID,
            attachmentID: attachmentID,
            thumbnailMaxPixels: thumbnail ? maxPixels : nil,
            maxBytes: maxBytes
        )
    }

    /// Reads the attachment for `request` from `message` (nil when the message
    /// does not exist). Containment: the message must be on the requested
    /// thread, the attachment must be on that message, and its bytes must be
    /// a blob inside `store` that still matches its recorded digest and size.
    /// Blocking file and image work: call it off the main actor.
    public static func load(
        _ request: Request,
        message: AgentMessage?,
        store: AgentAttachmentStore
    ) throws -> JSONValue {
        guard let message, message.threadId == request.threadID else {
            throw notFound("message")
        }
        let wanted = request.attachmentID.lowercased()
        guard let attachment = message.attachments.first(where: { candidate in
            (candidate.id ?? candidate.sha256)?.lowercased() == wanted
        }), let reference = AgentAttachmentReference(attachment) else {
            throw notFound("attachment")
        }
        let original: Data
        do {
            original = try store.containedData(for: attachment)
        } catch {
            throw unavailable("missing", reference: reference)
        }

        let bytes: Data
        let mimeType: String?
        let dimensions: (width: Int, height: Int)?
        if let maxPixels = request.thumbnailMaxPixels {
            guard attachment.kind == .image,
                  let thumbnail = jpegThumbnail(original, maxPixels: maxPixels) else {
                throw unavailable("not_image", reference: reference)
            }
            bytes = thumbnail.data
            mimeType = "image/jpeg"
            dimensions = (thumbnail.width, thumbnail.height)
        } else {
            bytes = original
            mimeType = reference.mimeType
            dimensions = attachment.kind == .image ? pixelSize(original) : nil
        }
        guard bytes.count <= request.maxBytes else {
            throw JSONRPCError(
                code: tooLargeCode,
                message: "Attachment is larger than max_bytes.",
                data: .object([
                    "domain": .string("attachment"),
                    "kind": .string("too_large"),
                    "data_size_bytes": .number(Double(bytes.count)),
                    "max_bytes": .number(Double(request.maxBytes)),
                    "thumbnail": .bool(request.thumbnailMaxPixels != nil),
                ])
            )
        }
        var result: [String: JSONValue] = [
            "thread_id": .string(request.threadID.value.uuidString),
            "message_id": .string(request.messageID.value.uuidString),
            "attachment_id": .string(reference.id),
            "display_name": .string(reference.displayName),
            "kind": .string(reference.kind.rawValue),
            "mime_type": reference.mimeType.map(JSONValue.string) ?? .null,
            "sha256": .string(reference.sha256),
            "size_bytes": .number(Double(reference.sizeBytes)),
            "thumbnail": .bool(request.thumbnailMaxPixels != nil),
            "data_mime_type": mimeType.map(JSONValue.string) ?? .null,
            "data_size_bytes": .number(Double(bytes.count)),
            "data_base64": .string(bytes.base64EncodedString()),
        ]
        result["width"] = dimensions.map { .number(Double($0.width)) } ?? .null
        result["height"] = dimensions.map { .number(Double($0.height)) } ?? .null
        return .object(result)
    }

    static func notFound(_ what: String) -> JSONRPCError {
        JSONRPCError(
            code: notFoundCode,
            message: "Attachment not found on this thread's message.",
            data: .object([
                "domain": .string("attachment"),
                "kind": .string("not_found"),
                "missing": .string(what),
            ])
        )
    }

    static func unavailable(_ reason: String, reference: AgentAttachmentReference) -> JSONRPCError {
        JSONRPCError(
            code: unavailableCode,
            message: reason == "not_image"
                ? "A thumbnail needs a readable image attachment."
                : "The attachment's stored bytes are no longer available on the Mac.",
            data: .object([
                "domain": .string("attachment"),
                "kind": .string("unavailable"),
                "reason": .string(reason),
                "attachment_id": .string(reference.id),
            ])
        )
    }

    private static func jpegThumbnail(_ data: Data, maxPixels: Int) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: thumbnailJPEGQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, image.width, image.height)
    }

    private static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
