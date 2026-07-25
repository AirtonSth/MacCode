import XCTest
@testable import Persistence

/// WHY: Graphify must not run as a free/always-on capability; Token Saver is the
/// paid gate and Graphify is only active when both toggles are on.
final class GraphifyTokenSaverGateTests: XCTestCase {
    func test_graphifyRuntimeActiveRequiresTokenSaverAndPreference() {
        var s = AppSettings(tokenSaverEnabled: false, graphifyEnabled: true)
        XCTAssertFalse(s.isGraphifyRuntimeActive, "TS off + graphify preference on → inactive")

        s.tokenSaverEnabled = true
        XCTAssertTrue(s.isGraphifyRuntimeActive, "TS on + graphify preference on → active")

        s.graphifyEnabled = false
        XCTAssertFalse(s.isGraphifyRuntimeActive, "TS on + graphify preference off → inactive")

        s.tokenSaverEnabled = false
        s.graphifyEnabled = false
        XCTAssertFalse(s.isGraphifyRuntimeActive)
    }
}
