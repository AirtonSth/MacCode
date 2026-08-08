import Foundation

public enum ProsePruningLane {
    public static func prune(
        _ input: String,
        handle: String?,
        maxKeepLines: Int = 12,
        question: String? = nil,
        ranker: QueryAwareChunkRanker = QueryAwareChunkRanker()
    ) -> String? {
        // PERF: size floor via O(1) utf8.count (not Character.count grapheme walk).
        guard let handle, !handle.isEmpty,
              input.utf8.count >= 2_000,
              !rejectsAsCodeOrStructured(input) else {
            return nil
        }

        let lines = input.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count > maxKeepLines + 4 else { return nil }

        var keep = requiredKeeps(lines)
        guard keep.count <= maxKeepLines else { return nil }

        if let question = question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            let chunks = lines.enumerated().map { index, line in
                QueryAwareChunk(id: String(index), text: line, contentType: .prose, position: index)
            }
            for ranked in ranker.rank(chunks: chunks, query: question).prefix(max(1, maxKeepLines - keep.count)) {
                guard let index = Int(ranked.chunk.id) else { continue }
                keep.insert(index)
                if keep.count >= maxKeepLines { break }
            }
        }

        if keep.count < maxKeepLines {
            for index in lines.indices where keep.count < maxKeepLines {
                if index < 3 || index >= lines.count - 3 {
                    keep.insert(index)
                }
            }
        }
        guard keep.count < lines.count else { return nil }

        var out: [String] = []
        var omitted = 0
        for index in lines.indices {
            if keep.contains(index) {
                if omitted > 0 {
                    out.append(elisionMarker(omitted: omitted, handle: handle))
                    omitted = 0
                }
                out.append(lines[index])
            } else {
                omitted += 1
            }
        }
        if omitted > 0 {
            out.append(elisionMarker(omitted: omitted, handle: handle))
        }

        let output = out.joined(separator: "\n")
        // PERF: never-inflate via O(1) utf8.count (not Character.count grapheme walk).
        guard output.utf8.count < input.utf8.count,
              LiteralPreservation.guarded(original: input, compressed: output).droppedLiteral == nil,
              FaithfulnessGate.validate(original: input, compressed: output).accepted else {
            return nil
        }
        return output
    }

    private static func requiredKeeps(_ lines: [String]) -> Set<Int> {
        var keep = Set<Int>()
        for index in lines.indices {
            if index < 3 || index >= lines.count - 3 || isSalient(lines[index]) {
                keep.insert(index)
            }
        }
        return keep
    }

    private static func elisionMarker(omitted: Int, handle: String) -> String {
        "... \(omitted) prose lines elided [[rc:\(handle)]]; retrieve before negative claims ..."
    }

    private static func rejectsAsCodeOrStructured(_ input: String) -> Bool {
        if input.contains("```") ||
            JSONCrusher.looksLikeJSON(input) ||
            DiffCrusher.looksLikeDiff(input) ||
            StackTraceCrusher.looksLikeStackTrace(input) {
            return true
        }
        let lines = input.split(whereSeparator: \.isNewline).map(String.init)
        let codeLike = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("func ") ||
                trimmed.hasPrefix("class ") ||
                trimmed.hasPrefix("struct ") ||
                trimmed.hasPrefix("import ") ||
                trimmed.contains("{") && trimmed.contains("}") ||
                trimmed.range(of: #"^\s{4,}\S"#, options: .regularExpression) != nil
        }
        return !lines.isEmpty && Double(codeLike.count) / Double(lines.count) > 0.25
    }

    private static func isSalient(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.range(of: #"\b(error|fatal|warn|warning|fail|panic|exception|traceback|must|never|only|not)\b"#, options: .regularExpression) != nil {
            return true
        }
        if line.range(of: #"[\w./~-]+\.[A-Za-z0-9]+:\d+"#, options: .regularExpression) != nil {
            return true
        }
        if line.contains("[[rc:") || line.contains("`") {
            return true
        }
        return false
    }
}
