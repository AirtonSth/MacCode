import XCTest
@testable import Surfaces

// BellDetector is a pure, non-MainActor helper — no @MainActor annotation needed.
//
// WHY these tests matter: the original `data.contains(0x07)` check fires for
// any byte equal to 0x07 in the PTY stream. OSC sequences (ESC ] ... BEL) use
// 0x07 as a legal string-terminator. Every `printf "\e]0;My Title\a"` call in
// the shell emits a 0x07 that is NOT an audible bell — treating it as one
// produces a false unread-activity dot and potential sound/flash on every
// title-change. BellDetector.containsStandaloneBEL() must return false for
// OSC-terminated 0x07 and true only for bare 0x07 bytes.
final class TerminalBellDetectorTests: XCTestCase {

    // MARK: - standalone BEL (should return true)

    func test_bareBEL_returnsTrueForSingleByte() {
        // A lone 0x07 in the stream is a real BEL; the terminal must fire the
        // bell feedback so the user can notice an alert from a running command.
        let data = Data([0x07])
        XCTAssertTrue(BellDetector.containsStandaloneBEL(data),
            "bare 0x07 must be detected as a real BEL; missing it suppresses bell feedback")
    }

    func test_bareBEL_insideNormalText_returnsTrue() {
        // BEL buried in regular output bytes is still a real bell.
        let data = Data([0x68, 0x69, 0x07, 0x6F, 0x6B]) // "hi\x07ok"
        XCTAssertTrue(BellDetector.containsStandaloneBEL(data),
            "0x07 embedded in non-escape output must be treated as a real BEL")
    }

    func test_multipleBELs_anyStandaloneReturnsTrueEarly() {
        // Two bare BELs: both are real; the first hit should be enough.
        let data = Data([0x07, 0x07])
        XCTAssertTrue(BellDetector.containsStandaloneBEL(data),
            "two bare BELs must produce a true return (the first standalone BEL is sufficient)")
    }

    // MARK: - OSC-terminated BEL (should return false)

    func test_oscTitleSetWithBELTerminator_returnsFalse() {
        // OSC title: ESC ] 0 ; T i t l e BEL
        // The 0x07 here terminates the OSC sequence, not a bell. Treating it as
        // a bell fires the dot/sound every time the shell refreshes the tab title.
        let data = Data([0x1B, 0x5D, 0x30, 0x3B, 0x54, 0x69, 0x74, 0x6C, 0x65, 0x07])
        XCTAssertFalse(BellDetector.containsStandaloneBEL(data),
            "0x07 that terminates an OSC sequence must NOT be treated as a real BEL (false-positive suppression)")
    }

    func test_oscWithEmptyPayloadBELTerminator_returnsFalse() {
        // ESC ] BEL — shortest possible OSC
        let data = Data([0x1B, 0x5D, 0x07])
        XCTAssertFalse(BellDetector.containsStandaloneBEL(data),
            "minimal OSC ESC ] BEL must not produce a false-positive bell detection")
    }

    func test_oscWithTwoByteSTTerminator_returnsFalse() {
        // OSC terminated by two-byte ST (ESC \): ESC ] 0 ; Hi ESC backslash
        let data = Data([0x1B, 0x5D, 0x30, 0x3B, 0x48, 0x69, 0x1B, 0x5C])
        XCTAssertFalse(BellDetector.containsStandaloneBEL(data),
            "OSC using two-byte ST (ESC backslash) must not trigger bell detection")
    }

    func test_oscFollowedByStandaloneBEL_returnsTrue() {
        // OSC title (BEL-terminated) then a real BEL after it.
        // ESC ] 0 ; Hi BEL BEL — the second 0x07 is standalone.
        let data = Data([0x1B, 0x5D, 0x30, 0x3B, 0x48, 0x69, 0x07, 0x07])
        XCTAssertTrue(BellDetector.containsStandaloneBEL(data),
            "OSC BEL-terminator followed by a bare BEL must detect the standalone one")
    }

    func test_multipleOSCsWithBELTerminators_noStandaloneBEL_returnsFalse() {
        // Two consecutive OSC sequences, both BEL-terminated; no real bell.
        // ESC ] 1 ; A BEL ESC ] 2 ; B BEL
        let data = Data([0x1B, 0x5D, 0x31, 0x3B, 0x41, 0x07,
                         0x1B, 0x5D, 0x32, 0x3B, 0x42, 0x07])
        XCTAssertFalse(BellDetector.containsStandaloneBEL(data),
            "two consecutive OSC title-set sequences must produce no false-positive bell detection")
    }

    // MARK: - empty / edge cases

    func test_emptyData_returnsFalse() {
        XCTAssertFalse(BellDetector.containsStandaloneBEL(Data()),
            "empty data has no BEL; must return false to avoid spurious bell on empty reads")
    }

    func test_dataWithoutBEL_returnsFalse() {
        // Normal text output, no BEL.
        let data = Data("ls -la".utf8)
        XCTAssertFalse(BellDetector.containsStandaloneBEL(data),
            "output with no 0x07 byte must return false")
    }

    func test_escapeNotFollowedByOSCIntroducer_thenBEL_returnsTrue() {
        // ESC followed by something other than ']' resets state; subsequent BEL is standalone.
        // ESC A BEL
        let data = Data([0x1B, 0x41, 0x07])
        XCTAssertTrue(BellDetector.containsStandaloneBEL(data),
            "ESC not followed by ] must reset state; subsequent 0x07 is a real BEL")
    }

    func test_oscWithESCinsideNotFollowedByBackslash_thenBEL_isStandalone() {
        // Inside OSC, ESC followed by non-'\' is not a two-byte ST; 0x07 after that is real.
        // ESC ] 1 ; ESC A BEL — the ESC A is not ST, BEL after is standalone.
        let data = Data([0x1B, 0x5D, 0x31, 0x3B, 0x1B, 0x41, 0x07])
        XCTAssertTrue(BellDetector.containsStandaloneBEL(data),
            "ESC inside OSC not forming two-byte ST must not prevent standalone BEL detection after")
    }
}
