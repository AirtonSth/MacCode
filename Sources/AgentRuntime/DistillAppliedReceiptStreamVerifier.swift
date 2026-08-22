import CoreModel
import CryptoKit
import Foundation

/// Bounded verifier for receipt-bearing provider item streams.
///
/// The full output is hashed incrementally. Only enough trailing bytes to hold
/// one complete receipt line are retained, so a large tool result cannot become
/// a second in-memory copy merely to attest its final marker.
package struct DistillAppliedReceiptStreamVerifier: Sendable {
    package struct Scope: Sendable, Equatable {
        package let rootRunID: String
        package let key: Data

        package init(rootRunID: String, key: Data) {
            self.rootRunID = rootRunID
            self.key = key
        }
    }

    private struct Channel: Sendable {
        private static let retainedTailByteCount =
            DistillAppliedReceipt.maximumV2MarkerByteCount + 3 // preceding LF + terminal CRLF

        private var hasher = SHA256()
        private var tail = Data()
        private var totalByteCount = 0

        mutating func append(_ text: String?) {
            guard let text, !text.isEmpty else { return }
            append(Data(text.utf8))
        }

        private mutating func append(_ data: Data) {
            guard !data.isEmpty else { return }
            totalByteCount += data.count
            tail.append(data)
            let overflow = tail.count - Self.retainedTailByteCount
            guard overflow > 0 else { return }
            hasher.update(data: tail.prefix(overflow))
            tail.removeFirst(overflow)
        }

        func verifiedNonce(scope: Scope) -> Data? {
            guard let marker = DistillAppliedReceipt.parseTrailingV2Marker(in: tail) else {
                return nil
            }
            let signedTail = tail.prefix(marker.markerByteRange.lowerBound)
            var finalHasher = hasher
            finalHasher.update(data: signedTail)
            let digest = Data(finalHasher.finalize())
            let signedByteCount = totalByteCount
                - (tail.count - marker.markerByteRange.lowerBound)
            guard DistillAppliedReceipt.verify(
                marker,
                rootRunID: scope.rootRunID,
                payloadByteCount: signedByteCount,
                payloadSHA256: digest,
                key: scope.key
            ) else {
                return nil
            }
            return marker.nonce
        }
    }

    private struct Item: Sendable {
        var orderingIsValid: Bool
        var body = Channel()
        var output = Channel()
    }

    private static let itemLimit = 5_000
    package static let maximumTrackedReceiptNoncesPerRun = 5_000
    private var items: [String: Item] = [:]
    private var itemOrder: [String] = []
    private var consumedNonces: Set<Data> = []

    package init() {}

    package mutating func startItem(
        id: String,
        body: String,
        output: String?
    ) {
        guard items[id] == nil else {
            // Duplicate starts or a delta-before-start make byte ordering
            // ambiguous. Fail closed for the badge while leaving text untouched.
            items[id]?.orderingIsValid = false
            return
        }
        var item = Item(orderingIsValid: true)
        item.body.append(body)
        item.output.append(output)
        items[id] = item
        itemOrder.append(id)
        trimItems()
    }

    package mutating func append(
        itemID: String,
        body: String?,
        output: String?
    ) {
        guard var item = items[itemID] else {
            items[itemID] = Item(orderingIsValid: false)
            itemOrder.append(itemID)
            trimItems()
            return
        }
        item.body.append(body)
        item.output.append(output)
        items[itemID] = item
    }

    /// Finalizes one item and consumes a valid nonce exactly once per run.
    package mutating func complete(itemID: String, scope: Scope) -> Bool {
        guard let item = items.removeValue(forKey: itemID) else { return false }
        itemOrder.removeAll { $0 == itemID }
        guard item.orderingIsValid else { return false }
        for channel in [item.output, item.body] {
            guard let nonce = channel.verifiedNonce(scope: scope) else { continue }
            return consume(nonce)
        }
        return false
    }

    /// Authenticates a terminal prose payload without retaining it in the item map.
    package mutating func authenticateStandalone(_ text: String, scope: Scope) -> Bool {
        var channel = Channel()
        channel.append(text)
        guard let nonce = channel.verifiedNonce(scope: scope) else { return false }
        return consume(nonce)
    }

    package mutating func endTurn() {
        items.removeAll(keepingCapacity: true)
        itemOrder.removeAll(keepingCapacity: true)
    }

    package mutating func reset() {
        endTurn()
        consumedNonces.removeAll(keepingCapacity: true)
    }

    private mutating func consume(_ nonce: Data) -> Bool {
        guard !consumedNonces.contains(nonce),
              consumedNonces.count < Self.maximumTrackedReceiptNoncesPerRun else {
            // Never evict: accepting an old nonce again would let provider-owned
            // text replay a previously valid receipt. Saturation only removes the
            // badge claim; the provider output itself still passes through.
            return false
        }
        consumedNonces.insert(nonce)
        return true
    }

    private mutating func trimItems() {
        while itemOrder.count > Self.itemLimit {
            let oldest = itemOrder.removeFirst()
            items.removeValue(forKey: oldest)
        }
    }
}
