import Foundation
import CryptoKit

/// V5: embedding cache keyed by (content-hash, model-id, chunker-version). Identical
/// text is embedded once; a model bump or chunker change is a different key, so stale
/// vectors are never served. Bounded LRU so steady-state memory is flat. Used by
/// `MLXEmbeddingBackend` to skip re-embedding repeated blocks (I9.1 vector cache).
public actor EmbeddingCache {
    public struct Key: Hashable, Sendable {
        public let contentHash: String
        public let modelID: String
        public let chunkerVersion: String
    }

    private var store: [Key: [Float]] = [:]
    private var recency: [Key] = []
    private let capacity: Int
    private(set) public var hits = 0
    private(set) public var misses = 0

    public init(capacity: Int = 2048) {
        self.capacity = max(1, capacity)
    }

    public static func key(text: String, modelID: String, chunkerVersion: String) -> Key {
        let hash = DistillSHA256.hex(text)
        return Key(contentHash: hash, modelID: modelID, chunkerVersion: chunkerVersion)
    }

    public func get(_ key: Key) -> [Float]? {
        if let v = store[key] {
            hits += 1
            touch(key)
            return v
        }
        misses += 1
        return nil
    }

    public func put(_ key: Key, _ vector: [Float]) {
        if store[key] == nil, store.count >= capacity, let evict = recency.first {
            store.removeValue(forKey: evict)
            recency.removeFirst()
        }
        store[key] = vector
        touch(key)
    }

    public var count: Int { store.count }

    private func touch(_ key: Key) {
        if let i = recency.firstIndex(of: key) { recency.remove(at: i) }
        recency.append(key)
    }
}
