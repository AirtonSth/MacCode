import XCTest
@testable import DistillCore
@testable import CoreModel

final class TokenSaverTypedCrushersBridgeTests: XCTestCase {
    func test_pytestFailureLines_excludesSummary() {
        let out = """
        test_a FAILED
        test_b FAILED
        ===== 2 failed, 3 passed in 0.1s =====
        """
        let lines = TokenSaverTypedCrushersBridge.pytestFailureLines(from: out)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.contains(where: { $0.contains("=====") }))
    }

    func test_bridgeObserve_doesNotThrow() {
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Bash",
            output: "test_a FAILED\n===== 1 failed ====="
        )
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Grep",
            output: "a.swift:1:hit"
        )
        XCTAssertTrue(true)
    }
}
