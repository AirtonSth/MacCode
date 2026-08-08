import Foundation

/// Wire contract `silent_catchup.v1` (plan-connection S-001).
/// Silent APNs `data` is opaque flags + numeric strings only — never agent text/titles.
public struct SilentCatchUpV1: Sendable, Equatable {
    public static let schemaVersion = "silent_catchup.v1"
    public static let catchUpKey = "rc2_catch_up"
    public static let schemaKey = "rc2_schema"
    public static let watermarkKey = "rc2_wm"
    public static let sinceSeqKey = "rc2_since_seq"
    public static let bootEpochKey = "rc2_boot_epoch"
    public static let reasonKey = "rc2_reason"

    public var catchUp: Bool
    public var watermark: String?
    public var sinceSeq: String?
    public var bootEpoch: String?
    public var reason: String?

    public init(
        catchUp: Bool = true,
        watermark: String? = nil,
        sinceSeq: String? = nil,
        bootEpoch: String? = nil,
        reason: String? = nil
    ) {
        self.catchUp = catchUp
        self.watermark = Self.sanitizeNumericString(watermark)
        self.sinceSeq = Self.sanitizeNumericString(sinceSeq)
        self.bootEpoch = Self.sanitizeNumericString(bootEpoch)
        self.reason = Self.sanitizeReason(reason)
    }

    /// Push `data` map for private backend / APNs custom data (all string values).
    public func asPushData() -> [String: String] {
        var data: [String: String] = [
            Self.catchUpKey: catchUp ? "1" : "0",
            Self.schemaKey: Self.schemaVersion,
        ]
        if let watermark, !watermark.isEmpty { data[Self.watermarkKey] = watermark }
        if let sinceSeq, !sinceSeq.isEmpty { data[Self.sinceSeqKey] = sinceSeq }
        if let bootEpoch, !bootEpoch.isEmpty { data[Self.bootEpochKey] = bootEpoch }
        if let reason, !reason.isEmpty { data[Self.reasonKey] = reason }
        return data
    }

    /// Parse host/iOS userInfo or backend data; ignore unknown keys.
    public static func parse(_ userInfo: [AnyHashable: Any]) -> SilentCatchUpV1? {
        guard isCatchUpFlag(userInfo[Self.catchUpKey] ?? userInfo["rc2_catch_up"]) else {
            // Also accept aps content-available path without explicit flag only via caller.
            return nil
        }
        return SilentCatchUpV1(
            catchUp: true,
            watermark: stringValue(userInfo[Self.watermarkKey]),
            sinceSeq: stringValue(userInfo[Self.sinceSeqKey]),
            bootEpoch: stringValue(userInfo[Self.bootEpochKey]),
            reason: stringValue(userInfo[Self.reasonKey])
        )
    }

    public static func isCatchUpFlag(_ raw: Any?) -> Bool {
        switch raw {
        case let b as Bool: return b
        case let i as Int: return i == 1
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t == "1" || t == "true" || t == "yes"
        default: return false
        }
    }

    private static func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let s as String: return s
        case let i as Int: return String(i)
        case let i as Int64: return String(i)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Only digits / optional leading sign — refuse free-form content (privacy).
    // PERF: silent wake payloads sanitize watermark/sinceSeq/bootEpoch on every
    // agent-completion catch-up; share one digit/sign set instead of allocating
    // CharacterSet(charactersIn:) per field.
    private static let numericWireScalars = CharacterSet(charactersIn: "0123456789+-")

    private static func sanitizeNumericString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ numericWireScalars.contains($0) }) else { return nil }
        return trimmed
    }

    /// Short opaque reason tokens only (snake_case), max 32 chars.
    private static func sanitizeReason(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let filtered = trimmed.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }
        let s = String(filtered).prefix(32)
        return s.isEmpty ? nil : String(s)
    }
}
