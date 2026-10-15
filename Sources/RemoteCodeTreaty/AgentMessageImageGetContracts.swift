import Foundation

// Images that an assistant message talks about, for paired devices (host
// capability `agent.message_image_get_v1`).
//
// - Which images: in order, de-duplicated — the message's image attachments
//   (fetch those with `agent.attachment.get`), markdown images `![alt](src)`,
//   then bare `http(s)://`, `file://`, absolute or `~/` references whose path
//   ends in .png .jpg .jpeg .gif .webp .heic .heif .tiff .tif .bmp. Fenced code
//   is ignored; inline code counts. https images are fetched by the phone
//   itself (image MIME only, 10 MB, 15 s).
// - Read: `agent.message.image.get {thread_id, message_id, ref, max_pixel}`
//   (batchable, `read` scope) returns one Mac-local image referenced by an
//   assistant message. `ref` is the reference exactly as written in the
//   message content (`/Users/me/a.png`, `~/a.png` or `file:///Users/me/a.png`).
//   `max_pixel` is 512, 1024 (default) or 2048: the long edge of the returned
//   image is at most that, and smaller still when needed to keep the reply
//   under 262144 bytes before base64 (same cap as `agent.attachment.get`).
// - Result: `{mime, width, height, sha256, data_base64}`; `mime` is
//   `image/png` (images with transparency, when it fits) or `image/jpeg`;
//   `width`/`height` are the returned pixels; `sha256` is the lowercase hex
//   digest of the returned bytes.
// - Containment: the message must be an assistant message on `thread_id`,
//   `ref` must occur literally in its content, and the file it names must
//   exist, be a regular file (symlinks are resolved), have an image extension
//   and decode as an image. Nothing else on the Mac is readable this way.
//
// Errors: `not_found` (-32069, `data: {"domain": "message_image", "kind":
// "not_found", "missing": "message" | "ref" | "file"}`), or -32602 invalid
// params (malformed params, a `max_pixel` outside 512/1024/2048, a ref that is
// not a Mac-local image path, a non-regular file, or bytes that do not decode
// as an image; `data.reason` says which). Show the "image unavailable" tile
// for either.

public enum AgentMessageImageGet: RemoteCodeRPCContract {
    public static let method = "agent.message.image.get"
    public static let allowedMaxPixels: [Int] = [512, 1_024, 2_048]
    public static let defaultMaxPixel = 1_024

    public struct Params: Codable, Equatable, Sendable {
        public let threadID: String
        public let messageID: String
        public let ref: String
        public let maxPixel: Int?

        public init(threadID: String, messageID: String, ref: String, maxPixel: Int? = nil) {
            self.threadID = threadID
            self.messageID = messageID
            self.ref = ref
            self.maxPixel = maxPixel
        }

        private enum CodingKeys: String, CodingKey {
            case ref
            case threadID = "thread_id"
            case messageID = "message_id"
            case maxPixel = "max_pixel"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let mime: String
        public let width: Int
        public let height: Int
        public let sha256: String
        public let dataBase64: String

        public init(mime: String, width: Int, height: Int, sha256: String, dataBase64: String) {
            self.mime = mime
            self.width = width
            self.height = height
            self.sha256 = sha256
            self.dataBase64 = dataBase64
        }

        private enum CodingKeys: String, CodingKey {
            case mime, width, height, sha256
            case dataBase64 = "data_base64"
        }
    }
}
