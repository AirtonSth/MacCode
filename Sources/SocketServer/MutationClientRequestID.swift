import Foundation

/// Stage 3 `client_request_id` alphabet and length gate.
///
/// Applied before receipt claim. Trimmed UUID / hex / dash / alnum / `_`
/// strings of length 8...128 are accepted; everything else is rejected.
public enum MutationClientRequestID {
    public static let minimumLength = 8
    public static let maximumLength = 128

    private static let allowed = CharacterSet(
        charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
    )

    public static func validate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = trimmed.utf8.count
        guard length >= minimumLength, length <= maximumLength else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return trimmed
    }
}
