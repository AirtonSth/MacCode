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
}
