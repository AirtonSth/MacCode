import XCTest
@testable import CoreModel

final class BotBrowserHostStateTests: XCTestCase {
    func test_payloadUsesSurfaceBrowserKindAndNewURL() {
        // WHY: iOS mirrors the same host-state event other macOS browsers emit.
        let surface = SurfaceID()
        let payload = BotBrowserHostState.makePayload(
            surfaceID: surface,
            url: "https://login.example.test/in",
            title: "Sign in"
        )
        XCTAssertEqual(BotBrowserHostState.eventKind, "surface.browser")
        XCTAssertEqual(payload["surface_id"], surface.value.uuidString)
        XCTAssertEqual(payload["url"], "https://login.example.test/in")
        XCTAssertEqual(payload["title"], "Sign in")
    }
}
