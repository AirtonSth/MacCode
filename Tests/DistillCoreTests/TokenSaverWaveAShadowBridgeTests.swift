import XCTest
@testable import DistillCore
@testable import CoreModel

final class TokenSaverWaveAShadowBridgeTests: XCTestCase {
    override func tearDown() {
        TokenSaverWaveAShadowBridge.resetReplayStateForTesting()
        super.tearDown()
    }

    func test_noScoringWithoutBindingDigest() {
        let emptyBefore = TokenSaverWaveALossless.sharedScoreboard.snapshot(
            bindingDigest: "", trigger: .repeatedLog
        )
        TokenSaverWaveAShadowBridge.observeToolOutput(
            toolName: "Bash",
            output: (0..<10).map { _ in "line" }.joined(separator: "\n"),
            bindingDigest: nil
        )
        TokenSaverWaveAShadowBridge.observeToolOutput(
            toolName: "Bash",
            output: (0..<10).map { _ in "line" }.joined(separator: "\n"),
            bindingDigest: ""
        )
        let emptyAfter = TokenSaverWaveALossless.sharedScoreboard.snapshot(
            bindingDigest: "", trigger: .repeatedLog
        )
        XCTAssertEqual(emptyBefore.eligible, emptyAfter.eligible)
        XCTAssertEqual(emptyBefore.attempted, emptyAfter.attempted)
    }

    func test_crossBindingIsolation_exactReplay() {
        let a = "binding-A-\(UUID().uuidString)"
        let b = "binding-B-\(UUID().uuidString)"
        let payload = Data("same-tool-output".utf8)

        XCTAssertEqual(
            TokenSaverWaveALossless.sharedScoreboard.snapshot(bindingDigest: a, trigger: .exactToolReplay).eligible, 0
        )

        // First A: not eligible (no prior), but attempted
        TokenSaverWaveAShadowBridge.observeExactReplay(bindingDigest: a, toolName: "Bash", current: payload)
        let a1 = TokenSaverWaveALossless.sharedScoreboard.snapshot(bindingDigest: a, trigger: .exactToolReplay)
        XCTAssertEqual(a1.eligible, 0)
        XCTAssertEqual(a1.attempted, 1)
        XCTAssertEqual(a1.accepted, 0)

        // Second A: eligible (prior matches)
        TokenSaverWaveAShadowBridge.observeExactReplay(bindingDigest: a, toolName: "Bash", current: payload)
        let a2 = TokenSaverWaveALossless.sharedScoreboard.snapshot(bindingDigest: a, trigger: .exactToolReplay)
        XCTAssertEqual(a2.eligible, 1)
        XCTAssertEqual(a2.attempted, 2)

        // First B: not eligible — A's prior must not leak
        TokenSaverWaveAShadowBridge.observeExactReplay(bindingDigest: b, toolName: "Bash", current: payload)
        let b1 = TokenSaverWaveALossless.sharedScoreboard.snapshot(bindingDigest: b, trigger: .exactToolReplay)
        XCTAssertEqual(b1.eligible, 0)
        XCTAssertEqual(b1.attempted, 1)
        XCTAssertEqual(b1.accepted, 0)
    }

    func test_toolNameIsolation_sameBinding() {
        let d = "binding-T-\(UUID().uuidString)"
        let payload = Data("payload".utf8)
        TokenSaverWaveAShadowBridge.observeExactReplay(bindingDigest: d, toolName: "Bash", current: payload)
        TokenSaverWaveAShadowBridge.observeExactReplay(bindingDigest: d, toolName: "Bash", current: payload)
        let beforeGrep = TokenSaverWaveALossless.sharedScoreboard.snapshot(
            bindingDigest: d, trigger: .exactToolReplay
        )
        // First Grep must not inherit Bash prior → eligible stays same, attempted +1
        TokenSaverWaveAShadowBridge.observeExactReplay(bindingDigest: d, toolName: "Grep", current: payload)
        let afterFirstGrep = TokenSaverWaveALossless.sharedScoreboard.snapshot(
            bindingDigest: d, trigger: .exactToolReplay
        )
        XCTAssertEqual(afterFirstGrep.eligible, beforeGrep.eligible)
        XCTAssertEqual(afterFirstGrep.attempted, beforeGrep.attempted + 1)
        // Second Grep becomes eligible
        TokenSaverWaveAShadowBridge.observeExactReplay(bindingDigest: d, toolName: "Grep", current: payload)
        let afterSecondGrep = TokenSaverWaveALossless.sharedScoreboard.snapshot(
            bindingDigest: d, trigger: .exactToolReplay
        )
        XCTAssertEqual(afterSecondGrep.eligible, beforeGrep.eligible + 1)
    }

    func test_exactReplayStateIsBoundedAcrossDistinctBindings() {
        TokenSaverWaveAShadowBridge.resetReplayStateForTesting()
        for index in 0..<2_100 {
            TokenSaverWaveAShadowBridge.observeExactReplay(
                bindingDigest: "binding-\(index)",
                toolName: "Bash",
                current: Data("payload".utf8)
            )
        }
        XCTAssertLessThanOrEqual(TokenSaverWaveAShadowBridge.replayStateCountForTesting(), 2_048)
    }
}
