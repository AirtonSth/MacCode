import CryptoKit
import Foundation

/// Host-owned, provider-neutral conversation seed (`RCSEED1/1`).
///
/// When a provider session cannot be resumed, the adapter opens a fresh one
/// and sends this document with the first turn so the new session can rebuild
/// the prior conversation. Every item carries the stored Human text plus its
/// role and order. The document is never ordinary message content.
public enum ConversationContextSeed {
    public static let version = "RCSEED1/1"
    public static let maxEncodedBytes = 65_536
    public static let maxItemBytes = 65_536
    public static let maxItems = 100
    /// Item format field of the wire layout. Only Human text is sent.
    static let humanFormat = "human"

    public enum Role: String, Sendable, Equatable, Codable {
        case user
        case assistant
    }

    public struct Item: Sendable, Equatable {
        public let role: Role
        public let ordinal: Int
        public let sourceMessageId: String
        public let payload: String

        public init(role: Role, ordinal: Int, sourceMessageId: String, payload: String) {
            self.role = role
            self.ordinal = ordinal
            self.sourceMessageId = sourceMessageId
            self.payload = payload
        }
    }

    public struct Document: Sendable, Equatable {
        public let snapshotDigest: String
        public let items: [Item]

        public init(snapshotDigest: String, items: [Item]) {
            self.snapshotDigest = snapshotDigest
            self.items = items
        }
    }

    public struct Prepared: Sendable, Equatable {
        public let document: Document
        public let encoded: String

        public init(document: Document, encoded: String) {
            self.document = document
            self.encoded = encoded
        }
    }

    /// Builds the complete seed for a snapshot. Never emits a partial seed.
    public static func prepare(snapshot: ConversationContextSnapshot) -> Prepared? {
        guard !snapshot.items.isEmpty,
              snapshot.items.count <= maxItems,
              snapshot.digest == ConversationContextSnapshot.digest(for: snapshot.items) else {
            return nil
        }
        let items = snapshot.items.map {
            Item(role: $0.role, ordinal: $0.ordinal, sourceMessageId: $0.messageId, payload: $0.canonicalText)
        }
        let document = Document(snapshotDigest: snapshot.digest, items: items)
        guard let encoded = encode(document) else { return nil }
        return Prepared(document: document, encoded: encoded)
    }

    public static func encode(snapshotDigest: String, items: [Item]) -> String? {
        encode(Document(snapshotDigest: snapshotDigest, items: items))
    }

    public static func encode(_ document: Document) -> String? {
        guard validDigest(document.snapshotDigest),
              !document.items.isEmpty,
              document.items.count <= maxItems,
              document.items.count == Set(document.items.map(\.ordinal)).count else {
            return nil
        }
        let ordered = document.items.sorted { $0.ordinal < $1.ordinal }
        guard ordered.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }) else {
            return nil
        }
        var bytes = Array("\(version)\nH\t\(ordered.count)\t\(document.snapshotDigest)\n".utf8)
        for item in ordered {
            guard validItem(item) else { return nil }
            let payloadBytes = Array(item.payload.utf8)
            bytes.append(contentsOf: Array(
                "I\t\(item.ordinal)\t\(item.role.rawValue)\t\(humanFormat)\t\(payloadBytes.count)\t\(item.sourceMessageId)\n".utf8
            ))
            bytes.append(contentsOf: payloadBytes)
            bytes.append(UInt8(ascii: "\n"))
        }
        bytes.append(contentsOf: Array("END".utf8))
        guard bytes.count <= maxEncodedBytes,
              let body = String(bytes: bytes, encoding: .utf8) else {
            return nil
        }
        return body
    }

    public static func decode(_ text: String) -> Document? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= maxEncodedBytes else { return nil }
        var cursor = 0
        guard consume("\(version)\n", in: bytes, cursor: &cursor),
              let headerLine = readLine(in: bytes, cursor: &cursor) else {
            return nil
        }
        let headerFields = splitTabs(headerLine)
        guard headerFields.count == 3,
              headerFields[0] == Array("H".utf8),
              let count = parseUnsigned(headerFields[1]),
              count > 0,
              count <= maxItems,
              let digest = String(bytes: headerFields[2], encoding: .utf8),
              validDigest(digest) else {
            return nil
        }
        var items: [Item] = []
        for expectedOrdinal in 0..<count {
            guard let itemLine = readLine(in: bytes, cursor: &cursor) else { return nil }
            let fields = splitTabs(itemLine)
            guard fields.count == 6,
                  fields[0] == Array("I".utf8),
                  let ordinal = parseUnsigned(fields[1]),
                  ordinal == expectedOrdinal,
                  let roleText = String(bytes: fields[2], encoding: .utf8),
                  let role = Role(rawValue: roleText),
                  fields[3] == Array(humanFormat.utf8),
                  let payloadCount = parseUnsigned(fields[4]),
                  payloadCount <= maxItemBytes,
                  let sourceMessageId = String(bytes: fields[5], encoding: .utf8),
                  !sourceMessageId.isEmpty else {
                return nil
            }
            guard cursor + payloadCount < bytes.count else { return nil }
            let payloadBytes = Array(bytes[cursor..<(cursor + payloadCount)])
            cursor += payloadCount
            guard bytes[cursor] == UInt8(ascii: "\n"),
                  let payload = String(bytes: payloadBytes, encoding: .utf8),
                  payload.utf8.count == payloadCount else {
                return nil
            }
            cursor += 1
            items.append(Item(
                role: role,
                ordinal: ordinal,
                sourceMessageId: sourceMessageId,
                payload: payload
            ))
        }
        guard Array(bytes[cursor...]) == Array("END".utf8) else { return nil }
        let rebuilt = encode(snapshotDigest: digest, items: items)
        guard rebuilt == text else { return nil }
        return Document(snapshotDigest: digest, items: items)
    }

    private static func validDigest(_ digest: String) -> Bool {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == digest
            && !trimmed.contains(where: \.isWhitespace)
            && trimmed.count <= 128
    }

    private static func consume(_ text: String, in bytes: [UInt8], cursor: inout Int) -> Bool {
        let expected = Array(text.utf8)
        guard cursor + expected.count <= bytes.count,
              bytes[cursor..<(cursor + expected.count)].elementsEqual(expected) else {
            return false
        }
        cursor += expected.count
        return true
    }

    private static func readLine(in bytes: [UInt8], cursor: inout Int) -> [UInt8]? {
        guard cursor < bytes.count else { return nil }
        var index = cursor
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n") {
            index += 1
        }
        guard index < bytes.count else { return nil }
        let line = Array(bytes[cursor..<index])
        cursor = index + 1
        return line
    }

    private static func splitTabs(_ line: [UInt8]) -> [[UInt8]] {
        var fields: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in line {
            if byte == UInt8(ascii: "\t") {
                fields.append(current)
                current = []
            } else {
                current.append(byte)
            }
        }
        fields.append(current)
        return fields
    }

    private static func parseUnsigned(_ bytes: [UInt8]) -> Int? {
        guard !bytes.isEmpty else { return nil }
        if bytes.count > 1 && bytes[0] == UInt8(ascii: "0") { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            let digit = Int(byte - UInt8(ascii: "0"))
            guard value <= (maxEncodedBytes - digit) / 10 else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    private static func validItem(_ item: Item) -> Bool {
        item.ordinal >= 0
            && !item.sourceMessageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !item.payload.isEmpty
            && item.payload.utf8.count <= maxItemBytes
    }
}

/// Prior user/assistant conversation captured before provider start.
public struct ConversationContextSnapshot: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let messageId: String
        public let role: ConversationContextSeed.Role
        public let ordinal: Int
        public let canonicalText: String

        public init(
            messageId: String,
            role: ConversationContextSeed.Role,
            ordinal: Int,
            canonicalText: String
        ) {
            self.messageId = messageId
            self.role = role
            self.ordinal = ordinal
            self.canonicalText = canonicalText
        }
    }

    public let items: [Item]
    public let digest: String

    public init(items: [Item], digest: String) {
        self.items = items
        self.digest = digest
    }

    /// Snapshot prior user/assistant rows, excluding the current user prompt.
    /// Returns nil when empty, inconsistent, or too large for the seed bounds.
    public static func capture(
        messages: [AgentMessage],
        excludingCurrentUserText: String?,
        excludingCurrentUserMessageId: AgentMessageID? = nil
    ) -> ConversationContextSnapshot? {
        var prior = messages
        if let excludedId = excludingCurrentUserMessageId,
           let currentIndex = prior.lastIndex(where: { $0.role == .user && $0.id == excludedId }) {
            prior.remove(at: currentIndex)
        } else if let excluded = excludingCurrentUserText, !excluded.isEmpty,
                  let currentIndex = prior.lastIndex(where: {
                      $0.role == .user && $0.content == excluded
                  }) {
            prior.remove(at: currentIndex)
        }
        let eligible = prior.compactMap { message -> Item? in
            let role: ConversationContextSeed.Role
            switch message.role {
            case .user:
                role = .user
            case .assistant:
                role = .assistant
            case .system:
                return nil
            }
            return Item(
                messageId: message.id.value.uuidString,
                role: role,
                ordinal: 0,
                canonicalText: message.content
            )
        }
        guard !eligible.isEmpty, eligible.count <= ConversationContextSeed.maxItems else {
            return nil
        }
        var numbered: [Item] = []
        var total = 0
        for (index, item) in eligible.enumerated() {
            guard !item.canonicalText.isEmpty,
                  item.canonicalText.utf8.count <= ConversationContextSeed.maxItemBytes else {
                return nil
            }
            total += item.canonicalText.utf8.count
            if total > ConversationContextSeed.maxEncodedBytes {
                return nil
            }
            numbered.append(Item(
                messageId: item.messageId,
                role: item.role,
                ordinal: index,
                canonicalText: item.canonicalText
            ))
        }
        return ConversationContextSnapshot(
            items: numbered,
            digest: digest(for: numbered)
        )
    }

    public static func digest(for items: [Item]) -> String {
        let material = items.map { item in
            "\(item.ordinal)\u{1e}\(item.role.rawValue)\u{1e}\(item.messageId)\u{1e}\(item.canonicalText)"
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        // PERF: nibble table avoids 32 String(format:) calls; same lowercase hex.
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for b in digest {
            out.append(conversationContextHexAlphabet[Int(b >> 4)])
            out.append(conversationContextHexAlphabet[Int(b & 0x0F)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}

private let conversationContextHexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

/// Durable, content-free record that one seed slot was handed to a fresh
/// provider session. It keeps a seed from being sent twice for the same run,
/// destination session and snapshot, including after a restart.
public struct ConversationContextSeedReceipt: Sendable, Equatable {
    public enum Lifecycle: String, Sendable, Codable, Equatable {
        case provisional
        case delivered
        case notDelivered = "not_delivered"
        case deliveryUnknown = "delivery_unknown"
    }

    public var runId: String
    public var destinationProviderThreadId: String
    public var snapshotDigest: String
    public var sourceMessageId: String
    public var role: ConversationContextSeed.Role
    public var ordinal: Int
    public var provider: String
    public var resolvedModel: String
    public var lifecycle: Lifecycle
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String,
        sourceMessageId: String,
        role: ConversationContextSeed.Role,
        ordinal: Int,
        provider: String,
        resolvedModel: String,
        lifecycle: Lifecycle = .provisional,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.runId = runId
        self.destinationProviderThreadId = destinationProviderThreadId
        self.snapshotDigest = snapshotDigest
        self.sourceMessageId = sourceMessageId
        self.role = role
        self.ordinal = max(0, ordinal)
        self.provider = provider
        self.resolvedModel = resolvedModel
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ConversationContextSeedAck: Sendable, Equatable {
    public let runId: String
    public let destinationProviderThreadId: String
    public let snapshotDigest: String
    public let sourceMessageId: String
    public let ordinal: Int
    public let lifecycle: ConversationContextSeedReceipt.Lifecycle

    public init(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String,
        sourceMessageId: String,
        ordinal: Int,
        lifecycle: ConversationContextSeedReceipt.Lifecycle
    ) {
        self.runId = runId
        self.destinationProviderThreadId = destinationProviderThreadId
        self.snapshotDigest = snapshotDigest
        self.sourceMessageId = sourceMessageId
        self.ordinal = ordinal
        self.lifecycle = lifecycle
    }
}

public struct PreparedConversationContextSeed: Sendable, Equatable {
    public let encoded: String
    public let document: ConversationContextSeed.Document
    public let receipts: [ConversationContextSeedReceipt]

    public init(
        encoded: String,
        document: ConversationContextSeed.Document,
        receipts: [ConversationContextSeedReceipt]
    ) {
        self.encoded = encoded
        self.document = document
        self.receipts = receipts
    }
}

public enum ConversationContextSeedReceiptError: Error, Equatable {
    case identityMismatch(runId: String)
    case missingReceipt(runId: String)
    case illegalLifecycleTransition(
        runId: String,
        from: ConversationContextSeedReceipt.Lifecycle,
        to: ConversationContextSeedReceipt.Lifecycle
    )
}
