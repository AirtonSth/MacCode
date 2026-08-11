import XCTest
@testable import AgentRuntime

/// Bounds for coordinator hot-replay rehydrate window (memory R6 residual).
final class HotReplayWindowCapTests: XCTestCase {
    func test_hotReplayWindowDefaults() {
        XCTAssertEqual(AgentRunCoordinator.hotReplayEventCount, 4_096)
        XCTAssertEqual(AgentRunCoordinator.hotReplayEventBytes, 32 * 1_024 * 1_024)
        // Count window must stay below the old 16k ceiling that could pin
        // multi-MB event arrays during Full Access / Chrome storms.
        XCTAssertLessThan(AgentRunCoordinator.hotReplayEventCount, 16_384)
        XCTAssertLessThan(AgentRunCoordinator.hotReplayEventBytes, 256 * 1_024 * 1_024)
    }

    func test_retentionEstimate_16kHotReplayTo4kWindow() {
        let uncappedCount = 16_384
        let count = AgentRunCoordinator.hotReplayEventCount
        let countReduction = Double(uncappedCount - count) / Double(uncappedCount)
        XCTAssertGreaterThan(countReduction, 0.74)
        XCTAssertEqual(count, 4_096)

        let uncappedBytes = 256 * 1_024 * 1_024
        let bytes = Int(AgentRunCoordinator.hotReplayEventBytes)
        let byteReduction = Double(uncappedBytes - bytes) / Double(uncappedBytes)
        XCTAssertGreaterThan(byteReduction, 0.85)
        XCTAssertEqual(bytes, 32 * 1_024 * 1_024)
    }

    func test_streamFlushAndBufferCeilings() {
        XCTAssertEqual(AgentRunCoordinator.streamFlushByteThreshold, 2 * 1_024 * 1_024)
        XCTAssertEqual(AgentRunCoordinator.maximumBufferedEventBytes, 4 * 1_024 * 1_024)
        XCTAssertGreaterThan(
            AgentRunCoordinator.maximumBufferedEventBytes,
            AgentRunCoordinator.streamFlushByteThreshold
        )
    }
}
