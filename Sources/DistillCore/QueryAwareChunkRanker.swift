import Foundation

public struct QueryAwareChunk: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let contentType: DistillContentType
    public let position: Int

    public init(id: String, text: String, contentType: DistillContentType = .prose, position: Int) {
        self.id = id
        self.text = text
        self.contentType = contentType
        self.position = max(0, position)
    }
}

public struct QueryAwareRankedChunk: Sendable, Equatable {
    public let chunk: QueryAwareChunk
    public let bm25Score: Double
    public let embeddingScore: Double?
    public let finalScore: Double
}

public struct QueryAwareChunkRanker: Sendable, Equatable {
    public typealias EmbeddingScoreFn = @Sendable (_ query: String, _ text: String) -> Double?

    public let hybridAlpha: Double

    public init(hybridAlpha: Double = 0.25) {
        self.hybridAlpha = min(1.0, max(0.0, hybridAlpha))
    }

    public func rank(
        chunks: [QueryAwareChunk],
        query: String,
        toolArguments: String? = nil,
        embeddingScore: EmbeddingScoreFn? = nil
    ) -> [QueryAwareRankedChunk] {
        let mergedQuery = [query, toolArguments]
            .compactMap { value -> String? in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            .joined(separator: " ")
        let queryTerms = Set(tokens(mergedQuery))
        guard !chunks.isEmpty, !queryTerms.isEmpty else { return [] }

        let tokenized = chunks.map { tokens($0.text) }
        let averageLength = max(1.0, Double(tokenized.reduce(0) { $0 + $1.count }) / Double(chunks.count))
        let documentFrequency = queryTerms.reduce(into: [String: Int]()) { frequencies, term in
            frequencies[term] = tokenized.filter { $0.contains(term) }.count
        }

        let rawBM25 = zip(chunks, tokenized).map { chunk, terms in
            bm25(queryTerms: queryTerms, documentTerms: terms, averageLength: averageLength, documentFrequency: documentFrequency, totalDocuments: chunks.count)
        }
        let maxBM25 = max(rawBM25.max() ?? 0, 0.0001)

        return chunks.enumerated().map { index, chunk in
            let normalizedBM25 = rawBM25[index] / maxBM25
            let embedding = embeddingScore?(mergedQuery, chunk.text)
            // I6.1: the encoder may only ADD keeps — its contribution is a NON-NEGATIVE
            // additive boost on top of the deterministic BM25 score, so it can promote a
            // semantically-relevant chunk but can NEVER demote a high-BM25 chunk below its
            // deterministic rank (boost >= 0). hybridAlpha caps the encoder's weight.
            let hybrid = if let embedding {
                normalizedBM25 + max(0.0, embedding) * hybridAlpha
            } else {
                normalizedBM25
            }
            let final = hybrid + contentTypeBoost(chunk.contentType) + positionBoost(chunk.position, count: chunks.count)
            return QueryAwareRankedChunk(
                chunk: chunk,
                bm25Score: normalizedBM25,
                embeddingScore: embedding,
                finalScore: final
            )
        }
        .sorted { lhs, rhs in
            lhs.finalScore != rhs.finalScore ? lhs.finalScore > rhs.finalScore : lhs.chunk.position < rhs.chunk.position
        }
    }

    private func bm25(
        queryTerms: Set<String>,
        documentTerms: [String],
        averageLength: Double,
        documentFrequency: [String: Int],
        totalDocuments: Int
    ) -> Double {
        let k1 = 1.2
        let b = 0.75
        let length = Double(max(1, documentTerms.count))
        var counts: [String: Int] = [:]
        for term in documentTerms { counts[term, default: 0] += 1 }

        return queryTerms.reduce(0.0) { score, term in
            let frequency = Double(counts[term] ?? 0)
            guard frequency > 0 else { return score }
            let df = Double(documentFrequency[term] ?? 0)
            let idf = log(1.0 + (Double(totalDocuments) - df + 0.5) / (df + 0.5))
            let denominator = frequency + k1 * (1.0 - b + b * (length / averageLength))
            return score + idf * ((frequency * (k1 + 1.0)) / denominator)
        }
    }

    private func contentTypeBoost(_ type: DistillContentType) -> Double {
        switch type {
        case .buildOutput:
            return 0.20
        case .searchResults:
            return 0.15
        case .sourceCode, .diff, .stackTrace, .testReport:
            return 0.10
        case .json, .log, .html, .mixed, .prose:
            return 0.0
        }
    }

    private func positionBoost(_ position: Int, count: Int) -> Double {
        if position < 3 { return 0.05 }
        if count > 0, position >= count - 3 { return 0.03 }
        return 0.0
    }

    private func tokens(_ text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .filter { $0.count >= 2 }
            .map(String.init)
    }
}
