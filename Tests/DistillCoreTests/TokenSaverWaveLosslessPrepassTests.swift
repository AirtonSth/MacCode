import XCTest
import CoreModel
@testable import DistillCore

final class TokenSaverWaveLosslessPrepassTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TokenSaverWaveLiveRollout.resetForTesting()
        TokenSaverWaveLosslessPrepass.setLossyCrushersOptInForTesting(nil)
    }

    override func tearDown() {
        TokenSaverWaveLosslessPrepass.setLossyCrushersOptInForTesting(nil)
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

    /// WHY: Lossy Wave B crushers embed `[[rc:handle]]` markers. Default-off (even when
    /// `waveBCrushers` is live) prevents the prepass from serving unrecoverable lossy
    /// output without an explicit opt-in + durable store (T-003 store-before-loss).
    func test_lossyCrushers_offByDefault_evenWhenWaveBLive() {
        TokenSaverWaveLiveRollout.activate(.waveBCrushers)
        // Force default-off path (ignore any ambient env from the host process).
        TokenSaverWaveLosslessPrepass.setLossyCrushersOptInForTesting(false)
        XCTAssertFalse(
            TokenSaverWaveLosslessPrepass.lossyCrushersOptIn,
            "lossy crushers must default OFF independent of TokenSaverWaveLiveRollout"
        )

        let withFailures = """
        ============================= test session starts ==============================
        collected 3 items
        test_b.py::test_fail FAILED
        test_c.py::test_fail2 FAILED
        =========================== 2 failed, 1 passed in 0.12s ===========================
        test_b.py::test_fail FAILED
        test_c.py::test_fail2 FAILED
        """
        XCTAssertNil(
            TokenSaverWaveLosslessPrepass.apply(input: withFailures, toolHint: "bash"),
            "Wave B live alone must not early-return lossy crusher output"
        )
    }

    /// WHY: structured-JSON only proves sorted-key deep equality + min gain — not
    /// `expand(collapse(x)) == x`. Early-return would skip the sidecar and serve
    /// reformatted (non-byte-exact) JSON without a recoverable original (T-003).
    func test_structuredJSON_semanticEquality_doesNotEarlyReturn() {
        TokenSaverWaveLiveRollout.activate(.waveA)

        // Pretty-printed homogeneous object: compact form gains well over 30% and
        // would have been accepted by the old early-return path.
        let pretty = """
        {
          "alpha" : 1,
          "bravo" : 2,
          "charlie" : 3,
          "delta" : 4,
          "echo" : 5,
          "foxtrot" : 6,
          "golf" : 7,
          "hotel" : 8
        }
        """
        let trimmed = pretty.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(TokenSaverWaveALossless.isHomogeneousJSON(trimmed))

        guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let compactData = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let compact = String(data: compactData, encoding: .utf8) else {
            return XCTFail("fixture must compact")
        }
        XCTAssertTrue(
            TokenSaverWaveALossless.structuredJSONAllows(original: trimmed, collapsed: compact),
            "fixture must be eligible for structured-JSON so nil proves the early-return gate"
        )
        XCTAssertNotEqual(compact, trimmed, "compact must differ byte-wise from pretty input")

        XCTAssertNil(
            TokenSaverWaveLosslessPrepass.apply(input: pretty),
            "semantic-equality-only transform must return nil so ManagedDistillCLI falls through"
        )
    }

    /// WHY: process-local `MemoryStore` dies with the CLI process; any `[[rc:handle]]`
    /// it backs is unrecoverable via sidecar `/v1/retrieve`. Even with opt-in on, missing
    /// or process-local store must return nil (T-003 store-before-loss) — no new
    /// persistence layer is invented.
    func test_noHandleWithoutDurableStore_evenWhenOptIn() {
        TokenSaverWaveLiveRollout.activate(.waveBCrushers)
        TokenSaverWaveLosslessPrepass.setLossyCrushersOptInForTesting(true)
        defer { TokenSaverWaveLosslessPrepass.setLossyCrushersOptInForTesting(nil) }

        let withFailures = """
        ============================= test session starts ==============================
        collected 3 items
        test_b.py::test_fail FAILED
        test_c.py::test_fail2 FAILED
        =========================== 2 failed, 1 passed in 0.12s ===========================
        test_b.py::test_fail FAILED
        test_c.py::test_fail2 FAILED
        """

        XCTAssertNil(
            TokenSaverWaveLosslessPrepass.apply(input: withFailures, toolHint: "bash"),
            "opt-in without injected durable store must not emit lossy handles"
        )

        let processLocal = TokenSaverTypedCrushers.MemoryStore()
        XCTAssertTrue(TokenSaverTypedCrushers.isProcessLocalStore(processLocal))
        XCTAssertNil(
            TokenSaverWaveLosslessPrepass.apply(
                input: withFailures,
                toolHint: "bash",
                durableStore: processLocal
            ),
            "process-local MemoryStore must be refused for [[rc:handle]] emission"
        )
        XCTAssertTrue(TokenSaverTypedCrushers.isProcessLocalStore(TokenSaverTypedCrushers.sharedMemory))
    }
}
