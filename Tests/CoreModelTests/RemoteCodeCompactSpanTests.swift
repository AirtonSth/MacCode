import XCTest
@testable import CoreModel

/// WHY: RCS1 is a lossless request codec. A broken encoder/parser would either
/// send unrecoverable provider bytes or accept an alternate encoding of the same
/// Human, which the selector would then rank as a different envelope.
final class RemoteCodeCompactSpanTests: XCTestCase {
    func test_repeatedASCIIRoundtripsAndReencodesCanonically() throws {
        let source = String(repeating: "ABCDEFGH", count: 16)
        let item = try XCTUnwrap(RemoteCodeCompactSpan.encode(source))
        assertCanonicalItem(item, source: source)
        XCTAssertEqual(RemoteCodeCompactSpan.encode(source), item)
        XCTAssertEqual(RemoteCodeCompactSpan.encodeCanonicalChoice(source), item)
    }

    func test_multilineTabBackslashAndUnicodeRoundtrip() throws {
        let source = "keep\tthis\npath\\\\and\r"
            + String(repeating: "世界世界", count: 12)
            + " extra "
            + String(repeating: "世界世界", count: 12)
        let item = try XCTUnwrap(RemoteCodeCompactSpan.encode(source))
        assertCanonicalItem(item, source: source)
        XCTAssertTrue(item.contains("\\t") || item.contains("\\n") || item.contains("\\r") || item.contains("\\\\"))
        XCTAssertTrue(item.contains("世界"))
    }

    func test_encodeIsDeterministicAcrossRepeatedCalls() throws {
        let source = String(repeating: "tokenSaver", count: 8)
        let first = try XCTUnwrap(RemoteCodeCompactSpan.encode(source))
        for _ in 0..<5 {
            XCTAssertEqual(RemoteCodeCompactSpan.encode(source), first)
        }
    }

    func test_noSpanEmptyOversizeAndUnsupportedControlFailClosed() {
        XCTAssertNil(RemoteCodeCompactSpan.encode(""), "empty source has no RCS1 candidate")
        XCTAssertNil(RemoteCodeCompactSpan.encode("short"), "below two min-span copies")
        XCTAssertNil(
            RemoteCodeCompactSpan.encode("abcdefghijklmnop"),
            "unique text has no eligible repeated span"
        )
        let oversize = String(repeating: "A", count: RemoteCodeCompactSpan.encoderMaxSourceBytes + 1)
        XCTAssertNil(RemoteCodeCompactSpan.encode(oversize), "encoder must reject oversized source before search")
        XCTAssertNil(
            RemoteCodeCompactSpan.encode("ABCDEFGH\u{0001}ABCDEFGH"),
            "unsupported C0 must fail closed"
        )
        XCTAssertNil(
            RemoteCodeCompactSpan.encode("ABCDEFGH\u{007f}ABCDEFGH"),
            "DEL must fail closed"
        )
    }

    func test_malformedHeaderNumbersEscapeTruncationTrailingAndSecondDFail() throws {
        let source = String(repeating: "XXXXXXXX", count: 16)
        let valid = try XCTUnwrap(RemoteCodeCompactSpan.encode(source))
        XCTAssertNil(RemoteCodeCompactSpan.decode("RCW1/1\n" + dropFirstLine(valid)))
        XCTAssertNil(RemoteCodeCompactSpan.decode(valid.replacingOccurrences(of: "H\t", with: "H ")))
        XCTAssertNil(RemoteCodeCompactSpan.decode(mutatingH(valid) { fields in
            fields[0] = "01"
        }), "leading-zero numbers are noncanonical")
        XCTAssertNil(RemoteCodeCompactSpan.decode(valid.replacingOccurrences(of: "D\t", with: "D\t\\x")))
        XCTAssertNil(RemoteCodeCompactSpan.decode(String(valid.dropLast(3))), "truncated END")
        XCTAssertNil(RemoteCodeCompactSpan.decode(valid + "\n"), "trailing bytes")
        XCTAssertNil(RemoteCodeCompactSpan.decode(valid + "x"), "trailing payload")
        XCTAssertNil(RemoteCodeCompactSpan.decode(insertSecondD(valid)))
    }

    func test_rWithoutDCountLengthRecordsRefsRatioAndCapsFail() throws {
        let source = String(repeating: "XXXXXXXX", count: 16)
        let valid = try XCTUnwrap(RemoteCodeCompactSpan.encode(source))
        XCTAssertNil(RemoteCodeCompactSpan.decode(removingD(valid)), "R without D")
        XCTAssertNil(RemoteCodeCompactSpan.decode(mutatingH(valid) { fields in
            fields[2] = "99"
        }), "record_count mismatch")
        XCTAssertNil(RemoteCodeCompactSpan.decode(mutatingH(valid) { fields in
            fields[0] = "4"
        }), "decoded length mismatch")
        XCTAssertNil(RemoteCodeCompactSpan.decode(mutatingH(valid) { fields in
            fields[1] = "1"
        }), "dict length mismatch")
        XCTAssertNil(RemoteCodeCompactSpan.decode(adjacentL(valid)))
        XCTAssertNil(RemoteCodeCompactSpan.decode(emptyDictionary(valid)))
        XCTAssertNil(RemoteCodeCompactSpan.decode(emptyLiteral(valid)))
        XCTAssertNil(RemoteCodeCompactSpan.decode(singleRef(valid)))
        XCTAssertNil(RemoteCodeCompactSpan.decode(invalidTag(valid)))
        XCTAssertNil(RemoteCodeCompactSpan.decode(rawTabInDictionary(valid)))
        XCTAssertNil(RemoteCodeCompactSpan.decode(craftedHighRatioItem()))
        XCTAssertNil(RemoteCodeCompactSpan.decode(craftedOversizeDecodedHeader()))
    }

    func test_decodeReturnsNothingUntilTheCompleteItemValidates() throws {
        let source = String(repeating: "XXXXXXXX", count: 16)
        let valid = try XCTUnwrap(RemoteCodeCompactSpan.encode(source))
        let utf8 = Array(valid.utf8)
        for end in 1..<utf8.count {
            let prefix = String(decoding: utf8.prefix(end), as: UTF8.self)
            XCTAssertNil(
                RemoteCodeCompactSpan.decode(prefix),
                "partial \(end)-byte prefix must not decode"
            )
        }
        XCTAssertEqual(RemoteCodeCompactSpan.decode(valid), source)
    }

    func test_invalidUTF8BytesFailClosed() {
        let bytes: [UInt8] = Array("RCS1/1\nH\t1\t8\t2\t2\nD\t".utf8) + [0xFF, 0xFE] + Array("\nR\nR\nEND".utf8)
        XCTAssertNil(RemoteCodeCompactSpan.decode(bytes: bytes))
    }

    func test_rcs1ItemIsNotRCWireProtocolWire() throws {
        let source = String(repeating: "XXXXXXXX", count: 16)
        let item = try XCTUnwrap(RemoteCodeCompactSpan.encode(source))
        XCTAssertTrue(item.hasPrefix("RCS1/1\n"))
        XCTAssertFalse(
            RCWireProtocol.isWire(item),
            "RCS1 must never be classified as RCW1 transport"
        )
        XCTAssertFalse(RCWireProtocol.isWire("RCS1/1\n"))
    }

    func test_longRepeatedSentenceEncodesWithinRatioCap() throws {
        let source = String(
            repeating: "Verbose English guidance carries recoverable contextual explanation. ",
            count: 90
        )
        let item = try XCTUnwrap(
            RemoteCodeCompactSpan.encode(source),
            "a repeated Human-sized prompt must still have a ratio-legal RCS1 candidate"
        )
        XCTAssertEqual(RemoteCodeCompactSpan.decode(item), source)
        XCTAssertLessThan(item.utf8.count, source.utf8.count)
        XCTAssertLessThanOrEqual(source.utf8.count, item.utf8.count * RemoteCodeCompactSpan.maxDecodedToWireRatio)
    }

    func test_completeWireMustBeStrictlySmallerThanSource() throws {
        let source = String(repeating: "ABCDEFGH", count: 16)
        let item = try XCTUnwrap(RemoteCodeCompactSpan.encode(source))
        XCTAssertLessThan(item.utf8.count, source.utf8.count)
    }

    func test_hostileNumericHeaderFieldsFailClosedWithoutPartialOutput() {
        let names = ["decodedLen", "dictLen", "recordCount", "refCount"]
        for index in 0..<4 {
            let overflowItem = hostileNumericItem(fieldIndex: index, digits: String(repeating: "9", count: 20))
            XCTAssertLessThanOrEqual(overflowItem.utf8.count, RemoteCodeCompactSpan.maxWireBytes)
            XCTAssertNil(
                RemoteCodeCompactSpan.decode(overflowItem),
                "\(names[index]) overflow-width digits must return nil, not a partial source"
            )
            XCTAssertNil(RemoteCodeCompactSpan.decode(bytes: Array(overflowItem.utf8)))

            let maxItem = hostileNumericItemFillingWire(fieldIndex: index)
            XCTAssertLessThanOrEqual(maxItem.utf8.count, RemoteCodeCompactSpan.maxWireBytes)
            XCTAssertEqual(maxItem.utf8.count, RemoteCodeCompactSpan.maxWireBytes)
            XCTAssertNil(
                RemoteCodeCompactSpan.decode(maxItem),
                "\(names[index]) max-wire hostile digits must return nil without crashing"
            )
            XCTAssertNil(RemoteCodeCompactSpan.decode(bytes: Array(maxItem.utf8)))
        }
    }

    // MARK: - Helpers

    private func assertCanonicalItem(_ item: String, source: String) {
        XCTAssertTrue(item.hasPrefix("RCS1/1\n"), item)
        XCTAssertTrue(item.hasSuffix("END"))
        XCTAssertFalse(item.hasSuffix("END\n"))
        XCTAssertEqual(RemoteCodeCompactSpan.decode(item), source)
        XCTAssertEqual(RemoteCodeCompactSpan.encodeCanonicalChoice(source), item)
        XCTAssertEqual(RemoteCodeCompactSpan.encode(source), item)
        let lines = item.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "RCS1/1")
        XCTAssertTrue(lines[1].hasPrefix("H\t"))
        XCTAssertTrue(lines[2].hasPrefix("D\t"))
        XCTAssertEqual(lines.last, "END")
        let header = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(header.count, 5)
        XCTAssertEqual(header[0], "H")
        XCTAssertEqual(Int(header[1]), source.utf8.count)
        XCTAssertEqual(RemoteCodeCompactSpan.decode(bytes: Array(item.utf8)), source)
    }

    private func dropFirstLine(_ item: String) -> String {
        let rest = item.drop(while: { $0 != "\n" }).dropFirst()
        return String(rest)
    }

    private func mutatingH(_ item: String, _ mutate: (inout [String]) -> Void) -> String {
        var lines = item.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fields = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        mutate(&fields)
        lines[1] = fields.joined(separator: "\t")
        return lines.joined(separator: "\n")
    }

    private func insertSecondD(_ item: String) -> String {
        var lines = item.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.insert(lines[2], at: 3)
        return lines.joined(separator: "\n")
    }

    private func removingD(_ item: String) -> String {
        var lines = item.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.remove(at: 2)
        return lines.joined(separator: "\n")
    }

    private func adjacentL(_ item: String) -> String {
        var lines = item.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.insert("L\tone", at: 3)
        lines.insert("L\ttwo", at: 4)
        return mutatingH(lines.joined(separator: "\n")) { fields in
            if let count = Int(fields[2]) {
                fields[2] = String(count + 2)
            }
        }
    }

    private func emptyDictionary(_ item: String) -> String {
        var lines = item.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[2] = "D\t"
        return lines.joined(separator: "\n")
    }

    private func emptyLiteral(_ item: String) -> String {
        var lines = item.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.insert("L\t", at: 3)
        return mutatingH(lines.joined(separator: "\n")) { fields in
            if let count = Int(fields[2]) {
                fields[2] = String(count + 1)
            }
        }
    }

    private func singleRef(_ item: String) -> String {
        var lines = item.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines = lines.filter { $0 != "R" }
        lines.insert("R", at: 3)
        return mutatingH(lines.joined(separator: "\n")) { fields in
            fields[2] = String(lines.count - 4)
            fields[3] = "1"
        }
    }

    private func invalidTag(_ item: String) -> String {
        var lines = item.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.insert("X\tnope", at: 3)
        return mutatingH(lines.joined(separator: "\n")) { fields in
            if let count = Int(fields[2]) {
                fields[2] = String(count + 1)
            }
        }
    }

    private func rawTabInDictionary(_ item: String) -> String {
        var lines = item.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[2] = "D\tXXXX\tYYYY"
        return lines.joined(separator: "\n")
    }

    private func craftedHighRatioItem() -> String {
        let span = String(repeating: "Z", count: 256)
        var lines = ["RCS1/1", "H\t25600\t256\t100\t100", "D\t\(span)"]
        lines.append(contentsOf: repeatElement("R", count: 100))
        lines.append("END")
        return lines.joined(separator: "\n")
    }

    private func craftedOversizeDecodedHeader() -> String {
        let span = "YYYYYYYY"
        let lines = ["RCS1/1", "H\t65537\t8\t2\t2", "D\t\(span)", "R", "R", "END"]
        return lines.joined(separator: "\n")
    }

    private func hostileNumericItem(fieldIndex: Int, digits: String) -> String {
        var fields = ["16", "8", "2", "2"]
        fields[fieldIndex] = digits
        return ["RCS1/1", "H\t\(fields.joined(separator: "\t"))", "D\tYYYYYYYY", "R", "R", "END"]
            .joined(separator: "\n")
    }

    private func hostileNumericItemFillingWire(fieldIndex: Int) -> String {
        let probe = hostileNumericItem(fieldIndex: fieldIndex, digits: "9")
        let extra = RemoteCodeCompactSpan.maxWireBytes - probe.utf8.count
        XCTAssertGreaterThan(extra, 0)
        return hostileNumericItem(fieldIndex: fieldIndex, digits: String(repeating: "9", count: extra + 1))
    }
}
