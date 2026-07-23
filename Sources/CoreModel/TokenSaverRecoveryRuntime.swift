import Foundation

/// Host-owned recovery runtime (task-16). Default OFF for lossy admits.
public final class TokenSaverRecoveryRuntime: @unchecked Sendable {
    public static let taskID = "task-16"

    public struct HandleRecord: Sendable, Equatable {
        public let handle: String
        public let scopeDigest: String
        public let payload: Data
        public var revoked: Bool
    }

    public struct SearchHit: Sendable, Equatable {
        public let handle: String
        public let excerpt: String
    }

    private let lock = NSLock()
    private var byHandle: [String: HandleRecord] = [:]
    private var _live: Bool = TokenSaverRecoveryProjections.defaultEnabled
    public var maxSearchHits: Int = 32
    public var excerptBytes: Int = 200

    public init() {}

    public var live: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _live }
        set { lock.lock(); _live = newValue; lock.unlock() }
    }

    private static func normalizeHandle(_ handle: String) -> String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First store wins. Same-byte/same-scope replay is idempotent; rebind,
    /// overwrite, and resurrection of revoked handles are rejected.
    public func store(handle: String, scopeDigest: String, payload: Data) -> Bool {
        let h = Self.normalizeHandle(handle)
        let scope = scopeDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !scope.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if let existing = byHandle[h] {
            return !existing.revoked
                && existing.scopeDigest == scope
                && existing.payload == payload
        }
        byHandle[h] = HandleRecord(handle: h, scopeDigest: scope, payload: payload, revoked: false)
        return true
    }

    public func revoke(_ handle: String) {
        let h = Self.normalizeHandle(handle)
        lock.lock()
        if var rec = byHandle[h] {
            rec.revoked = true
            byHandle[h] = rec
        } else {
            byHandle[h] = HandleRecord(handle: h, scopeDigest: "", payload: Data(), revoked: true)
        }
        lock.unlock()
    }

    /// Budgeted excerpt+handle hits, same-scope only.
    public func search(queryScope: String, resultHandles: [String]) -> [SearchHit] {
        lock.lock()
        let isLive = _live
        let snapshot = byHandle
        let budget = maxSearchHits
        let excerptN = excerptBytes
        lock.unlock()
        guard isLive else { return [] }
        var hits: [SearchHit] = []
        for raw in resultHandles {
            if hits.count >= budget { break }
            let h = Self.normalizeHandle(raw)
            guard let rec = snapshot[h], !rec.revoked else { continue }
            guard TokenSaverRecoveryProjections.admitSearch(
                queryScopeDigest: queryScope,
                resultScopeDigest: rec.scopeDigest,
                live: true
            ) else { continue }
            let excerpt = Self.makeExcerpt(rec.payload, maxBytes: excerptN)
            hits.append(SearchHit(handle: h, excerpt: excerpt))
        }
        return hits
    }

    /// Exact retrieve requires caller-supplied expected bytes matching stored payload.
    public func retrieve(handle: String, queryScopeDigest: String, expected: Data) -> Data? {
        let h = Self.normalizeHandle(handle)
        let scope = queryScopeDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        let isLive = _live
        let rec = byHandle[h]
        lock.unlock()
        guard let rec, !scope.isEmpty, rec.scopeDigest == scope else { return nil }
        let ok = TokenSaverRecoveryProjections.admitRetrieve(
            bytes: rec.payload,
            original: expected,
            handle: h,
            revoked: rec.revoked,
            live: isLive
        )
        return ok ? rec.payload : nil
    }

    public func resumeNeedsFullHistory(tailGap: Bool) -> Bool {
        TokenSaverRecoveryProjections.resumeTailGapLoadsFull(tailGap)
    }

    public func workspaceNeedsFullSnapshot(gap: Bool) -> Bool {
        TokenSaverRecoveryProjections.workspaceGapForcesFullSnapshot(gap)
    }

    /// Cap final UTF-8 representation to maxBytes (never expands via base64).
    private static func makeExcerpt(_ data: Data, maxBytes: Int) -> String {
        let budget = max(0, maxBytes)
        guard budget > 0 else { return "" }
        // Prefer valid UTF-8 prefix within budget.
        var n = min(budget, data.count)
        while n > 0 {
            let slice = data.prefix(n)
            if let s = String(data: slice, encoding: .utf8), s.utf8.count <= budget {
                return s
            }
            n -= 1
        }
        return ""
    }
}
