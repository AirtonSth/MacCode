import XCTest
@testable import AppShell
@testable import Persistence

/// Intent: v2 must be packaged as RemoteCode, with the legacy desktop
/// bundle identifier and icon, so users can install it as an update.
final class AppIdentityNotificationTests: XCTestCase {
    func testReleaseChannelUsesLegacyRemoteCodeDesktopIdentity() {
        XCTAssertEqual(ReleaseChannel.stable.bundleID, "io.remotecode.desktop")
        XCTAssertEqual(ReleaseChannel.stable.displayName, "RemoteCode")
        XCTAssertEqual(ReleaseChannel.debug.displayName, "RemoteCodeDebug")
    }

    func testPackageScriptBuildsRemoteCodeAppWithLegacyIcon() throws {
        let script = try String(contentsOf: packageScriptURL())

        XCTAssertTrue(script.contains("BUNDLE=\"RemoteCode.app\""))
        XCTAssertTrue(script.contains("BUNDLE_ID=\"${RC2_BUNDLE_ID:-io.remotecode.desktop}\""))
        XCTAssertTrue(script.contains("<key>CFBundleDisplayName</key><string>RemoteCode</string>"))
        XCTAssertTrue(script.contains("<key>CFBundleIconFile</key><string>AppIcon</string>"))
        XCTAssertTrue(script.contains("AppIcon.icns"))
    }

    func testThreadOutcomeNotificationContentMatchesLegacyActionablePhases() {
        XCTAssertNil(RemoteCodeNotificationContent.threadOutcome(
            threadId: "t1",
            title: "Build fix",
            phase: .running
        ))

        let completed = RemoteCodeNotificationContent.threadOutcome(
            threadId: "t1",
            title: "Build fix",
            phase: .completed
        )
        XCTAssertEqual(completed?.title, "Thread finished")
        XCTAssertEqual(completed?.body, "Build fix response is ready.")
        XCTAssertEqual(completed?.categoryIdentifier, "RemoteCodeThreadUpdate")
        XCTAssertEqual(completed?.userInfo["threadId"], "t1")
    }

    private func packageScriptURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/package-app.sh")
    }
}
