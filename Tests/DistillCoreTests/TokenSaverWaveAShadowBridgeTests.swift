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
        let limit = TokenSaverWaveAShadowBridge.maxReplayKeys
        for index in 0..<(limit + 50) {
            TokenSaverWaveAShadowBridge.observeExactReplay(
                bindingDigest: "binding-\(index)",
                toolName: "Bash",
                current: Data("payload".utf8)
            )
        }
        XCTAssertEqual(TokenSaverWaveAShadowBridge.replayStateCountForTesting(), limit)
        XCTAssertEqual(TokenSaverWaveAShadowBridge.maxReplayKeys, 128)
    }


    func test_retentionEstimate_256KeysTo128Window() {
        let uncapped = 256 // prior maxReplayKeys
        let limit = TokenSaverWaveAShadowBridge.maxReplayKeys
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 128)
        // Basis: modest tool prior ~4KB (pathological multi-MB dumps scale
        // with the same key ceiling).
        // 256 × 4KB ≈ 1MB → 128 × 4KB ≈ 512KB (−50%).
        let perKey = 4_096
        XCTAssertEqual(uncapped * perKey, 1_048_576)
        XCTAssertEqual(limit * perKey, 524_288)
    }
}
