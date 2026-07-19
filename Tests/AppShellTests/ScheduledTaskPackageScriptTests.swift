import XCTest

final class ScheduledTaskPackageScriptTests: XCTestCase {
    func test_packagerEmbedsLaunchAgentWithHeadlessArgument_becauseSchedulesMustSurviveAppExit() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/package-app.sh"), encoding: .utf8)
        XCTAssertTrue(source.contains("Contents/Library/LaunchAgents"))
        XCTAssertTrue(source.contains("--scheduled-task-agent"))
        XCTAssertTrue(source.contains("BundleProgram"))
        XCTAssertTrue(source.contains("MachServices"))
        XCTAssertTrue(source.contains("KeepAlive"))
        XCTAssertTrue(source.contains("RC2_CODESIGN_IDENTITY"))
    }

    func test_bundleValidatorRequiresLaunchAgent_becauseMissingPackagingMustFailCI() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/check-app-bundle.sh"), encoding: .utf8)
        XCTAssertTrue(source.contains("missing Scheduled Tasks LaunchAgent"))
        XCTAssertTrue(source.contains("Scheduled Tasks headless argument is missing"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
