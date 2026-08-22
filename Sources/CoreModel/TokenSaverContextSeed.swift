import CryptoKit

private let _tokenSaverContextSeedHexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)
import Foundation

/// Host-owned, provider-neutral conversation seed (`RCSEED1/1`).
///
/// Contains only selected representations plus role/order metadata so a fresh
/// destination can reconstruct the canonical prior conversation. Visible
/// transcript stays Human; this document is never ordinary message content.
public enum TokenSaverContextSeed {
    public static let version = "RCSEED1/1"
    public static let maxEncodedBytes = RemoteCodeCompactSpan.maxWireBytes
    public static let maxItemBytes = RemoteCodeCompactSpan.maxDecodedBytes
    public static let maxItems = 100

    public enum Role: String, Sendable, Equatable, Codable {
        case user
        case assistant
    }

    public struct Item: Sendable, Equatable {
        public let role: Role
        public let ordinal: Int
        public let sourceMessageId: String
        public let format: TokenSaverBestOfThreeSelector.Format
        public let payload: String

        public init(
            role: Role,
            ordinal: Int,
            sourceMessageId: String,
            format: TokenSaverBestOfThreeSelector.Format,
            payload: String
        ) {
            self.role = role
            self.ordinal = ordinal
            self.sourceMessageId = sourceMessageId
            self.format = format
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
                "I\t\(item.ordinal)\t\(item.role.rawValue)\t\(item.format.rawValue)\t\(payloadBytes.count)\t\(item.sourceMessageId)\n".utf8
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
                  let formatText = String(bytes: fields[3], encoding: .utf8),
                  let format = TokenSaverBestOfThreeSelector.Format(rawValue: formatText),
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
                format: format,
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
            && (item.role != .user || item.format == .human)
    }
}

/// Canonical prior conversation captured before provider start.
public struct TokenSaverCanonicalConversationSnapshot: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let messageId: String
        public let role: TokenSaverContextSeed.Role
        public let ordinal: Int
        public let canonicalText: String
        public let persistedRCW1: String?

        public init(
            messageId: String,
            role: TokenSaverContextSeed.Role,
            ordinal: Int,
            canonicalText: String,
            persistedRCW1: String? = nil
        ) {
            self.messageId = messageId
            self.role = role
            self.ordinal = ordinal
            self.canonicalText = canonicalText
            self.persistedRCW1 = persistedRCW1
        }
    }

    public let items: [Item]
    public let digest: String

    public init(items: [Item], digest: String) {
        self.items = items
        self.digest = digest
    }

    /// Snapshot prior user/assistant rows, excluding the current user prompt.
    /// Returns nil when empty, inconsistent, or too large for existing bounds.
    public static func capture(
        messages: [AgentMessage],
        persistedRCW1ByMessageId: [String: String],
        excludingCurrentUserText: String?,
        excludingCurrentUserMessageId: AgentMessageID? = nil
    ) -> TokenSaverCanonicalConversationSnapshot? {
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
            let role: TokenSaverContextSeed.Role
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
                canonicalText: message.content,
                persistedRCW1: role == .assistant
                    ? persistedRCW1ByMessageId[message.id.value.uuidString]
                    : nil
            )
        }
        guard !eligible.isEmpty, eligible.count <= TokenSaverContextSeed.maxItems else {
            return nil
        }
        var numbered: [Item] = []
        var total = 0
        for (index, item) in eligible.enumerated() {
            guard !item.canonicalText.isEmpty,
                  item.canonicalText.utf8.count <= TokenSaverContextSeed.maxItemBytes else {
                return nil
            }
            total += item.canonicalText.utf8.count
            if total > TokenSaverContextSeed.maxEncodedBytes {
                return nil
            }
            numbered.append(Item(
                messageId: item.messageId,
                role: item.role,
                ordinal: index,
                canonicalText: item.canonicalText,
                persistedRCW1: item.persistedRCW1
            ))
        }
        return TokenSaverCanonicalConversationSnapshot(
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
            out.append(_tokenSaverContextSeedHexAlphabet[Int(b >> 4)])
            out.append(_tokenSaverContextSeedHexAlphabet[Int(b & 0x0F)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}

/// Independently constructed Human / RCW1 / RCS1 arms for one assistant context item.
public enum TokenSaverContextItemSelector {
    public static func ineligibleRCW1Candidate(
        sourceSHA256: String
    ) -> TokenSaverBestOfThreeSelector.Candidate {
        TokenSaverBestOfThreeSelector.Candidate(
            format: .rcw1,
            sourceSHA256: sourceSHA256,
            payload: "RCW1_CONTEXT_INELIGIBLE",
            abi: "RCW1_ABI_INELIGIBLE",
            effectiveEnvelope: "RCW1_ABI_INELIGIBLE\nRCW1_CONTEXT_INELIGIBLE",
            handle: nil,
            producerID: TokenSaverRequestSelectionReceipt.rcw1ProducerID,
            producerRevision: "ineligible",
            abiRevision: "ineligible",
            generation: .passed,
            structural: .failed,
            semantic: .failed,
            recovery: .failed
        )
    }

    public static func ineligibleRCS1Candidate(
        sourceSHA256: String
    ) -> TokenSaverBestOfThreeSelector.Candidate {
        TokenSaverBestOfThreeSelector.Candidate(
            format: .rcs1,
            sourceSHA256: sourceSHA256,
            payload: "RCS1_CONTEXT_INELIGIBLE",
            abi: "RCS1_ABI_INELIGIBLE",
            effectiveEnvelope: "RCS1_ABI_INELIGIBLE\nRCS1_CONTEXT_INELIGIBLE",
            handle: nil,
            producerID: TokenSaverRequestSelectionReceipt.rcs1UnavailableProducerID,
            producerRevision: "ineligible",
            abiRevision: "ineligible",
            generation: .failed,
            structural: .failed,
            semantic: .failed,
            recovery: .failed
        )
    }

    /// RCW1 is eligible only from persisted provider-authored response bytes
    /// that already satisfy existing structural, semantic, and exact Human
    /// recovery gates. There is no Human → RCW1 A encoder here.
    public static func rcw1Candidate(
        canonicalHuman: String,
        persistedProviderWire: String?,
        abi: String = "RCW1 ABI",
        effectiveEnvelope: String? = nil
    ) -> TokenSaverBestOfThreeSelector.Candidate {
        let sourceSHA256 = sha256Hex(canonicalHuman)
        guard let wire = persistedProviderWire,
              !wire.isEmpty,
              wire != RemoteCodeCompactSpan.encode(canonicalHuman) else {
            return ineligibleRCW1Candidate(sourceSHA256: sourceSHA256)
        }
        guard let projection = RCWireProtocol.strictResponseProjection(raw: wire) else {
            var failed = ineligibleRCW1Candidate(sourceSHA256: sourceSHA256)
            failed = withGates(
                format: .rcw1,
                sourceSHA256: sourceSHA256,
                payload: wire,
                abi: abi,
                envelope: effectiveEnvelope ?? "\(abi)\n\(wire)",
                generation: .passed,
                structural: .failed,
                semantic: .failed,
                recovery: .failed
            )
            return failed
        }
        let frames: [RCWireFrame]
        do {
            frames = try RCWireProtocol.parse(wire)
        } catch {
            return withGates(
                format: .rcw1,
                sourceSHA256: sourceSHA256,
                payload: wire,
                abi: abi,
                envelope: effectiveEnvelope ?? "\(abi)\n\(wire)",
                generation: .passed,
                structural: .failed,
                semantic: .failed,
                recovery: .failed
            )
        }
        let semanticOK = RCWireProtocol.renderedTextPreservesProtectedSemantics(
            canonicalHuman,
            frames: frames
        )
        let recoveryOK = projection.deterministicHuman == canonicalHuman
        let structuralOK = frames.allSatisfy { $0.direction == .response }
        guard structuralOK, semanticOK, recoveryOK else {
            return withGates(
                format: .rcw1,
                sourceSHA256: sourceSHA256,
                payload: wire,
                abi: abi,
                envelope: effectiveEnvelope ?? "\(abi)\n\(wire)",
                generation: .passed,
                structural: structuralOK ? .passed : .failed,
                semantic: semanticOK ? .passed : .failed,
                recovery: recoveryOK ? .passed : .failed
            )
        }
        let envelope = effectiveEnvelope ?? "\(abi)\n\(wire)"
        return TokenSaverBestOfThreeSelector.Candidate(
            format: .rcw1,
            sourceSHA256: sourceSHA256,
            payload: wire,
            abi: abi,
            effectiveEnvelope: envelope,
            handle: nil,
            producerID: TokenSaverRequestSelectionReceipt.rcw1ProducerID,
            producerRevision: "1",
            abiRevision: "1",
            generation: .passed,
            structural: .passed,
            semantic: .passed,
            recovery: .passed
        )
    }

    public static func rcs1Candidate(
        canonicalHuman: String,
        encodedItem: String? = nil,
        abi: String,
        effectiveEnvelope: String
    ) -> TokenSaverBestOfThreeSelector.Candidate {
        let sourceSHA256 = sha256Hex(canonicalHuman)
        let item: String
        if let encodedItem {
            item = encodedItem
        } else if let encoded = RemoteCodeCompactSpan.encode(canonicalHuman) {
            item = encoded
        } else {
            return TokenSaverBestOfThreeSelector.Candidate(
                format: .rcs1,
                sourceSHA256: sourceSHA256,
                payload: "RCS1_CONTEXT_INELIGIBLE",
                abi: abi,
                effectiveEnvelope: effectiveEnvelope,
                handle: nil,
                producerID: TokenSaverRequestSelectionReceipt.rcs1UnavailableProducerID,
                producerRevision: "ineligible",
                abiRevision: "ineligible",
                generation: .failed,
                structural: .failed,
                semantic: .failed,
                recovery: .failed
            )
        }
        let decoded = RemoteCodeCompactSpan.decode(item)
        let structural = decoded != nil ? TokenSaverBestOfThreeSelector.GateStatus.passed : .failed
        let recovery = decoded == canonicalHuman ? TokenSaverBestOfThreeSelector.GateStatus.passed : .failed
        return TokenSaverBestOfThreeSelector.Candidate(
            format: .rcs1,
            sourceSHA256: sourceSHA256,
            payload: item,
            abi: abi,
            effectiveEnvelope: effectiveEnvelope,
            handle: nil,
            producerID: TokenSaverRequestSelectionReceipt.rcs1ProducerID,
            producerRevision: "1",
            abiRevision: "1",
            generation: .passed,
            structural: structural,
            semantic: recovery,
            recovery: recovery
        )
    }

    package static func select(
        canonicalHuman: String,
        humanEnvelope: String,
        rcw1: TokenSaverBestOfThreeSelector.Candidate,
        rcs1: TokenSaverBestOfThreeSelector.Candidate,
        target: TokenSaverBestOfThreeSelector.Target,
        counter: TokenSaverBestOfThreeSelector.CounterCapability?
    ) async -> TokenSaverBestOfThreeSelector.Decision {
        await TokenSaverBestOfThreeSelector.select(
            canonicalHuman: canonicalHuman,
            humanOutboundPrompt: canonicalHuman,
            humanEffectiveEnvelope: humanEnvelope,
            target: target,
            candidates: [rcw1, rcs1],
            counter: counter
        )
    }

    private static func withGates(
        format: TokenSaverBestOfThreeSelector.Format,
        sourceSHA256: String,
        payload: String,
        abi: String,
        envelope: String,
        generation: TokenSaverBestOfThreeSelector.GateStatus,
        structural: TokenSaverBestOfThreeSelector.GateStatus,
        semantic: TokenSaverBestOfThreeSelector.GateStatus,
        recovery: TokenSaverBestOfThreeSelector.GateStatus
    ) -> TokenSaverBestOfThreeSelector.Candidate {
        TokenSaverBestOfThreeSelector.Candidate(
            format: format,
            sourceSHA256: sourceSHA256,
            payload: payload,
            abi: abi,
            effectiveEnvelope: envelope,
            handle: nil,
            producerID: format == .rcw1
                ? TokenSaverRequestSelectionReceipt.rcw1ProducerID
                : TokenSaverRequestSelectionReceipt.rcs1ProducerID,
            producerRevision: "1",
            abiRevision: "1",
            generation: generation,
            structural: structural,
            semantic: semantic,
            recovery: recovery
        )
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        // PERF: nibble table avoids 32 String(format:) calls; same lowercase hex.
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for b in digest {
            out.append(_tokenSaverContextSeedHexAlphabet[Int(b >> 4)])
            out.append(_tokenSaverContextSeedHexAlphabet[Int(b & 0x0F)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}

/// Builds a complete RCSEED1 document from a snapshot. Assistant items are
/// selected independently; user items stay Human. Never emits a partial seed.
public enum TokenSaverContextSeedBuilder {
    public struct ProjectedEnvelope: Sendable, Equatable {
        public let payload: String
        public let abi: String
        public let effectiveEnvelope: String

        public init(payload: String, abi: String, effectiveEnvelope: String) {
            self.payload = payload
            self.abi = abi
            self.effectiveEnvelope = effectiveEnvelope
        }
    }

    public struct Prepared: Sendable, Equatable {
        public let seed: TokenSaverContextSeed.Document
        public let encoded: String
        public let decisions: [TokenSaverBestOfThreeSelector.Decision]

        public init(
            seed: TokenSaverContextSeed.Document,
            encoded: String,
            decisions: [TokenSaverBestOfThreeSelector.Decision]
        ) {
            self.seed = seed
            self.encoded = encoded
            self.decisions = decisions
        }
    }

    package static func prepare(
        snapshot: TokenSaverCanonicalConversationSnapshot,
        target: TokenSaverBestOfThreeSelector.Target,
        counter: TokenSaverBestOfThreeSelector.CounterCapability?,
        project: @Sendable (TokenSaverBestOfThreeSelector.Format, String) -> ProjectedEnvelope?
    ) async -> Prepared? {
        guard !snapshot.items.isEmpty,
              snapshot.items.count <= TokenSaverContextSeed.maxItems,
              snapshot.digest == TokenSaverCanonicalConversationSnapshot.digest(for: snapshot.items) else {
            return nil
        }
        var selected: [TokenSaverContextSeed.Item] = []
        var decisions: [TokenSaverBestOfThreeSelector.Decision] = []
        for item in snapshot.items {
            if item.role == .user {
                guard item.canonicalText == item.canonicalText,
                      !item.canonicalText.isEmpty else {
                    return nil
                }
                selected.append(TokenSaverContextSeed.Item(
                    role: .user,
                    ordinal: item.ordinal,
                    sourceMessageId: item.messageId,
                    format: .human,
                    payload: item.canonicalText
                ))
                continue
            }
            guard let humanProjection = project(.human, item.canonicalText) else {
                return nil
            }
            let rcw1Base = TokenSaverContextItemSelector.rcw1Candidate(
                canonicalHuman: item.canonicalText,
                persistedProviderWire: item.persistedRCW1
            )
            let rcw1Projected: TokenSaverBestOfThreeSelector.Candidate
            if rcw1Base.structural == .passed,
               rcw1Base.semantic == .passed,
               rcw1Base.recovery == .passed,
               let projected = project(.rcw1, rcw1Base.payload) {
                rcw1Projected = TokenSaverBestOfThreeSelector.Candidate(
                    format: .rcw1,
                    sourceSHA256: rcw1Base.sourceSHA256,
                    payload: projected.payload,
                    abi: projected.abi,
                    effectiveEnvelope: projected.effectiveEnvelope,
                    handle: rcw1Base.handle,
                    producerID: rcw1Base.producerID,
                    producerRevision: rcw1Base.producerRevision,
                    abiRevision: rcw1Base.abiRevision,
                    generation: rcw1Base.generation,
                    structural: rcw1Base.structural,
                    semantic: rcw1Base.semantic,
                    recovery: rcw1Base.recovery
                )
            } else {
                rcw1Projected = TokenSaverContextItemSelector.ineligibleRCW1Candidate(
                    sourceSHA256: rcw1Base.sourceSHA256
                )
            }
            let rcs1: TokenSaverBestOfThreeSelector.Candidate
            if let encoded = RemoteCodeCompactSpan.encode(item.canonicalText) {
                let candidate = TokenSaverContextItemSelector.rcs1Candidate(
                    canonicalHuman: item.canonicalText,
                    encodedItem: encoded,
                    abi: "RCS1 ABI",
                    effectiveEnvelope: "RCS1 ABI\n\(encoded)"
                )
                if candidate.recovery == .passed,
                   let projected = project(.rcs1, encoded) {
                    rcs1 = TokenSaverBestOfThreeSelector.Candidate(
                        format: .rcs1,
                        sourceSHA256: candidate.sourceSHA256,
                        payload: projected.payload,
                        abi: projected.abi,
                        effectiveEnvelope: projected.effectiveEnvelope,
                        handle: nil,
                        producerID: candidate.producerID,
                        producerRevision: candidate.producerRevision,
                        abiRevision: candidate.abiRevision,
                        generation: candidate.generation,
                        structural: candidate.structural,
                        semantic: candidate.semantic,
                        recovery: candidate.recovery
                    )
                } else {
                    rcs1 = TokenSaverContextItemSelector.ineligibleRCS1Candidate(
                        sourceSHA256: candidate.sourceSHA256
                    )
                }
            } else {
                rcs1 = TokenSaverContextItemSelector.rcs1Candidate(
                    canonicalHuman: item.canonicalText,
                    abi: "RCS1 ABI",
                    effectiveEnvelope: "RCS1 ABI\nRCS1_UNAVAILABLE"
                )
            }
            let decision = await TokenSaverContextItemSelector.select(
                canonicalHuman: item.canonicalText,
                humanEnvelope: humanProjection.effectiveEnvelope,
                rcw1: rcw1Projected,
                rcs1: rcs1,
                target: target,
                counter: counter
            )
            decisions.append(decision)
            let payload: String
            switch decision.selectedFormat {
            case .human:
                payload = item.canonicalText
            case .rcw1, .rcs1:
                payload = decision.selectedPayload
            }
            selected.append(TokenSaverContextSeed.Item(
                role: .assistant,
                ordinal: item.ordinal,
                sourceMessageId: item.messageId,
                format: decision.selectedFormat,
                payload: payload
            ))
        }
        guard let encoded = TokenSaverContextSeed.encode(
            snapshotDigest: snapshot.digest,
            items: selected
        ) else {
            return nil
        }
        return Prepared(
            seed: TokenSaverContextSeed.Document(snapshotDigest: snapshot.digest, items: selected),
            encoded: encoded,
            decisions: decisions
        )
    }
}
