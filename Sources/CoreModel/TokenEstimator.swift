import Foundation

/// Deterministic token estimate for Token Saver deltas (not billed counts).
///
/// Owned here so SR2 adoption and Distill ledger share one formula. CoreModel
/// cannot import DistillCore.
public enum TokenEstimator {
    /// PERF: `utf8.count` is O(1); a single UTF-8 pass counts space/LF/tab/CR
    /// separators without allocating. ASCII-heavy agent text matches the prior
    /// Character/split estimates exactly.
    public static func estimate(_ text: String) -> Int {
        let chars = text.utf8.count
        guard chars > 0 else { return 0 }
        let byChars = Int((Double(chars) / 4.0).rounded())
        var words = 0
        var inWord = false
        for byte in text.utf8 {
            switch byte {
            case 0x20, 0x0A, 0x09, 0x0D:
                inWord = false
            default:
                if !inWord {
                    inWord = true
                    words += 1
                }
            }
        }
        let byWords = Int((Double(words) * 1.3).rounded())
        return max(1, max(byChars, byWords))
    }
}
