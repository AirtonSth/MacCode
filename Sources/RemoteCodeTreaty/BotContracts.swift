import Foundation

public enum BotSend: RemoteCodeRPCContract {
    public static let method = "bot.send"

    public struct Params: Codable, Equatable, Sendable {
        public let botID: String
        public let conversationID: String?
        public let text: String
        public let submitKey: String
        public let attachmentIDs: [String]
        public let routingReceiptID: String?
        public let provider: String?
        public let providerInstanceID: String?
        public let model: String?
        public let routingMode: String?
        public let permissionMode: String?
        public let reasoningEffort: String?
        public let serviceTier: String?
        public let runAsUser: RemoteCodeJSONValue?

        public init(
            botID: String,
            conversationID: String? = nil,
            text: String,
            submitKey: String,
            attachmentIDs: [String] = [],
            routingReceiptID: String? = nil,
            provider: String? = nil,
            providerInstanceID: String? = nil,
            model: String? = nil,
            routingMode: String? = nil,
            permissionMode: String? = nil,
            reasoningEffort: String? = nil,
            serviceTier: String? = nil,
            runAsUser: RemoteCodeJSONValue? = nil
        ) {
            self.botID = botID
            self.conversationID = conversationID
            self.text = text
            self.submitKey = submitKey
            self.attachmentIDs = attachmentIDs
            self.routingReceiptID = routingReceiptID
            self.provider = provider
            self.providerInstanceID = providerInstanceID
            self.model = model
            self.routingMode = routingMode
            self.permissionMode = permissionMode
            self.reasoningEffort = reasoningEffort
            self.serviceTier = serviceTier
            self.runAsUser = runAsUser
        }

        private enum CodingKeys: String, CodingKey {
            case botID = "bot_id"
            case conversationID = "conversation_id"
            case text
            case submitKey = "submit_key"
            case attachmentIDs = "attachment_ids"
            case routingReceiptID = "routing_receipt_id"
            case provider
            case providerInstanceID = "provider_instance_id"
            case model
            case routingMode = "routing_mode"
            case permissionMode = "permission_mode"
            case reasoningEffort = "reasoning_effort"
            case serviceTier = "service_tier"
            case runAsUser = "run_as_user"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            case accepted, completed, failed, unknown, partial
        }
        public enum Disposition: Equatable, Sendable {
            case started(threadID: String)
            case queued(queueID: String)
        }

        public let requestID: String
        public let clientRequestID: String
        public let receiptID: String
        public let status: Status
        public let hostID: String
        public let botID: String
        public let conversationID: String?
        public let runID: String
        public let disposition: Disposition
        public let routingReadback: RemoteCodeJSONValue?
        public let readback: RemoteCodeJSONValue

        private enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case clientRequestID = "client_request_id"
            case receiptID = "receipt_id"
            case status, hostID = "host_id", botID = "bot_id", readback
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requestID = try container.decode(String.self, forKey: .requestID)
            clientRequestID = try container.decodeIfPresent(String.self, forKey: .clientRequestID)
                ?? requestID
            receiptID = try container.decode(String.self, forKey: .receiptID)
            status = try container.decode(Status.self, forKey: .status)
            let decodedHostID = try container.decode(String.self, forKey: .hostID)
            let decodedBotID = try container.decode(String.self, forKey: .botID)
            hostID = decodedHostID
            botID = decodedBotID
            readback = try container.decode(RemoteCodeJSONValue.self, forKey: .readback)
            guard let object = readback.objectValue,
                  object["host_id"]?.stringValue == decodedHostID,
                  object["bot_id"]?.stringValue == decodedBotID,
                  object["request_id"]?.stringValue == requestID,
                  object["client_request_id"]?.stringValue == clientRequestID,
                  let runID = object["run_id"]?.stringValue else {
                throw DecodingError.dataCorruptedError(
                    forKey: .readback,
                    in: container,
                    debugDescription: "Bot send receipt identity is incomplete."
                )
            }
            self.runID = runID
            let decodedConversationID = object["conversation_id"]?.stringValue
            conversationID = decodedConversationID
            if object["enqueued"]?.boolValue == true {
                guard let queueID = object["id"]?.stringValue, !queueID.isEmpty,
                      case .array(let queue) = object["queue"],
                      queue.contains(where: { item in
                          guard let row = item.objectValue else { return false }
                          return row["id"]?.stringValue == queueID
                              && row["bot_id"]?.stringValue == decodedBotID
                              && row["conversation_id"]?.stringValue == decodedConversationID
                      }) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .readback,
                        in: container,
                        debugDescription: "Queued Bot send receipt is missing its owned queue identity."
                    )
                }
                disposition = .queued(queueID: queueID)
                routingReadback = object["effective_routing"]
            } else {
                guard let run = object["run"]?.objectValue,
                      run["host_id"]?.stringValue == decodedHostID,
                      run["bot_id"]?.stringValue == decodedBotID,
                      run["request_id"]?.stringValue == requestID,
                      run["client_request_id"]?.stringValue == clientRequestID,
                      run["conversation_id"]?.stringValue == decodedConversationID,
                      run["run_id"]?.stringValue == runID,
                      let threadID = run["thread_id"]?.stringValue,
                      !threadID.isEmpty else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .readback,
                        in: container,
                        debugDescription: "Started Bot send receipt is missing its owned run identity."
                    )
                }
                disposition = .started(threadID: threadID)
                routingReadback = run["routing"]
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(clientRequestID, forKey: .clientRequestID)
            try container.encode(receiptID, forKey: .receiptID)
            try container.encode(status, forKey: .status)
            try container.encode(hostID, forKey: .hostID)
            try container.encode(botID, forKey: .botID)
            try container.encode(readback, forKey: .readback)
        }
    }
}

public struct BotUploadTarget: Codable, Equatable, Sendable {
    public let botID: String
    public let conversationID: String
    public let attachmentID: String
    public let filename: String
    public let kind: String
    public let digest: String
    public let size: Int
    public let mimeType: String?

    public init(
        botID: String,
        conversationID: String,
        attachmentID: String,
        filename: String,
        kind: String,
        digest: String,
        size: Int,
        mimeType: String? = nil
    ) {
        self.botID = botID
        self.conversationID = conversationID
        self.attachmentID = attachmentID
        self.filename = filename
        self.kind = kind
        self.digest = digest
        self.size = size
        self.mimeType = mimeType
    }

    private enum CodingKeys: String, CodingKey {
        case botID = "bot_id"
        case conversationID = "conversation_id"
        case attachmentID = "attachment_id"
        case filename, kind, digest, size
        case mimeType = "mime_type"
    }
}

public struct BotAttachmentGrant: Codable, Equatable, Sendable {
    public let id: String
    public let botID: String
    public let conversationID: String
    public let attachmentID: String
    public let filename: String
    public let kind: String
    public let digest: String
    public let size: Int
    public let mimeType: String?
    public let consumed: Bool

    public init(
        id: String,
        botID: String,
        conversationID: String,
        attachmentID: String,
        filename: String,
        kind: String,
        digest: String,
        size: Int,
        mimeType: String? = nil,
        consumed: Bool
    ) {
        self.id = id
        self.botID = botID
        self.conversationID = conversationID
        self.attachmentID = attachmentID
        self.filename = filename
        self.kind = kind
        self.digest = digest
        self.size = size
        self.mimeType = mimeType
        self.consumed = consumed
    }

    private enum CodingKeys: String, CodingKey {
        case id, filename, kind, digest, size, consumed
        case botID = "bot_id"
        case conversationID = "conversation_id"
        case attachmentID = "attachment_id"
        case mimeType = "mime_type"
    }
}
