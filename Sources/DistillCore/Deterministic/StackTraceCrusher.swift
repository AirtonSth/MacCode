import Foundation

public enum StackTraceCrusher {
    public static func looksLikeStackTrace(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let frameCount = lines.filter(isStackFrame).count
        return frameCount >= 3 && (
            text.contains("Traceback (most recent call last)") ||
            text.contains("Caused by:") ||
            frameCount >= 5
        )
    }

    public static func crush(_ input: String, handle: String?) -> String? {
        guard looksLikeStackTrace(input), let handle, !handle.isEmpty else { return nil }
        let lines = input.components(separatedBy: "\n")
        var out: [String] = []
        var didElide = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if isStackFrame(line) {
                var end = index + 1
                while end < lines.count, lines[end] == line {
                    end += 1
                }
                let count = end - index
                out.append(line)
                if count >= 3 {
                    out.append("... \(count - 1) identical stack frames elided [[rc:\(handle)]] ...")
                    didElide = true
                } else {
                    for duplicateIndex in (index + 1)..<end {
                        out.append(lines[duplicateIndex])
                    }
                }
                index = end
            } else {
                out.append(line)
                index += 1
            }
        }

        guard didElide else { return nil }
        let output = out.joined(separator: "\n")
        return output.count < input.count ? output : nil
    }

    private static func isStackFrame(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("at ") ||
            trimmed.hasPrefix("File \"") ||
            trimmed.range(of: #"^\d+\s+[\w.$<>]+\("#, options: .regularExpression) != nil
    }
}
