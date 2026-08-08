import Foundation

/// Store-backed, dependency-free HTML compressor. It only elides bulky script or
/// style bodies after the caller has stored the original and supplied a retrieve
/// handle; user-visible HTML text and the enclosing tags stay in place.
public enum HTMLStructuralCompressor {
    public static func compress(
        _ input: String,
        droppedHandle: String,
        minSavingsRatio: Double = 0.20,
        minimumBlockCharacters: Int = 160
    ) -> String? {
        let handle = normalizeRetrieveHandle(droppedHandle)
        // PERF: floor + savings used Character.count (O(n)). utf8.count is O(1);
        // matches byte-oriented Token Saver gain gates and marker `bytes=` field.
        let inputBytes = input.utf8.count
        guard !handle.isEmpty, inputBytes >= minimumBlockCharacters else { return nil }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        replacements.append(contentsOf: elisions(in: input, tagName: "script", handle: handle, minimumBlockCharacters: minimumBlockCharacters))
        replacements.append(contentsOf: elisions(in: input, tagName: "style", handle: handle, minimumBlockCharacters: minimumBlockCharacters))
        guard !replacements.isEmpty else { return nil }

        var output = input
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            output.replaceSubrange(replacement.range, with: replacement.text)
        }

        let outputBytes = output.utf8.count
        guard outputBytes < inputBytes else { return nil }
        let savings = 1.0 - (Double(outputBytes) / Double(inputBytes))
        return savings >= minSavingsRatio ? output : nil
    }

    private static func elisions(
        in input: String,
        tagName: String,
        handle: String,
        minimumBlockCharacters: Int
    ) -> [(range: Range<String.Index>, text: String)] {
        let pattern = #"(?is)(<\#(tagName)\b[^>]*>)(.*?)(</\#(tagName)\s*>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.matches(in: input, range: nsRange).compactMap { match in
            guard match.numberOfRanges == 4,
                  let fullRange = Range(match.range(at: 0), in: input),
                  let openRange = Range(match.range(at: 1), in: input),
                  let bodyRange = Range(match.range(at: 2), in: input),
                  let closeRange = Range(match.range(at: 3), in: input) else {
                return nil
            }
            let body = String(input[bodyRange])
            guard body.utf8.count >= minimumBlockCharacters else { return nil }
            let replacement = [
                String(input[openRange]),
                "<!-- html block elided [[rc:\(handle)]] tag=\(tagName) bytes=\(body.utf8.count) -->",
                String(input[closeRange])
            ].joined(separator: "\n")
            return (range: fullRange, text: replacement)
        }
    }

    private static func normalizeRetrieveHandle(_ handle: String) -> String {
        var normalized = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = normalized.range(of: "rc:") {
            normalized = String(normalized[range.upperBound...])
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "[]{}() \t\n"))
        return normalized
    }
}
