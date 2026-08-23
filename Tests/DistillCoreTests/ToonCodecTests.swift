import XCTest
@testable import DistillCore

final class ToonCodecTests: XCTestCase {
    func test_usersArrayEncodesTabularAndRoundTrips() throws {
        let json = """
        {"users":[{"id":1,"name":"Ada","role":"admin"},{"id":2,"name":"Bob","role":"user"}]}
        """
        let toon = try XCTUnwrap(ToonCodec.encode(json))
        XCTAssertTrue(toon.contains("users[2]{id,name,role}:"), toon)
        XCTAssertTrue(toon.contains("1,Ada,admin"), toon)
        XCTAssertTrue(toon.contains("2,Bob,user"), toon)
        let back = try XCTUnwrap(ToonCodec.decodeToJSON(toon))
        XCTAssertTrue(ToonCodec.jsonModelEqual(json, back), "got \(back)")
    }

    func test_weatherNestedTabularRoundTrips() throws {
        let json = """
        {
          "location": {"city":"Berlin","country":"DE","units":"metric"},
          "alerts": ["frost","wind"],
          "forecast": [
            {"day":"Mon","temp":{"min":-2,"max":4},"condition":"snow","rainChance":80},
            {"day":"Tue","temp":{"min":1,"max":7},"condition":"cloudy","rainChance":20},
            {"day":"Wed","temp":{"min":3,"max":11},"condition":"sunny","rainChance":5}
          ]
        }
        """
        let toon = try XCTUnwrap(ToonCodec.encode(json))
        XCTAssertTrue(toon.contains("alerts[2]: frost,wind"), toon)
        XCTAssertTrue(toon.contains("forecast[3]{condition,day,rainChance,temp{max,min}}:"), toon)
        let back = try XCTUnwrap(ToonCodec.decodeToJSON(toon))
        XCTAssertTrue(ToonCodec.jsonModelEqual(json, back), "toon=\n\(toon)\nback=\(back)")
    }

    func test_boolsAreNotCoercedToNumbers() throws {
        let json = #"{"ok":true,"off":false,"n":1}"#
        let toon = try XCTUnwrap(ToonCodec.encode(json))
        XCTAssertTrue(toon.contains("ok: true"), toon)
        XCTAssertTrue(toon.contains("off: false"), toon)
        let back = try XCTUnwrap(ToonCodec.decodeToJSON(toon))
        XCTAssertTrue(ToonCodec.jsonModelEqual(json, back), back)
    }

    func test_extractiveJsonQuestionSkips() {
        XCTAssertTrue(ToonCodec.shouldSkipForQuestion("return json only"))
        XCTAssertFalse(ToonCodec.shouldSkipForQuestion("what failed?"))
        XCTAssertFalse(ToonCodec.shouldSkipForQuestion(nil))
    }

    func test_tinyPayloadIsNotAdopted() {
        XCTAssertNil(ToonCodec.encodeIfEfficient(#"{"a":1}"#))
    }

    /// WHY: JSON tool output can contain thousands of keys and string cells;
    /// compiling the same lexical regex for every field makes deterministic
    /// JSON-to-TOON routing spend CPU on regex construction instead of encoding.
    func test_microbench_sharedLexicalRegexesBeatPerFieldCompilation() {
        let keys = (0..<4_096).map { index -> String in
            switch index % 4 {
            case 0: return "field_\(index)"
            case 1: return "nested.field\(index)"
            case 2: return "field-\(index)"
            default: return "field \(index)"
            }
        }
        let values = (0..<4_096).map { index -> String in
            switch index % 4 {
            case 0: return "value-\(index)"
            case 1: return "\(index).5"
            case 2: return index.isMultiple(of: 2) ? "true" : "false"
            default: return "#heading\(index)"
            }
        }
        let warmups = 2
        let samples = 7

        func legacyEncodeKey(_ key: String) -> String {
            let unquoted = try? NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_.]*$")
            let range = NSRange(key.startIndex..<key.endIndex, in: key)
            if unquoted?.firstMatch(in: key, range: range) != nil { return key }
            return "\"\(key)\""
        }

        func legacyEncodeString(_ string: String) -> String {
            let needsQuotes: Bool
            if string.isEmpty
                || string != string.trimmingCharacters(in: .whitespaces)
                || string == "true" || string == "false" || string == "null"
                || string.contains(":") || string.contains("\"") || string.contains("\\")
                || string.contains("[") || string.contains("]")
                || string.contains("{") || string.contains("}")
                || string.contains(",")
                || string.hasPrefix("-") || string.hasPrefix("#")
                || string.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                needsQuotes = true
            } else {
                needsQuotes = string.range(
                    of: #"^[+-]?[0-9]+(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?$"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
            }
            return needsQuotes ? "\"\(string)\"" : string
        }

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }

        func timeLegacy() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            let encodedKeys = keys.map(legacyEncodeKey)
            let encodedValues = values.map(legacyEncodeString)
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(encodedKeys, keys.map(ToonCodec.encodeKey))
            XCTAssertEqual(encodedValues, values.map(ToonCodec.encodeString))
            return Double(end - start) / 1_000_000
        }

        func timeCurrent() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            let encodedKeys = keys.map(ToonCodec.encodeKey)
            let encodedValues = values.map(ToonCodec.encodeString)
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(encodedKeys.count, keys.count)
            XCTAssertEqual(encodedValues.count, values.count)
            return Double(end - start) / 1_000_000
        }

        for _ in 0..<warmups {
            _ = timeLegacy()
            _ = timeCurrent()
        }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timeLegacy())
            after.append(timeCurrent())
        }
        let beforeMedian = median(before)
        let afterMedian = median(after)
        let improvement = (beforeMedian - afterMedian) / beforeMedian * 100
        print(
            "TOON_LEXICAL_BENCH warmups=\(warmups) samples=\(samples) "
                + "before_ms=\(before) after_ms=\(after) "
                + "before_median_ms=\(beforeMedian) after_median_ms=\(afterMedian) "
                + "improvement_pct=\(improvement) keys=\(keys.count) values=\(values.count)"
        )
        XCTAssertGreaterThanOrEqual(
            improvement,
            5,
            "shared lexical regexes must improve the 8,192-field corpus by at least 5%"
        )
    }
}
