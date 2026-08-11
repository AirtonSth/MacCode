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

        let prefix = data.prefix(limit)
        var presentation = String(decoding: prefix, as: UTF8.self)
        // Ensure we do not claim a complete body: append recoverable marker.
        let marker = ReversibleContentStore.marker(for: handle)
        presentation += "\n\(marker)\n"

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
