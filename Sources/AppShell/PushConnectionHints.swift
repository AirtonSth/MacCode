import Foundation

/// Public facts about the last successfully published Tailcat catalog host.
/// Never carries `connBlob`, tokens, or keys (APNs payload is 4096 bytes and
/// transits Apple); iOS uses version/lease to decide whether to prefetch.
struct TailcatPushHint: Sendable, Equatable {
    let serverId: String
    let version: Int64
    let leaseExpiresAt: String
    let transportBuildId: String
}

/// Connection + catch-up hints merged into every host -> iOS push `data`
/// (alert, silent catch-up, and outbox replay).
enum PushConnectionHints {
    static let tailcatServerIdKey = "rc2_tc_sid"
    static let tailcatVersionKey = "rc2_tc_ver"
    static let tailcatLeaseExpiresKey = "rc2_tc_exp"
    static let tailcatBuildKey = "rc2_tc_build"
    static let tailcatKeys = [tailcatServerIdKey, tailcatVersionKey, tailcatLeaseExpiresKey, tailcatBuildKey]

    private static let maxServerIdLength = 128
    private static let maxBuildLength = 96
    private static let maxLeaseLength = 40

    /// Returns `data` plus `rc2_wm` / `rc2_boot_epoch` (never overwriting
    /// existing values) and the all-or-nothing `rc2_tc_*` keys. Tailcat keys
    /// are omitted when the hint is missing, malformed, or its lease expired.
    static func merge(
        into data: [String: String],
        tailcat: TailcatPushHint?,
        watermark: String?,
        bootEpoch: String?,
        now: Date = Date()
    ) -> [String: String] {
        var out = data
        let catchUp = SilentCatchUpV1(watermark: watermark, bootEpoch: bootEpoch).asPushData()
        for key in [SilentCatchUpV1.watermarkKey, SilentCatchUpV1.bootEpochKey] where out[key] == nil {
            if let value = catchUp[key] { out[key] = value }
        }
        for key in tailcatKeys { out[key] = nil }
        if let tailcat, let leaseExpiry = validLeaseExpiry(tailcat), leaseExpiry > now {
            out[tailcatServerIdKey] = tailcat.serverId
            out[tailcatVersionKey] = String(tailcat.version)
            out[tailcatLeaseExpiresKey] = tailcat.leaseExpiresAt
            out[tailcatBuildKey] = tailcat.transportBuildId
        }
        return out
    }

    /// Lease expiry when every field passes wire validation, else nil.
    private static func validLeaseExpiry(_ hint: TailcatPushHint) -> Date? {
        guard hint.version >= 0,
              hint.serverId.count <= maxServerIdLength,
              hint.serverId.range(of: #"^[\w.:-]{1,128}$"#, options: .regularExpression) != nil,
              !hint.transportBuildId.isEmpty,
              hint.transportBuildId.count <= maxBuildLength,
              hint.transportBuildId.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x21 }),
              hint.leaseExpiresAt.count <= maxLeaseLength
        else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: hint.leaseExpiresAt) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: hint.leaseExpiresAt)
    }
}
