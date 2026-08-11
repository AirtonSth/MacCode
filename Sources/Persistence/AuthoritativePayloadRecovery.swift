import Foundation

/// Exact authoritative ingress recovery for oversized presentation (S3 / T-003).
///
/// Before any presentation truncation at the 16 MiB boundary, store the original
/// bytes in `ReversibleContentStore`, embed a resolvable `[[rc:<handle>]]` marker,
/// and rehydrate byte-identically. Unresolved handles must be stripped from final
/// user-facing assistant persistence.

public enum AuthoritativePayloadRecovery {
    /// Presentation truncation boundary (16 MiB).
    public static let presentationByteLimit = 16 * 1024 * 1024
    /// Owned trailer prefix so recovery detection cannot collide with provider content.
    public static let ownedTrailerToken = "rc_oversized_v1"

    /// Parse original byte count from an owned presentation trailer when present.
    /// Used for hot-replay admission so rehydrate cannot expand past the budget.
    /// `payload` may be a full row or only a trailing suffix (metadata path).
    public static func authoritativeByteCount(
        forStoredPayload payload: String,
        presentationFallback: Int? = nil
    ) -> Int {
        let presentation = presentationFallback ?? payload.utf8.count
        // Allow match at end of full payload or within a short trailer suffix.
        let pattern = #"…\[truncated rc_oversized_v1 (\d+)→(\d+) bytes\]\[\[rc:[0-9a-fA-F]+\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: payload,
                options: [],
                range: NSRange(payload.startIndex..., in: payload)
              ),
              match.numberOfRanges >= 2,
              let originalRange = Range(match.range(at: 1), in: payload),
              let original = Int(payload[originalRange]),
              original > 0 else {
            return presentation
        }
        return original
    }


    public struct RecoveryResult: Sendable, Equatable {
        public var presentationText: String
        public var handle: String?
        public var originalByteCount: Int
        public var storedOriginal: Bool
        public var truncatedForPresentation: Bool

        public init(
            presentationText: String,
            handle: String?,
            originalByteCount: Int,
            storedOriginal: Bool,
            truncatedForPresentation: Bool
        ) {
            self.presentationText = presentationText
            self.handle = handle
            self.originalByteCount = originalByteCount
            self.storedOriginal = storedOriginal
            self.truncatedForPresentation = truncatedForPresentation
        }
    }

    public enum RecoveryError: Error, Equatable, LocalizedError {
        case storeFailed(String)
        case rehydrateMismatch
        case unresolvedHandle(String)

        public var errorDescription: String? {
            switch self {
            case .storeFailed(let reason):
                return "Authoritative payload store failed: \(reason)"
            case .rehydrateMismatch:
                return "Rehydrated payload is not byte-identical to the original"
            case .unresolvedHandle(let handle):
                return "Unresolved reversible content handle: \(handle)"
            }
        }
    }

    /// If `data` exceeds the presentation limit, store original and return a
    /// presentation prefix plus marker. Smaller payloads pass through unchanged.
    public static func prepareForPresentation(
        data: Data,
        store: ReversibleContentStore,
        limit: Int = presentationByteLimit
    ) throws -> RecoveryResult {
        let byteCount = data.count
        if byteCount <= limit {
            let text = String(decoding: data, as: UTF8.self)
            return RecoveryResult(
                presentationText: text,
                handle: nil,
                originalByteCount: byteCount,
                storedOriginal: false,
                truncatedForPresentation: false
            )
        }

        let handle: String
        do {
            handle = try store.store(data)
        } catch {
            throw RecoveryError.storeFailed(String(describing: error))
        }

        // Soft-truncated the presentation form (keeps legacy "truncated" trailer
        // semantics) while the exact original is recoverable via [[rc:handle]].
        let marker = ReversibleContentStore.marker(for: handle)
        let trailer = "…[truncated \(AuthoritativePayloadRecovery.ownedTrailerToken) \(byteCount)→\(limit) bytes]\(marker)"
        let headBudget = max(0, limit - trailer.utf8.count)
        let text = String(decoding: data, as: UTF8.self)
        let presentation: String
        if headBudget <= 0 {
            presentation = trailer
        } else {
            var utf8End = text.utf8.index(
                text.utf8.startIndex,
                offsetBy: headBudget,
                limitedBy: text.utf8.endIndex
            ) ?? text.utf8.endIndex
            var head: String?
            while utf8End > text.utf8.startIndex {
                if let end = utf8End.samePosition(in: text) {
                    head = String(text[..<end])
                    break
                }
                text.utf8.formIndex(before: &utf8End)
            }
            presentation = (head ?? "") + trailer
        }

        return RecoveryResult(
            presentationText: presentation,
            handle: handle,
            originalByteCount: byteCount,
            storedOriginal: true,
            truncatedForPresentation: true
        )
    }

    public static func prepareForPresentation(
        text: String,
        store: ReversibleContentStore,
        limit: Int = presentationByteLimit
    ) throws -> RecoveryResult {
        try prepareForPresentation(data: Data(text.utf8), store: store, limit: limit)
    }

    /// Byte-identical rehydrate of a stored handle.
    public static func rehydrate(
        handle: String,
        store: ReversibleContentStore,
        expected: Data? = nil
    ) throws -> Data {
        guard let data = try store.retrieve(handle) else {
            throw RecoveryError.unresolvedHandle(handle)
        }
        if let expected, data != expected {
            throw RecoveryError.rehydrateMismatch
        }
        return data
    }

    /// Strip unresolved `[[rc:...]]` markers from final user-facing assistant text.
    public static func stripUnresolvedHandles(
        from text: String,
        resolve: (String) -> Bool
    ) -> String {
        let pattern = #"\[\[rc:([0-9a-fA-F]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        // Replace from end so ranges stay valid.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let full = Range(match.range(at: 0), in: result),
                  let handleRange = Range(match.range(at: 1), in: result) else { continue }
            let handle = String(result[handleRange])
            if !resolve(handle) {
                result.replaceSubrange(full, with: "")
            }
        }
        return result
    }

    /// Pure decision: whether an ingress payload must take the recovery path.
    public static func requiresRecovery(byteCount: Int, limit: Int = presentationByteLimit) -> Bool {
        byteCount > limit
    }
}
