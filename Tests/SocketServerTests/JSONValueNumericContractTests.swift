import XCTest
import SocketServer

/// `JSONValue.intValue` backs many remotely-reachable integer RPC fields. It must
/// never trap on a hostile or oversized JSON number: `Int(_: Double)` aborts the
/// host process on overflow, while `Int(exactly:)` returns nil. These tests pin
/// that contract (would crash the runner before the fix).
final class JSONValueNumericContractTests: XCTestCase {
    func testIntValueRejectsOutOfRangeNonFiniteAndFractionalWithoutTrapping() {
        XCTAssertNil(JSONValue.number(0x1p63).intValue)     // 2^63 > Int.max
        XCTAssertNil(JSONValue.number(-0x1p64).intValue)    // -2^64 < Int.min
        XCTAssertNil(JSONValue.number(1.5).intValue)        // fractional
        XCTAssertNil(JSONValue.number(.infinity).intValue)
        XCTAssertNil(JSONValue.number(.nan).intValue)
    }

    func testIntValuePreservesRepresentableIntegers() {
        XCTAssertEqual(JSONValue.number(0).intValue, 0)
        XCTAssertEqual(JSONValue.number(-1).intValue, -1)
        XCTAssertEqual(JSONValue.number(42).intValue, 42)
        let nearMax = Double(Int.max).nextDown            // largest Double < 2^63
        XCTAssertEqual(JSONValue.number(nearMax).intValue, Int(nearMax))
    }
}
