import Foundation

/// Builds a bounded, position-preserving source view for local Librarian generation.
///
/// The packer is deliberately deterministic and extractive. It only renders byte-exact
/// source segments, with small non-evidence headers between them. Callers can therefore
/// validate a generated exact span against both the original source and a displayed
/// verbatim segment instead of accepting a match that appeared only in pack metadata.
public struct LibrarianEvidencePack: Sendable, Equatable {
    public enum Strategy: String, Sendable, Equatable {
        /// The source already fit; no header or marker was added.
        case unchanged
        /// Ranked, verbatim source segments plus non-evidence byte-range headers.
        case rankedEvidence
        /// Mandatory evidence did not fit, so the byte-bounded baseline prefix won.
        case baselinePrefix
    }

    public struct SourceLine: Sendable, Equatable {
        public let number: Int
        public let sourceByteRange: Range<Int>
        public let text: String

        fileprivate init(number: Int, sourceByteRange: Range<Int>, text: String) {
            self.number = number
            self.sourceByteRange = sourceByteRange
            self.text = text
        }
    }

    public struct VerbatimSegment: Sendable, Equatable {
        public let sourceByteRange: Range<Int>
        public let renderedByteRange: Range<Int>
        public let text: String

        fileprivate init(
            sourceByteRange: Range<Int>,
            renderedByteRange: Range<Int>,
            text: String
        ) {
            self.sourceByteRange = sourceByteRange
            self.renderedByteRange = renderedByteRange
            self.text = text
        }
    }

    public struct Result: Sendable, Equatable {
        public let text: String
        public let strategy: Strategy
        public let budgetBytes: Int
        public let sourceByteCount: Int
        /// Number of source bytes shown by the byte-bounded baseline prefix.
        public let prefixCutoffByte: Int
        public let segments: [VerbatimSegment]

        public var renderedByteCount: Int { text.utf8.count }

        /// Bytes used by headers/separators. They are deliberately excluded from every
        /// `VerbatimSegment.renderedByteRange` and can never satisfy evidence validation.
        public var headerByteCount: Int {
            renderedByteCount - segments.reduce(0) { $0 + $1.text.utf8.count }
        }

        public var hasEvidenceBeyondPrefixCutoff: Bool {
            segments.contains { $0.sourceByteRange.upperBound > prefixCutoffByte }
        }

        /// Proves that every declared evidence segment is byte-identical in the original
        /// and rendered pack. This also rejects stale results used with another source.
        public func verbatimSegmentsAreValid(in original: String) -> Bool {
            let originalBytes = Array(original.utf8)
            let renderedBytes = Array(text.utf8)
            guard originalBytes.count == sourceByteCount else { return false }

            var previousSourceEnd = 0
            var previousRenderedEnd = 0
            for segment in segments {
                let sourceRange = segment.sourceByteRange
                let renderedRange = segment.renderedByteRange
                guard !sourceRange.isEmpty,
                      sourceRange.lowerBound >= previousSourceEnd,
                      sourceRange.lowerBound >= 0,
                      sourceRange.upperBound <= originalBytes.count,
                      renderedRange.lowerBound >= previousRenderedEnd,
                      renderedRange.lowerBound >= 0,
                      renderedRange.upperBound <= renderedBytes.count else {
                    return false
                }
                let segmentBytes = Array(segment.text.utf8)
                guard originalBytes[sourceRange].elementsEqual(segmentBytes),
                      renderedBytes[renderedRange].elementsEqual(segmentBytes) else {
                    return false
                }
                previousSourceEnd = sourceRange.upperBound
                previousRenderedEnd = renderedRange.upperBound
            }
            return true
        }

        /// Validates one exact, non-empty source byte range as fully contained in a shown
        /// verbatim segment. `exact` must match those original bytes when supplied.
        public func containsVerbatimSpan(
            sourceByteRange: Range<Int>,
            exact: String? = nil,
            in original: String
        ) -> Bool {
            guard !sourceByteRange.isEmpty,
                  verbatimSegmentsAreValid(in: original),
                  segments.contains(where: {
                      $0.sourceByteRange.lowerBound <= sourceByteRange.lowerBound
                          && sourceByteRange.upperBound <= $0.sourceByteRange.upperBound
                  }) else {
                return false
            }
            guard let exact else { return true }
            let originalBytes = Array(original.utf8)
            return originalBytes[sourceByteRange].elementsEqual(exact.utf8)
        }

        /// Finds every byte-exact occurrence in the original and succeeds only when at
        /// least one occurrence is entirely inside a displayed verbatim segment. A copy
        /// of the same text in a range header is intentionally irrelevant.
        public func containsExactSpan(_ exact: String, in original: String) -> Bool {
            let needle = Array(exact.utf8)
            let haystack = Array(original.utf8)
            guard !needle.isEmpty, needle.count <= haystack.count,
                  verbatimSegmentsAreValid(in: original) else {
                return false
            }

            for start in 0...(haystack.count - needle.count) {
                let range = start..<(start + needle.count)
                if haystack[range].elementsEqual(needle),
                   containsVerbatimSpan(sourceByteRange: range, exact: exact, in: original) {
                    return true
                }
            }
            return false
        }
    }

    public let budgetBytes: Int

    public init(budgetBytes: Int = 6_000) {
        self.budgetBytes = max(0, budgetBytes)
    }

    /// Splits on LF bytes while retaining every newline byte (including the CR in CRLF)
    /// and reporting source offsets in UTF-8 bytes. Rejoining `text` is byte-identical.
    public static func sourceLines(in source: String) -> [SourceLine] {
        let bytes = Array(source.utf8)
        guard !bytes.isEmpty else { return [] }

        var lines: [SourceLine] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 0x0A {
            let end = index + 1
            let range = start..<end
            lines.append(SourceLine(
                number: lines.count + 1,
                sourceByteRange: range,
                text: String(decoding: bytes[range], as: UTF8.self)
            ))
            start = end
        }
        if start < bytes.count {
            let range = start..<bytes.count
            lines.append(SourceLine(
                number: lines.count + 1,
                sourceByteRange: range,
                text: String(decoding: bytes[range], as: UTF8.self)
            ))
        }
        return lines
    }

    public func pack(source: String, question: String) -> Result {
        let sourceBytes = Array(source.utf8)
        let prefix = Self.validUTF8Prefix(of: sourceBytes, maximumBytes: budgetBytes)
        let prefixCutoff = prefix.utf8.count

        guard sourceBytes.count > budgetBytes else {
            return Result(
                text: source,
                strategy: .unchanged,
                budgetBytes: budgetBytes,
                sourceByteCount: sourceBytes.count,
                prefixCutoffByte: sourceBytes.count,
                segments: source.isEmpty ? [] : [VerbatimSegment(
                    sourceByteRange: 0..<sourceBytes.count,
                    renderedByteRange: 0..<sourceBytes.count,
                    text: source
                )]
            )
        }

        let lines = Self.sourceLines(in: source)
        guard !lines.isEmpty else {
            return Self.prefixResult(
                prefix,
                budgetBytes: budgetBytes,
                sourceByteCount: sourceBytes.count
            )
        }

        let queryTerms = Set(Self.tokens(question))
        var mandatory = Set<Int>()

        // The head and tail are required anchors. A one-line context radius yields a
        // target bundle of previous/current/next without inventing text.
        Self.insertBundle(around: 0, lineCount: lines.count, into: &mandatory)
        Self.insertBundle(around: lines.count - 1, lineCount: lines.count, into: &mandatory)

        for (index, line) in lines.enumerated() {
            if DistillImportanceScorer.isFloorLine(line.text) {
                Self.insertBundle(around: index, lineCount: lines.count, into: &mandatory)
            }
        }

        guard Self.renderedByteCount(
            lineIndices: mandatory,
            lines: lines
        ) <= budgetBytes else {
            return Self.prefixResult(
                prefix,
                budgetBytes: budgetBytes,
                sourceByteCount: sourceBytes.count
            )
        }

        var selected = mandatory
        if !queryTerms.isEmpty {
            let contentType = DistillContentRouter().classify(source)
            let chunks = lines.enumerated().map { index, line in
                QueryAwareChunk(
                    id: String(line.number),
                    text: line.text,
                    contentType: contentType,
                    position: index
                )
            }
            // No embedding callback: deterministic BM25 and existing type/position boosts
            // are the only ranking signals in this hot path.
            let ranked = QueryAwareChunkRanker().rank(chunks: chunks, query: question)
            let literalMatches = Set(lines.enumerated().compactMap { index, line in
                queryTerms.isDisjoint(with: Set(Self.tokens(line.text))) ? nil : index
            })
            for candidate in ranked {
                guard let target = Int(candidate.chunk.id).map({ $0 - 1 }),
                      lines.indices.contains(target),
                      literalMatches.contains(target) else {
                    continue
                }
                // Literal query hits are required evidence, but their BM25 order is the
                // deterministic candidate order. If the complete required set cannot fit,
                // fail back to the baseline prefix instead of silently dropping a hit.
                Self.insertBundle(around: target, lineCount: lines.count, into: &selected)
            }
            guard Self.renderedByteCount(lineIndices: selected, lines: lines) <= budgetBytes else {
                return Self.prefixResult(
                    prefix,
                    budgetBytes: budgetBytes,
                    sourceByteCount: sourceBytes.count
                )
            }
        }

        let rendered = Self.render(
            sourceBytes: sourceBytes,
            lineIndices: selected,
            lines: lines
        )
        let choseUsefulPack = rendered.text.utf8.count <= budgetBytes
            && rendered.text.utf8.count < sourceBytes.count
            && rendered.segments.contains { $0.sourceByteRange.upperBound > prefixCutoff }

        guard choseUsefulPack else {
            return Self.prefixResult(
                prefix,
                budgetBytes: budgetBytes,
                sourceByteCount: sourceBytes.count
            )
        }
        return Result(
            text: rendered.text,
            strategy: .rankedEvidence,
            budgetBytes: budgetBytes,
            sourceByteCount: sourceBytes.count,
            prefixCutoffByte: prefixCutoff,
            segments: rendered.segments
        )
    }

    private static func insertBundle(
        around target: Int,
        lineCount: Int,
        into selected: inout Set<Int>
    ) {
        guard lineCount > 0 else { return }
        let lower = max(0, target - 1)
        let upper = min(lineCount - 1, target + 1)
        selected.formUnion(lower...upper)
    }

    private static func tokens(_ text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .filter { $0.count >= 2 }
            .map(String.init)
    }

    private static func sourceRanges(
        lineIndices: Set<Int>,
        lines: [SourceLine]
    ) -> [Range<Int>] {
        let sorted = lineIndices.filter(lines.indices.contains).sorted()
        guard let first = sorted.first else { return [] }

        var ranges: [Range<Int>] = []
        var current = lines[first].sourceByteRange
        for index in sorted.dropFirst() {
            let next = lines[index].sourceByteRange
            if current.upperBound == next.lowerBound {
                current = current.lowerBound..<next.upperBound
            } else {
                ranges.append(current)
                current = next
            }
        }
        ranges.append(current)
        return ranges
    }

    private static func header(for range: Range<Int>) -> String {
        "[bytes:\(range.lowerBound)-\(range.upperBound)]\n"
    }

    private static func renderedByteCount(
        lineIndices: Set<Int>,
        lines: [SourceLine]
    ) -> Int {
        sourceRanges(lineIndices: lineIndices, lines: lines).reduce(0) { total, range in
            total + header(for: range).utf8.count + range.count
        }
    }

    private static func render(
        sourceBytes: [UInt8],
        lineIndices: Set<Int>,
        lines: [SourceLine]
    ) -> (text: String, segments: [VerbatimSegment]) {
        var text = ""
        var renderedByteOffset = 0
        var segments: [VerbatimSegment] = []

        for range in sourceRanges(lineIndices: lineIndices, lines: lines) {
            let header = header(for: range)
            text += header
            renderedByteOffset += header.utf8.count

            let verbatim = String(decoding: sourceBytes[range], as: UTF8.self)
            let renderedRange = renderedByteOffset..<(renderedByteOffset + range.count)
            text += verbatim
            renderedByteOffset = renderedRange.upperBound
            segments.append(VerbatimSegment(
                sourceByteRange: range,
                renderedByteRange: renderedRange,
                text: verbatim
            ))
        }
        return (text, segments)
    }

    private static func validUTF8Prefix(
        of bytes: [UInt8],
        maximumBytes: Int
    ) -> String {
        var count = min(max(0, maximumBytes), bytes.count)
        while count > 0 {
            if let prefix = String(bytes: bytes[..<count], encoding: .utf8) {
                return prefix
            }
            count -= 1
        }
        return ""
    }

    private static func prefixResult(
        _ prefix: String,
        budgetBytes: Int,
        sourceByteCount: Int
    ) -> Result {
        let bytes = prefix.utf8.count
        return Result(
            text: prefix,
            strategy: .baselinePrefix,
            budgetBytes: budgetBytes,
            sourceByteCount: sourceByteCount,
            prefixCutoffByte: bytes,
            segments: prefix.isEmpty ? [] : [VerbatimSegment(
                sourceByteRange: 0..<bytes,
                renderedByteRange: 0..<bytes,
                text: prefix
            )]
        )
    }
}
