import XCTest
import CoreModel
@testable import Surfaces

/// WHY: the user asked that a Bot's avatar keeps moving while it works and stays calm otherwise.
final class BotsAvatarMotionTests: XCTestCase {
    func test_workingBotUsesTheWorkingLoopAndIdleBotsOnlyMoveOnHover() {
        XCTAssertEqual(BotsAvatarView.motionMode(for: .working), .working)
        XCTAssertEqual(BotsAvatarView.motionMode(for: .none), .hover)
        XCTAssertEqual(BotsAvatarView.motionMode(for: .needsAttention), .hover)
    }

    func test_workingPoseComesFromTheWorkingLoop() {
        let pose = BotBlobatarView.pose(motion: .working, seed: "Piper", time: 0.3, expression: .happy)
        XCTAssertEqual(pose, BotBlobatarMotion.sampleWorking(name: "Piper", time: 0.3))
        XCTAssertEqual(BotBlobatarView.pose(motion: .frozen, seed: "Piper", time: 0.3, expression: .happy), .still)
    }
}
