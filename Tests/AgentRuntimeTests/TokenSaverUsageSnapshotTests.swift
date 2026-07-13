import XCTest
@testable import AgentRuntime
import CoreModel

/// Token Saver empty snapshot must reserve a slot for every managed agent provider.
final class TokenSaverUsageSnapshotTests: XCTestCase {
    func test_emptySnapshotIncludesGrokProviderSlot() {
        // WHY: Grok has a purple usage ring in the Token Saver card. Without a
        // reserved provider row, the UI only appears after the first Grok run.
        let providers = Set(TokenSaverUsageSnapshot.empty().providers.map(\.provider))
        XCTAssertTrue(providers.contains(.grok),
                      "empty usage snapshot must include .grok for the purple Token Saver ring")
        XCTAssertTrue(providers.contains(.claude))
        XCTAssertTrue(providers.contains(.codex))
    }
}
