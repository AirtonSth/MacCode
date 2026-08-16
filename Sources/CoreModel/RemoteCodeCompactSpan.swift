import Foundation

/// RemoteCode Compact Span v1 (`RCS1`) request codec.
///
/// The encoder chooses at most one exact non-overlapping repeated span and
/// emits a deterministic wire. The decoder validates the complete item, then
/// requires `encode(decode(item)) == item` before returning any source bytes.
public enum RemoteCodeCompactSpan {
    public static let maxDecodedBytes = 65_536
    public static let maxWireBytes = 65_536
    public static let encoderMaxSourceBytes = 65_536
    public static let minSpanBytes = 8
    public static let maxSpanBytes = 256
    public static let maxRecords = 4_096
    public static let maxRefs = 4_096
    public static let maxDecodedToWireRatio = 16

    public static func encode(_ source: String) -> String? {
        encodeCanonicalChoice(source)
    }

    public static func encodeCanonicalChoice(_ source: String) -> String? {
        guard !source.isEmpty else { return nil }
        let bytes = Array(source.utf8)
        guard bytes.count <= encoderMaxSourceBytes else { return nil }
        guard !containsUnsupportedControl(bytes) else { return nil }
        return bestItem(in: bytes)
    }

    public static func decode(_ item: String) -> String? {
        decode(bytes: Array(item.utf8))
    }

    public static func decode(bytes: [UInt8]) -> String? {
        guard let parsed = parseCompleteItem(bytes) else { return nil }
        guard encodeCanonicalChoice(parsed.source) == parsed.item else { return nil }
        return parsed.source
    }

    // MARK: - Encoder

    private static func bestItem(in bytes: [UInt8]) -> String? {
        let n = bytes.count
        let maxLength = min(maxSpanBytes, n / 2)
        guard maxLength >= minSpanBytes else { return nil }

        var best: Candidate?
        let radix: UInt64 = 131
        for length in minSpanBytes...maxLength {
            var firstIndex: [UInt64: Int] = [:]
            var counts: [UInt64: Int] = [:]
            var hash: UInt64 = 0
            var power: UInt64 = 1
            for _ in 1..<length {
                power &*= radix
            }
            for index in 0..<length {
                hash = hash &* radix &+ UInt64(bytes[index])
            }
            func visit(start: Int, windowHash: UInt64) {
                guard isScalarStart(bytes, start), isScalarStart(bytes, start + length) else { return }
                if firstIndex[windowHash] == nil {
                    firstIndex[windowHash] = start
                }
                counts[windowHash, default: 0] += 1
            }
            visit(start: 0, windowHash: hash)
            if n > length {
                for start in 1...(n - length) {
                    hash = hash &- UInt64(bytes[start - 1]) &* power
                    hash = hash &* radix &+ UInt64(bytes[start + length - 1])
                    visit(start: start, windowHash: hash)
                }
            }

            var chosenHash: UInt64?
            var chosenFirst = Int.max
            var chosenCount = 1
            var chosenSpan: [UInt8] = []
            for (windowHash, count) in counts where count >= 2 {
                guard let first = firstIndex[windowHash] else { continue }
                let span = Array(bytes[first..<(first + length)])
                if count > chosenCount
                    || (count == chosenCount && first < chosenFirst)
                    || (count == chosenCount && first == chosenFirst && span.lexicographicallyPrecedes(chosenSpan)) {
                    chosenHash = windowHash
                    chosenFirst = first
                    chosenCount = count
                    chosenSpan = span
                }
            }
            guard chosenHash != nil, !chosenSpan.isEmpty else { continue }
            guard let item = encode(bytes: bytes, span: chosenSpan) else { continue }
            let next = Candidate(item: item, span: chosenSpan, first: chosenFirst)
            if next.isBetter(than: best) {
                best = next
            }
        }
        return best?.item
    }

    private static func encode(bytes: [UInt8], span: [UInt8]) -> String? {
        guard span.count >= minSpanBytes, span.count <= maxSpanBytes else { return nil }
        guard let parts = replace(bytes, with: span), parts.count >= 2 else { return nil }
        let refs = parts.reduce(into: 0) { count, part in
            if case .ref = part { count += 1 }
        }
        guard refs >= 2, refs <= maxRefs, parts.count <= maxRecords else { return nil }
        var previousLiteral = false
        for part in parts {
            switch part {
            case .ref:
                previousLiteral = false
            case .literal(let literal):
                if previousLiteral || literal.isEmpty { return nil }
                previousLiteral = true
            }
        }

        var wire = [UInt8]()
        wire.append(contentsOf: Array("RCS1/1\n".utf8))
        wire.append(contentsOf: Array(
            "H\t\(bytes.count)\t\(span.count)\t\(parts.count)\t\(refs)\n".utf8
        ))
        wire.append(contentsOf: [UInt8(ascii: "D"), UInt8(ascii: "\t")])
        wire.append(contentsOf: escape(span))
        wire.append(UInt8(ascii: "\n"))
        for part in parts {
            switch part {
            case .ref:
                wire.append(contentsOf: [UInt8(ascii: "R"), UInt8(ascii: "\n")])
            case .literal(let literal):
                wire.append(contentsOf: [UInt8(ascii: "L"), UInt8(ascii: "\t")])
                wire.append(contentsOf: escape(literal))
                wire.append(UInt8(ascii: "\n"))
            }
        }
        wire.append(contentsOf: Array("END".utf8))
        guard wire.count <= maxWireBytes, wire.count < bytes.count else { return nil }
        guard bytes.count <= wire.count * maxDecodedToWireRatio else { return nil }
        return String(bytes: wire, encoding: .utf8)
    }

    private static func replace(_ bytes: [UInt8], with span: [UInt8]) -> [Part]? {
        var parts: [Part] = []
        var index = 0
        while index < bytes.count {
            if matches(bytes, span: span, at: index) {
                parts.append(.ref)
                index += span.count
            } else {
                let start = index
                index += 1
                while index < bytes.count && !matches(bytes, span: span, at: index) {
                    index += 1
                }
                let literal = Array(bytes[start..<index])
                guard !literal.isEmpty else { return nil }
                parts.append(.literal(literal))
            }
        }
        return parts
    }

    private static func matches(_ bytes: [UInt8], span: [UInt8], at index: Int) -> Bool {
        let end = index + span.count
        guard end <= bytes.count,
              isScalarStart(bytes, index),
              isScalarStart(bytes, end) else {
            return false
        }
        return bytes[index..<end].elementsEqual(span)
    }

    // MARK: - Decoder

    private struct ParsedItem {
        let source: String
        let item: String
    }

    private static func parseCompleteItem(_ bytes: [UInt8]) -> ParsedItem? {
        guard !bytes.isEmpty, bytes.count <= maxWireBytes else { return nil }
        guard String(bytes: bytes, encoding: .utf8) != nil else { return nil }
        var cursor = 0
        guard consume("RCS1/1\n", in: bytes, cursor: &cursor) else { return nil }
        guard let headerLine = readLine(in: bytes, cursor: &cursor) else { return nil }
        guard let header = parseHeader(headerLine) else { return nil }
        guard header.decodedLen <= maxDecodedBytes,
              header.dictLen >= minSpanBytes,
              header.dictLen <= maxSpanBytes,
              header.recordCount <= maxRecords,
              header.refCount <= maxRefs,
              header.refCount >= 2,
              header.recordCount >= header.refCount else {
            return nil
        }
        guard let dictionaryLine = readLine(in: bytes, cursor: &cursor) else { return nil }
        guard dictionaryLine.first == UInt8(ascii: "D"),
              dictionaryLine.count >= 2,
              dictionaryLine[1] == UInt8(ascii: "\t") else {
            return nil
        }
        let escapedDictionary = Array(dictionaryLine.dropFirst(2))
        guard !escapedDictionary.isEmpty,
              let dictionary = unescape(escapedDictionary),
              !dictionary.isEmpty,
              dictionary.count == header.dictLen else {
            return nil
        }

        var parts: [Part] = []
        var refs = 0
        var previousLiteral = false
        for _ in 0..<header.recordCount {
            guard let line = readLine(in: bytes, cursor: &cursor) else { return nil }
            if line == [UInt8(ascii: "R")] {
                parts.append(.ref)
                refs += 1
                previousLiteral = false
            } else if line.first == UInt8(ascii: "L"),
                      line.count >= 2,
                      line[1] == UInt8(ascii: "\t") {
                if previousLiteral { return nil }
                let escaped = Array(line.dropFirst(2))
                guard !escaped.isEmpty, let literal = unescape(escaped), !literal.isEmpty else {
                    return nil
                }
                parts.append(.literal(literal))
                previousLiteral = true
            } else {
                return nil
            }
        }
        guard refs == header.refCount, parts.count == header.recordCount else { return nil }
        guard Array(bytes[cursor...]) == Array("END".utf8) else { return nil }

        var decoded: [UInt8] = []
        decoded.reserveCapacity(header.decodedLen)
        for part in parts {
            switch part {
            case .ref:
                decoded.append(contentsOf: dictionary)
            case .literal(let literal):
                decoded.append(contentsOf: literal)
            }
        }
        guard decoded.count == header.decodedLen,
              decoded.count <= maxDecodedBytes,
              decoded.count <= bytes.count * maxDecodedToWireRatio,
              let source = String(bytes: decoded, encoding: .utf8),
              let item = String(bytes: bytes, encoding: .utf8) else {
            return nil
        }
        return ParsedItem(source: source, item: item)
    }

    private static func parseHeader(_ line: [UInt8]) -> (
        decodedLen: Int,
        dictLen: Int,
        recordCount: Int,
        refCount: Int
    )? {
        let fields = splitTabs(line)
        guard fields.count == 5, fields[0] == [UInt8(ascii: "H")] else { return nil }
        guard let decodedLen = parseUnsigned(fields[1]),
              let dictLen = parseUnsigned(fields[2]),
              let recordCount = parseUnsigned(fields[3]),
              let refCount = parseUnsigned(fields[4]) else {
            return nil
        }
        return (decodedLen, dictLen, recordCount, refCount)
    }

    // MARK: - Bytes

    private enum Part {
        case literal([UInt8])
        case ref
    }

    private struct Candidate {
        let item: String
        let span: [UInt8]
        let first: Int

        func isBetter(than other: Candidate?) -> Bool {
            guard let other else { return true }
            let lhs = item.utf8.count
            let rhs = other.item.utf8.count
            if lhs != rhs { return lhs < rhs }
            if span.count != other.span.count { return span.count > other.span.count }
            if first != other.first { return first < other.first }
            return span.lexicographicallyPrecedes(other.span)
        }
    }

    private static func containsUnsupportedControl(_ bytes: [UInt8]) -> Bool {
        bytes.contains { byte in
            if byte == 0x09 || byte == 0x0A || byte == 0x0D { return false }
            return byte < 0x20 || byte == 0x7F
        }
    }

    private static func isScalarStart(_ bytes: [UInt8], _ index: Int) -> Bool {
        index == bytes.count || (bytes[index] & 0xC0) != 0x80
    }

    private static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for byte in bytes {
            switch byte {
            case 0x5C:
                output.append(contentsOf: [0x5C, 0x5C])
            case 0x0A:
                output.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D:
                output.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09:
                output.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            default:
                output.append(byte)
            }
        }
        return output
    }

    private static func unescape(_ bytes: [UInt8]) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C {
                guard index + 1 < bytes.count else { return nil }
                switch bytes[index + 1] {
                case 0x5C:
                    output.append(0x5C)
                case UInt8(ascii: "n"):
                    output.append(0x0A)
                case UInt8(ascii: "r"):
                    output.append(0x0D)
                case UInt8(ascii: "t"):
                    output.append(0x09)
                default:
                    return nil
                }
                index += 2
            } else {
                if byte < 0x20 || byte == 0x7F { return nil }
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    private static func parseUnsigned(_ bytes: [UInt8]) -> Int? {
        guard !bytes.isEmpty else { return nil }
        if bytes.count > 1 && bytes[0] == UInt8(ascii: "0") { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            let digit = Int(byte - UInt8(ascii: "0"))
            guard value <= (maxDecodedBytes - digit) / 10 else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    private static func splitTabs(_ line: [UInt8]) -> [[UInt8]] {
        var fields: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in line {
            if byte == UInt8(ascii: "\t") {
                fields.append(current)
                current = []
            } else {
                current.append(byte)
            }
        }
        fields.append(current)
        return fields
    }

    private static func readLine(in bytes: [UInt8], cursor: inout Int) -> [UInt8]? {
        guard cursor < bytes.count else { return nil }
        var index = cursor
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n") {
            index += 1
        }
        guard index < bytes.count else { return nil }
        let line = Array(bytes[cursor..<index])
        cursor = index + 1
        return line
    }

    private static func consume(_ text: String, in bytes: [UInt8], cursor: inout Int) -> Bool {
        let expected = Array(text.utf8)
        guard cursor + expected.count <= bytes.count,
              bytes[cursor..<(cursor + expected.count)].elementsEqual(expected) else {
            return false
        }
        cursor += expected.count
        return true
    }
}
