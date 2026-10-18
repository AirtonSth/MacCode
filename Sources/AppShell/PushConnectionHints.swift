import Foundation

/// Connection + catch-up hints merged into every host -> iOS push `data`
/// (alert, silent catch-up, and outbox replay).
enum PushConnectionHints {
    /// Returns `data` plus `rc2_wm` / `rc2_boot_epoch`, never overwriting existing values.
    static func merge(
        into data: [String: String],
        watermark: String?,
        bootEpoch: String?
    ) -> [String: String] {
        var out = data
        let catchUp = SilentCatchUpV1(watermark: watermark, bootEpoch: bootEpoch).asPushData()
        for key in [SilentCatchUpV1.watermarkKey, SilentCatchUpV1.bootEpochKey] where out[key] == nil {
            if let value = catchUp[key] { out[key] = value }
        }
        return out
    }
}
