import XCTest
@testable import CoreModel

final class TokenSaverCacheGuardTests: XCTestCase {
    func test_defaultOff() {
        XCTAssertFalse(TokenSaverCacheGuard.defaultEnabled)
        XCTAssertFalse(TokenSaverCacheGuard.shouldEnableToolDeferral(hasCapability: true, catalogCount: 100, threshold: 10))
        XCTAssertFalse(TokenSaverCacheGuard.admit(
            systemBytes: Data("SYS".utf8), liveBytes: Data("live".utf8),
            candidate: Data("SYSlive".utf8), beforeHitRate: 0.5, afterHitRate: 0.9
        ))
    }

    func test_systemPrefixProtected() {
        let sys = Data("SYSTEM\n".utf8)
        let live = Data("hello".utf8)
        XCTAssertTrue(TokenSaverCacheGuard.liveZoneOnly(systemBytes: sys, liveBytes: live, candidate: sys + live))
        XCTAssertFalse(TokenSaverCacheGuard.liveZoneOnly(systemBytes: sys, liveBytes: live, candidate: Data("TAMPERED".utf8)))
    }

    func test_netCostRegression() {
        XCTAssertTrue(TokenSaverCacheGuard.netCacheCostRegression(beforeHitRate: 0.8, afterHitRate: 0.5))
        XCTAssertFalse(TokenSaverCacheGuard.netCacheCostRegression(beforeHitRate: 0.5, afterHitRate: 0.8))
    }

    func test_coreTools() {
        XCTAssertTrue(TokenSaverCacheGuard.coreToolsPresent(tools: ["Read","Edit","Bash"], core: ["Read","Edit"]))
        XCTAssertFalse(TokenSaverCacheGuard.coreToolsPresent(tools: ["Read"], core: ["Read","Edit"]))
    }
}
