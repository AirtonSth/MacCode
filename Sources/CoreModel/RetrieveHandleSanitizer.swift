import Foundation

/// Scoped Distill recovery bearer minted onto the provider wire as `[[rc:rcv1.<8hex>]]`.
/// Lookup is SHA-256 of this string; the object UUID stays in SQLite, not on the wire.
public enum TokenSaverRecoveryCapability: Sendable {
    public static let prefix = "rcv1."
    public static let tokenHexLength = 8

    public static func mint() -> String {
        let uuid = UUID().uuid
        let bytes = [uuid.0, uuid.1, uuid.2, uuid.3]
        var hex = [UInt8]()
        hex.reserveCapacity(tokenHexLength)
        let alphabet = Array("0123456789abcdef".utf8)
        for byte in bytes {
            hex.append(alphabet[Int(byte >> 4)])
            hex.append(alphabet[Int(byte & 0x0f)])
        }
        return prefix + (String(bytes: hex, encoding: .utf8) ?? "00000000")
    }

    public static func isValid(_ capability: String) -> Bool {
        guard capability.utf8.count == prefix.utf8.count + tokenHexLength,
              capability.hasPrefix(prefix) else { return false }
        return capability.utf8.dropFirst(prefix.utf8.count).allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

/// Strips unresolved CCR handle markers from final user-facing text.
public enum RetrieveHandleSanitizer {
    // PERF: compile once — strip/contains run on final assistant text and distill
    // gates; range(of:options:.regularExpression) recompiled every call.
    private static let handleRegex = try! NSRegularExpression(
        pattern: #"\[\[rc:(?:[0-9a-fA-F]+|rcv1\.[0-9a-f]{"#
            + String(TokenSaverRecoveryCapability.tokenHexLength)
            + #"})\]\]"#
    )
    private static let trailingSpacesBeforeNewlineRegex = try! NSRegularExpression(
        pattern: #"[ \t]+\n"#
    )
    private static let multiNewlineCollapseRegex = try! NSRegularExpression(
        pattern: #"\n{3,}"#
    )

    public static func strip(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = handleRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
        return tidyWhitespace(stripped)
    }

    public static func containsHandle(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return handleRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func tidyWhitespace(_ text: String) -> String {
        var result = text
        for (regex, template) in [
            (trailingSpacesBeforeNewlineRegex, "\n"),
            (multiNewlineCollapseRegex, "\n\n")
        ] {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
