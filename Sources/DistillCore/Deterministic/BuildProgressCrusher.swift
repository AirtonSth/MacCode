import Foundation

/// Elides SPM / `swift test` compile-progress chatter (`[N/M] Compiling`,
/// `Building for debugging`, `--prepared:`). Keeps warning/error/note lines and
/// outcome text. Lossy — callers must store-before-loss and pass a handle.
public enum BuildProgressCrusher {
    public static let minProgressLines = 3

    private static let indexedProgressRegex = try! NSRegularExpression(
        pattern: #"^\[\d+/\d+\]\s+(Compiling|Emitting module|Write |Linking |Applying |Copying |Planning )"#
    )
    private static let phaseProgressRegex = try! NSRegularExpression(
        pattern: #"^(Building for debugging|Fetching |Fetched |Computing version|Creating working copy|Working copy of|--prepared:|--validated:)"#
    )

    public static func isProgressLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return indexedProgressRegex.firstMatch(in: trimmed, options: [], range: range) != nil
            || phaseProgressRegex.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    public static func looksLike(_ text: String) -> Bool {
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            if isProgressLine(String(line)) {
                count += 1
                if count >= minProgressLines { return true }
            }
        }
        return false
    }

    public static func crush(_ input: String, handle: String?) -> String? {
        guard let handle, !handle.isEmpty else { return nil }
        let lines = input.components(separatedBy: "\n")
        var progress = 0
        var kept: [String] = []
        kept.reserveCapacity(lines.count)
        for line in lines {
            if isProgressLine(line) {
                progress += 1
                continue
            }
            kept.append(line)
        }
        guard progress >= minProgressLines else { return nil }
        let output = "spm: \(progress) progress lines elided [[rc:\(handle)]]\n" + kept.joined(separator: "\n")
        return output.utf8.count < input.utf8.count ? output : nil
    }
}
