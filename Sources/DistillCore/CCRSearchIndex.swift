import Foundation

public struct CCRSearchRecord: Sendable, Equatable {
    public let handle: String
    public let text: String

    public init(handle: String, text: String) {
        self.handle = handle
        self.text = text
    }
}

public struct CCRSearchResult: Codable, Sendable, Equatable {
    public let handle: String
    public let score: Double
    public let excerpt: String
}

public struct CCRSearchIndex: Sendable, Equatable {
    private var records: [CCRSearchRecord]

    public init(records: [CCRSearchRecord] = []) {
        self.records = records
    }

    public mutating func add(handle: String, text: String) {
        records.append(CCRSearchRecord(handle: handle, text: text))
    }

    public func search(_ query: String, topK: Int = 5) -> [CCRSearchResult] {
        let queryTerms = tokens(query)
        guard !queryTerms.isEmpty else { return [] }
        return records.compactMap { record -> CCRSearchResult? in
            let recordTerms = tokens(record.text)
            let overlap = queryTerms.intersection(recordTerms)
            guard !overlap.isEmpty else { return nil }
            let union = queryTerms.union(recordTerms)
            let score = Double(overlap.count) / Double(max(1, union.count))
            return CCRSearchResult(
                handle: record.handle,
                score: score,
                excerpt: excerpt(for: record.text, queryTerms: queryTerms)
            )
        }
        .sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.handle < rhs.handle
        }
        .prefix(max(1, topK))
        .map { $0 }
    }

    public func nominateNearDuplicate(_ text: String, minimumJaccard: Double = 0.90) -> CCRSearchResult? {
        let textTerms = tokens(text)
        guard !textTerms.isEmpty else { return nil }
        return records.compactMap { record -> CCRSearchResult? in
            let recordTerms = tokens(record.text)
            let union = textTerms.union(recordTerms)
            guard !union.isEmpty else { return nil }
            let score = Double(textTerms.intersection(recordTerms).count) / Double(union.count)
            guard score >= minimumJaccard else { return nil }
            return CCRSearchResult(handle: record.handle, score: score, excerpt: excerpt(for: record.text, queryTerms: textTerms))
        }
        .sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.handle < rhs.handle
        }
        .first
    }

    private func excerpt(for text: String, queryTerms: Set<String>) -> String {
        let lines = text.components(separatedBy: "\n")
        let salient = lines.first { line in
            let lower = line.lowercased()
            return lower.contains("error") ||
                lower.contains("fail") ||
                !queryTerms.intersection(tokens(line)).isEmpty
        } ?? lines.first ?? ""
        let lineCount = lines.count
        let byteCount = text.utf8.count
        return "\(String(salient.prefix(240))) [\(byteCount) bytes, \(lineCount) lines]"
    }

    private func tokens(_ text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
                .filter { $0.count >= 2 }
                .map(String.init)
        )
    }
}
