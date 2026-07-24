import XCTest
@testable import DistillCore
@testable import CoreModel

final class TokenSaverWaveAShadowMetricsBridgeTests: XCTestCase {
    func test_bridgeEmitIncrementsSharedLedger() {
        let d = String(repeating: "ef", count: 32)
        let before = TokenSaverWaveAShadowMetrics.sharedLedger.count
        let payload = Data("hello".utf8)
        let out = TokenSaverWaveAShadowBridge.observeShadowMetrics(
            bindingDigest: d,
            providerVisible: payload,
            cacheVolatileTokens: 1,
            queueCohortSize: 0,
            pair: nil
        )
        XCTAssertEqual(out, payload)
        XCTAssertEqual(TokenSaverWaveAShadowMetrics.sharedLedger.count, before + 1)
    }
}
