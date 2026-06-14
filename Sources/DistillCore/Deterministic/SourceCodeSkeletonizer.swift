import Foundation

/// Deterministic, dependency-free code skeletonizer. This is deliberately not a
/// parser: it preserves signatures and elides bodies only when simple brace or
/// indentation structure is clear. Callers must store the original first and
/// pass its retrieve handle; default routing does not use this path.
public enum SourceCodeSkeletonizer {
    public static func skeletonize(
        _ input: String,
        droppedHandle: String,
        minSavingsRatio: Double = 0.20
    ) -> String? {
        let handle = normalizeRetrieveHandle(droppedHandle)
        guard !handle.isEmpty else { return nil }

        let lines = input.components(separatedBy: "\n")
        guard lines.count >= 4 else { return nil }

        var output: [String] = []
        output.reserveCapacity(lines.count)
        var didElide = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            output.append(line)

            if isBraceFunctionSignature(line), line.contains("{") {
                let startDepth = braceDelta(line)
                if startDepth > 0 {
                    let result = elideBraceBody(
                        lines: lines,
                        startIndex: index + 1,
                        startDepth: startDepth,
                        indent: indentation(line) + "    ",
                        handle: handle
                    )
                    if result.skippedLines > 0 {
                        output.append(elisionLine(indent: indentation(line) + "    ", skippedLines: result.skippedLines, handle: handle))
                        didElide = true
                    }
                    index = result.nextIndex
                    continue
                }
            } else if isPythonFunctionSignature(line) {
                let result = elideIndentedBody(
                    lines: lines,
                    startIndex: index + 1,
                    parentIndent: indentationWidth(line),
                    indent: indentation(line) + "    ",
                    handle: handle
                )
                if result.skippedLines > 0 {
                    output.append(elisionLine(indent: indentation(line) + "    ", skippedLines: result.skippedLines, handle: handle))
                    didElide = true
                }
                index = result.nextIndex
                continue
            }

            index += 1
        }

        guard didElide else { return nil }
        let text = output.joined(separator: "\n")
        guard text.count < input.count else { return nil }
        let savings = 1.0 - (Double(text.count) / Double(input.count))
        return savings >= minSavingsRatio ? text : nil
    }

    private static func elideBraceBody(
        lines: [String],
        startIndex: Int,
        startDepth: Int,
        indent: String,
        handle: String
    ) -> (nextIndex: Int, skippedLines: Int) {
        var depth = startDepth
        var index = startIndex
        var skipped = 0
        while index < lines.count {
            let nextDepth = depth + braceDelta(lines[index])
            if nextDepth <= 0 {
                return (index, skipped)
            }
            skipped += 1
            depth = nextDepth
            index += 1
        }
        return (startIndex, 0)
    }

    private static func elideIndentedBody(
        lines: [String],
        startIndex: Int,
        parentIndent: Int,
        indent: String,
        handle: String
    ) -> (nextIndex: Int, skippedLines: Int) {
        var index = startIndex
        var skipped = 0
        while index < lines.count {
            let line = lines[index]
            if !line.trimmingCharacters(in: .whitespaces).isEmpty,
               indentationWidth(line) <= parentIndent {
                break
            }
            skipped += 1
            index += 1
        }
        return (index, skipped)
    }

    private static func isBraceFunctionSignature(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return false }
        let patterns = [
            "func ",
            "function ",
            "def ",
            "init(",
            "deinit ",
            "public func ",
            "private func ",
            "internal func ",
            "fileprivate func ",
            "open func ",
            "static func ",
            "public static func ",
            "private static func "
        ]
        if patterns.contains(where: { trimmed.hasPrefix($0) }) { return true }
        return trimmed.contains(") =>") || trimmed.contains(") {")
    }

    private static func isPythonFunctionSignature(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return (trimmed.hasPrefix("def ") || trimmed.hasPrefix("async def ")) && trimmed.hasSuffix(":")
    }

    private static func braceDelta(_ line: String) -> Int {
        var delta = 0
        for char in line {
            if char == "{" { delta += 1 }
            if char == "}" { delta -= 1 }
        }
        return delta
    }

    private static func indentation(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private static func indentationWidth(_ line: String) -> Int {
        indentation(line).reduce(0) { width, char in
            width + (char == "\t" ? 4 : 1)
        }
    }

    private static func elisionLine(indent: String, skippedLines: Int, handle: String) -> String {
        "\(indent)… \(skippedLines) code lines elided [[rc:\(handle)]]; retrieve original for body …"
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
