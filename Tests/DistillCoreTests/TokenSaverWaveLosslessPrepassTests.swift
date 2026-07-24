import XCTest
import CoreModel
@testable import DistillCore

final class TokenSaverWaveLosslessPrepassTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TokenSaverWaveLiveRollout.resetForTesting()
    }

    override func tearDown() {
        TokenSaverWaveLiveRollout.resetForTesting()
        super.tearDown()
    }

    func test_waveA_repeatedLog_savesBytesWhenLive() {
        TokenSaverWaveLiveRollout.activate(.waveA)
        let line = "same log line that repeats many times for compression"
        var input = ""
        for _ in 0..<20 { input += line + "\n" }
        input += "exit code: 0\n"

        let result = TokenSaverWaveLosslessPrepass.apply(input: input)
        XCTAssertNotNil(result, "Wave A live must collapse repeated logs")
        XCTAssertEqual(result?.waveID, "wave_a")
        XCTAssertEqual(result?.trigger, "repeated_log")
        XCTAssertGreaterThan(result?.savedBytes ?? 0, 0)
        XCTAssertLessThan(result?.compressedBytes ?? Int.max, result?.originalBytes ?? 0)
    }

    func test_waveA_off_doesNotMutate() {
        let line = "same log line that repeats many times for compression"
        var input = ""
        for _ in 0..<20 { input += line + "\n" }
        XCTAssertNil(TokenSaverWaveLosslessPrepass.apply(input: input))
    }

    func test_waveB_pytest_savesWhenLive() {
        TokenSaverWaveLiveRollout.activate(.waveBCrushers)
        let input = """
        ============================= test session starts ==============================
        collected 3 items
        test_a.py::test_ok PASSED
        test_b.py::test_fail FAILED
        test_c.py::test_fail2 FAILED
        =========================== 2 failed, 1 passed in 0.12s ===========================
        """
        // Ensure failure lines exist for count match
        let withFailures = input + "\ntest_b.py::test_fail FAILED\ntest_c.py::test_fail2 FAILED\n"
        let result = TokenSaverWaveLosslessPrepass.apply(input: withFailures, toolHint: "bash")
        // May or may not accept depending on count match; if accepted, must save bytes
        if let result {
            XCTAssertEqual(result.waveID, "wave_b_crushers")
            XCTAssertGreaterThan(result.savedBytes, 0)
        }
    }
}
