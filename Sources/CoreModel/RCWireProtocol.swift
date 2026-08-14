import Foundation

public enum RCWireDirection: String, Codable, Sendable, Equatable {
    case request = "Q"
    case response = "A"
}

public enum RCWireRecordKind: String, Codable, Sendable, Equatable {
    case goal = "G"
    case context = "C"
    case constraint = "K"
    case exact = "X"
    case outcome = "O"
    case action = "A"
    case evidence = "E"
    case risk = "R"
    case question = "Q"

    fileprivate func isAllowed(in direction: RCWireDirection) -> Bool {
        switch direction {
        case .request:
            return self == .goal || self == .context || self == .constraint || self == .exact
        case .response:
            return self == .outcome || self == .action || self == .evidence
                || self == .risk || self == .question || self == .exact
        }
    }
}

public struct RCWireRecord: Codable, Sendable, Equatable {
    public let kind: RCWireRecordKind
    public let value: String

    public init(kind: RCWireRecordKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct RCWireFrame: Codable, Sendable, Equatable {
    public let direction: RCWireDirection
    public let sequence: Int
    public let records: [RCWireRecord]

    public init(direction: RCWireDirection, sequence: Int, records: [RCWireRecord]) {
        self.direction = direction
        self.sequence = sequence
        self.records = records
    }
}

public enum RCWirePrefixDisposition: Sendable, Equatable {
    case undecided
    case wire
    case plainText
}

public enum RCWireProtocolError: Error, Sendable, Equatable {
    case empty
    case unsupportedVersion
    case malformedHeader
    case invalidSequence
    case invalidRecord
    case recordNotAllowed
    case missingTerminator
    case oversizedFrame
    case outOfOrder
}

/// Compact, provider-neutral Token Saver transport ABI.
///
/// Swift owns framing and escaping. Local models may supply record values, but
/// cannot redefine tags or delimiters. Every valid response frame remains
/// readable through `renderEnglish` when the local model is unavailable.
public enum RCWireProtocol {
    public static let version = "RCW1"
    public static let maximumFrameBytes = 8 * 1_024
    private static let maximumRecordsPerFrame = 64
    private static let protectedSemanticRegexes: [NSRegularExpression] = [
        #"```[\s\S]*?```"#,
        #"`[^`\n]+`"#,
        #"\"[^\"\n]+\"|'[^'\n]+'"#,
        #"https?://[^\s<>]+"#,
        #"\b\d+(?:\.\d+)?(?:\s?(?:ns|us|ms|s|min|h|B|KB|MB|GB|TB|KiB|MiB|GiB|%|px|pt|Hz|kHz|MHz|GHz))?\b"#,
        #"\b(?:do\s+not|does\s+not|did\s+not|not|never|without|unless|except|only|must\s+not|cannot|can't|don't|won't)\b"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    public static func prefixDisposition(_ text: String) -> RCWirePrefixDisposition {
        guard !text.isEmpty else { return .undecided }
        if version.hasPrefix(text) { return .undecided }
        if text.hasPrefix(version + "\t") { return .wire }
        if text.hasPrefix("RCW") { return .wire }
        return .plainText
    }

    public static func isWire(_ text: String) -> Bool {
        prefixDisposition(text.trimmingCharacters(in: .whitespacesAndNewlines)) == .wire
    }

    /// Locates a transport frame at a line boundary even when a provider
    /// violates the ABI by writing a prose preamble first. The parser remains
    /// strict; this helper only prevents raw transport text from leaking into
    /// the human transcript before that strict parse runs.
    public static func transportEnvelope(in text: String) -> (prefix: String, payload: String)? {
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            if looksLikeTransportHeader(line) {
                let prefix = String(text[..<lineStart]).trimmingCharacters(in: .whitespacesAndNewlines)
                let payload = String(text[lineStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (prefix, payload)
            }
            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }
        return nil
    }

    /// True while a line-boundary sentinel is complete or still arriving in
    /// split streaming deltas.
    public static func containsTransportCandidate(_ text: String) -> Bool {
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            if looksLikeTransportHeader(line)
                || (!line.isEmpty && version.hasPrefix(String(line))) {
                return true
            }
            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }
        return false
    }

    private static func looksLikeTransportHeader(_ line: Substring) -> Bool {
        guard let tab = line.firstIndex(of: "\t") else { return false }
        let token = line[..<tab]
        guard token.hasPrefix("RCW") else { return false }
        let digits = token.dropFirst(3)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// Per-turn Swift gate for intent-critical atoms that a semantic encoder can
    /// otherwise omit while still producing syntactically valid frames.
    public static func preservesProtectedSemantics(original: String, wire: String) -> Bool {
        guard let frames = try? parse(wire) else { return false }
        let values = frames.flatMap(\.records).map(\.value).joined(separator: "\n")
        return protectedSemanticSpans(in: original).allSatisfy { values.contains($0) }
    }

    public static func renderedTextPreservesProtectedSemantics(
        _ rendered: String,
        frames: [RCWireFrame]
    ) -> Bool {
        let source = frames.flatMap(\.records).map(\.value).joined(separator: "\n")
        return protectedSemanticSpans(in: source).allSatisfy { rendered.contains($0) }
    }

    public static func requiresDeterministicRendering(_ frames: [RCWireFrame]) -> Bool {
        let lower = " " + frames.flatMap(\.records).map(\.value).joined(separator: " ").lowercased() + " "
        return [
            " approval ", " approve ", " permission ", " security ", " data loss ",
            " irreversible ", " delete ", " remove production ", " password ",
            " secret ", " rm -rf ", " sudo "
        ].contains { lower.contains($0) }
    }

    public static func serialize(_ frame: RCWireFrame) throws -> String {
        try validate(frame)
        var lines = ["\(version)\t\(frame.direction.rawValue)\t\(frame.sequence)"]
        lines.append(contentsOf: frame.records.map { "\($0.kind.rawValue)\t\(escape($0.value))" })
        lines.append(".")
        let output = lines.joined(separator: "\n") + "\n"
        guard output.utf8.count <= maximumFrameBytes else {
            throw RCWireProtocolError.oversizedFrame
        }
        return output
    }

    /// Losslessly frames an arbitrarily long user prompt into independently
    /// bounded RCW1 request frames. The provider reads the ordered goal records
    /// as one turn; Swift never truncates input to satisfy the per-frame bound.
    public static func serializeRequestText(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RCWireProtocolError.empty
        }
        let payloadBudget = maximumFrameBytes - 128
        var chunks: [String] = []
        var current = ""
        var currentEscapedBytes = 0

        for scalar in text.unicodeScalars {
            let scalarText = String(scalar)
            let escapedBytes = scalarText.utf8.reduce(into: 0) { count, byte in
                count += byte == 0x5C || byte == 0x09 || byte == 0x0A || byte == 0x0D ? 2 : 1
            }
            if !current.isEmpty, currentEscapedBytes + escapedBytes > payloadBudget {
                chunks.append(current)
                current = ""
                currentEscapedBytes = 0
            }
            current.append(contentsOf: scalarText)
            currentEscapedBytes += escapedBytes
        }
        if !current.isEmpty { chunks.append(current) }

        return try chunks.enumerated().map { offset, chunk in
            try serialize(.init(
                direction: .request,
                sequence: offset + 1,
                records: [.init(kind: .goal, value: chunk)]
            ))
        }.joined()
    }

    /// Attaches a recoverable exact-span handle without leaving the RCW1
    /// grammar.
    public static func addingExactRecord(_ value: String, to request: String) throws -> String {
        try addingRequestRecords([RCWireRecord(kind: .exact, value: value)], to: request)
    }

    /// Adds host-owned request context without asking the local model to copy or
    /// reinterpret it. This keeps routing constraints exact while Swift remains
    /// the sole owner of RCW1 framing.
    public static func addingRequestRecords(
        _ records: [RCWireRecord],
        to request: String
    ) throws -> String {
        var frames = try parse(request)
        guard let frame = frames.last,
              frames.allSatisfy({ $0.direction == .request }) else {
            throw RCWireProtocolError.invalidRecord
        }
        let appended = RCWireFrame(
            direction: frame.direction,
            sequence: frame.sequence,
            records: frame.records + records
        )
        if let serialized = try? serialize(appended) {
            frames[frames.count - 1] = appended
            return try frames.dropLast().map(serialize).joined() + serialized
        }
        let trailing = RCWireFrame(
            direction: .request,
            sequence: frame.sequence + 1,
            records: records
        )
        return try frames.map(serialize).joined() + serialize(trailing)
    }

    public static func parse(_ text: String) throws -> [RCWireFrame] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RCWireProtocolError.empty
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var frames: [RCWireFrame] = []
        var index = 0

        while index < lines.count {
            if lines[index].isEmpty {
                index += 1
                continue
            }
            let header = lines[index].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard header.first == version else {
                if header.first?.hasPrefix("RCW") == true {
                    throw RCWireProtocolError.unsupportedVersion
                }
                throw RCWireProtocolError.malformedHeader
            }
            guard header.count == 3, let direction = RCWireDirection(rawValue: header[1]) else {
                throw RCWireProtocolError.malformedHeader
            }
            guard let sequence = Int(header[2]), sequence > 0 else {
                throw RCWireProtocolError.invalidSequence
            }
            index += 1
            var records: [RCWireRecord] = []
            var sawTerminator = false
            while index < lines.count {
                let line = lines[index]
                index += 1
                if line == "." {
                    sawTerminator = true
                    break
                }
                if direction == .response, !line.isEmpty, !line.contains("\t") {
                    records.append(.init(kind: .exact, value: line))
                    guard records.count <= maximumRecordsPerFrame else {
                        throw RCWireProtocolError.oversizedFrame
                    }
                    continue
                }
                guard !line.isEmpty,
                      let delimiter = line.firstIndex(of: "\t"),
                      delimiter != line.startIndex,
                      let kind = RCWireRecordKind(rawValue: String(line[..<delimiter])) else {
                    throw RCWireProtocolError.invalidRecord
                }
                guard kind.isAllowed(in: direction) else {
                    throw RCWireProtocolError.recordNotAllowed
                }
                let escaped = String(line[line.index(after: delimiter)...])
                let value = try unescape(escaped)
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RCWireProtocolError.invalidRecord
                }
                records.append(.init(kind: kind, value: value))
                guard records.count <= maximumRecordsPerFrame else {
                    throw RCWireProtocolError.oversizedFrame
                }
            }
            guard sawTerminator else { throw RCWireProtocolError.missingTerminator }
            let frame = RCWireFrame(direction: direction, sequence: sequence, records: records)
            try validate(frame)
            if let prior = frames.last, sequence <= prior.sequence {
                throw RCWireProtocolError.outOfOrder
            }
            let start = lines[max(0, index - records.count - 2)...min(index - 1, lines.count - 1)]
                .joined(separator: "\n")
            guard start.utf8.count <= maximumFrameBytes else {
                throw RCWireProtocolError.oversizedFrame
            }
            frames.append(frame)
        }
        guard !frames.isEmpty else { throw RCWireProtocolError.empty }
        return frames
    }

    public static func renderEnglish(_ frames: [RCWireFrame]) -> String {
        var paragraphs: [String] = []
        for frame in frames where frame.direction == .response {
            for record in frame.records {
                let value = record.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                switch record.kind {
                case .outcome, .exact:
                    paragraphs.append(value)
                case .action:
                    paragraphs.append("Action: \(value)")
                case .evidence:
                    paragraphs.append("Evidence: \(value)")
                case .risk:
                    paragraphs.append("Risk: \(value)")
                case .question:
                    paragraphs.append("Question: \(value)")
                case .goal, .context, .constraint:
                    break
                }
            }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func validate(_ frame: RCWireFrame) throws {
        guard frame.sequence > 0 else { throw RCWireProtocolError.invalidSequence }
        guard !frame.records.isEmpty, frame.records.count <= maximumRecordsPerFrame else {
            throw RCWireProtocolError.invalidRecord
        }
        guard frame.records.allSatisfy({ $0.kind.isAllowed(in: frame.direction) }) else {
            throw RCWireProtocolError.recordNotAllowed
        }
        guard frame.records.allSatisfy({ !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw RCWireProtocolError.invalidRecord
        }
    }

    private static func protectedSemanticSpans(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var spans = Set<String>()
        for regex in protectedSemanticRegexes {
            for match in regex.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                spans.insert(String(text[matchRange]))
            }
        }
        return spans
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func unescape(_ value: String) throws -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            guard character == "\\" else {
                result.append(character)
                index = value.index(after: index)
                continue
            }
            let next = value.index(after: index)
            guard next < value.endIndex else { throw RCWireProtocolError.invalidRecord }
            switch value[next] {
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "n": result.append("\n")
            default: throw RCWireProtocolError.invalidRecord
            }
            index = value.index(after: next)
        }
        return result
    }
}
