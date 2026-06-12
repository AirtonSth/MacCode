import XCTest
@testable import Surfaces

// Tests for TerminalSurface.autoSubmitNotice(promptCount:).
//
// WHY: A silent auto-submit confuses users -- the terminal appears to type on
// its own. These tests lock down the exact notice strings so that:
//   - promptCount 1: user knows the app answered the first password prompt.
//   - promptCount 2: user knows the SERVER rejected the saved password and is
//     asking again; the app will NOT re-submit (didSendSavedSSHPassword guard).
//   - other counts: no notice (first prompt handled; beyond second is a live
//     server conversation the app should not annotate).
//
// All three cases are pure (nonisolated static) so no @MainActor is needed.
final class TerminalSSHPasswordNoticeTests: XCTestCase {

    // MARK: - promptCount == 1: app auto-submitted the saved password

    func test_autoSubmitNotice_firstPrompt_returnsAutoSubmitMessage() {
        // WHY: Without this notice the user sees the cursor move past a password
        // prompt they did not interact with and has no idea the app did it.
        let notice = TerminalSurface.autoSubmitNotice(promptCount: 1)
        XCTAssertNotNil(notice,
            "first password prompt must produce a notice so users know the app acted")
        XCTAssertTrue(notice!.contains("saved password"),
            "notice must reference 'saved password' so the user understands the source")
        XCTAssertTrue(notice!.contains("automatically"),
            "notice must include 'automatically' to signal the app answered, not the user")
    }

    // MARK: - promptCount == 2: server re-asked; saved password was rejected

    func test_autoSubmitNotice_secondPrompt_returnsRejectedAndReaskMessage() {
        // WHY: If the saved password is wrong the server re-issues a password prompt.
        // Without a notice the user sees a second prompt with no context and may
        // assume the app is stuck in a loop, or that they need to re-enter.
        let notice = TerminalSurface.autoSubmitNotice(promptCount: 2)
        XCTAssertNotNil(notice,
            "second password prompt must produce a notice so users know the server rejected the saved password")
        XCTAssertTrue(notice!.contains("rejected") || notice!.contains("again"),
            "notice must signal the password was rejected or that the server is asking again")
        XCTAssertTrue(notice!.contains("manually"),
            "notice must direct the user to type the password manually")
    }

    // MARK: - promptCount == 0: no-op (guard path)

    func test_autoSubmitNotice_zeroPromptCount_returnsNil() {
        // WHY: promptCount starts at 0 and is incremented before calling this
        // function, so 0 should never reach a notice -- but the seam must be
        // safe if called with 0 (e.g. future refactor that resets the counter).
        XCTAssertNil(TerminalSurface.autoSubmitNotice(promptCount: 0),
            "prompt count 0 must return nil -- no auto-submit has occurred yet")
    }

    // MARK: - promptCount >= 3: no annotation beyond the second prompt

    func test_autoSubmitNotice_thirdAndBeyond_returnsNil() {
        // WHY: After the second prompt the user is in a live SSH conversation.
        // Annotating every subsequent password prompt would be noisy and wrong
        // (the app is no longer involved -- didSendSavedSSHPassword prevents re-submit).
        XCTAssertNil(TerminalSurface.autoSubmitNotice(promptCount: 3),
            "third prompt must return nil -- app is no longer auto-submitting")
        XCTAssertNil(TerminalSurface.autoSubmitNotice(promptCount: 99),
            "large prompt counts must also return nil")
    }
}
