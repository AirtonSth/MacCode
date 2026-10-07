import Foundation

// Attachment bytes for paired devices (host capability `agent.attachment_get_v1`).
//
// - Event: a bot screenshot posted to a chat is published as
//   `agent.message.appended` (assistant row, content "📷 <reason>", one
//   `kind: image`, `mimeType: image/jpeg` attachment reference), like any
//   other appended message.
// - Read: `agent.attachment.get` (read scope, batchable) returns one
//   attachment of one message as base64. Ask for `thumbnail: true` for a list
//   thumbnail (a JPEG whose long edge is at most `thumbnail_max_pixels`,
//   default 512, clamped to 64...2048; images only). Send one full-size or
//   large request per call rather than batching them: every response is
//   capped at `max_bytes` (default and ceiling 262144 bytes before base64).
// - Containment: the message must be on `thread_id`, the attachment must be
//   on that message (match its `id` as listed in the message's
//   `attachments`), and the bytes must still be the host-owned blob with the
//   recorded SHA-256 and size. No host path is ever accepted or returned.
//
// Errors carry `data: {"domain": "attachment", "kind": ...}`: kind
// `not_found` (-32066; `missing` is `message` or `attachment`), `too_large`
// (-32067; `data_size_bytes`, `max_bytes`, `thumbnail`: retry with a
// thumbnail or a smaller `thumbnail_max_pixels`) or `unavailable` (-32068;
// `reason` `missing` when the stored bytes are gone or changed, `not_image`
// when a thumbnail was asked for a non-image or an undecodable image).
// Malformed params are -32602.

public enum AgentAttachmentGet: RemoteCodeRPCContract {
    public static let method = "agent.attachment.get"

    public struct Params: Codable, Equatable, Sendable {
        public let threadID: String
        public let messageID: String
        public let attachmentID: String
        public let thumbnail: Bool?
        public let thumbnailMaxPixels: Int?
        public let maxBytes: Int?

        public init(
            threadID: String,
            messageID: String,
            attachmentID: String,
            thumbnail: Bool? = nil,
            thumbnailMaxPixels: Int? = nil,
            maxBytes: Int? = nil
        ) {
            self.threadID = threadID
            self.messageID = messageID
            self.attachmentID = attachmentID
            self.thumbnail = thumbnail
            self.thumbnailMaxPixels = thumbnailMaxPixels
            self.maxBytes = maxBytes
        }

        private enum CodingKeys: String, CodingKey {
            case thumbnail
            case threadID = "thread_id"
            case messageID = "message_id"
            case attachmentID = "attachment_id"
            case thumbnailMaxPixels = "thumbnail_max_pixels"
            case maxBytes = "max_bytes"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let threadID: String
        public let messageID: String
        public let attachmentID: String
        public let displayName: String
        /// `image` or `file`.
        public let kind: String
        public let mimeType: String?
        /// SHA-256 and size of the original attachment (not of a thumbnail).
        public let sha256: String
        public let sizeBytes: Int
        public let thumbnail: Bool
        /// Type and size of `dataBase64` (`image/jpeg` for a thumbnail).
        public let dataMimeType: String?
        public let dataSizeBytes: Int
        public let dataBase64: String
        /// Pixel size of the returned image; nil for files.
        public let width: Int?
        public let height: Int?

        private enum CodingKeys: String, CodingKey {
            case kind, sha256, thumbnail, width, height
            case threadID = "thread_id"
            case messageID = "message_id"
            case attachmentID = "attachment_id"
            case displayName = "display_name"
            case mimeType = "mime_type"
            case sizeBytes = "size_bytes"
            case dataMimeType = "data_mime_type"
            case dataSizeBytes = "data_size_bytes"
            case dataBase64 = "data_base64"
        }
    }
}
