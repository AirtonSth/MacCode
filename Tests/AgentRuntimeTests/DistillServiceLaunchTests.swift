import XCTest
import CoreModel
@testable import DistillCore

final class DistillServiceLaunchTests: XCTestCase {
    func test_parse_treatsNonFlagArgAsMissingRequiredOption() {
        // WHY: this is the exact stderr Codex app-server surfaces when Distill
        // is invoked as the `node` interpreter for Homebrew `codex`.
        XCTAssertThrowsError(
            try DistillServiceConfiguration.parse(arguments: ["/opt/homebrew/bin/codex", "app-server"])
        ) { error in
            XCTAssertEqual(
                error as? DistillServiceError,
                .missingRequiredOption("/opt/homebrew/bin/codex")
            )
            XCTAssertEqual(
                String(describing: error),
                "missing required option /opt/homebrew/bin/codex"
            )
        }
    }

    func test_shouldStartHTTPService_onlyForSidecarBasenameWithFlags() {
        XCTAssertTrue(
            DistillServiceLaunch.shouldStartHTTPService(
                programName: "RemoteCodeDistillService",
                arguments: ["--auth-token", "t", "--app-support-dir", "/tmp"]
            )
        )
        XCTAssertTrue(
            DistillServiceLaunch.shouldStartHTTPService(
                programName: "/App/RemoteCodeDistillService",
                arguments: []
            )
        )
        XCTAssertTrue(
            DistillServiceLaunch.shouldStartHTTPService(
                programName: "RemoteCodeDistillService",
                arguments: ["--help"]
            )
        )
    }

    func test_shouldStartHTTPService_rejectsShebangInterpreterWrappers() {
        // WHY: `#!/usr/bin/env node /opt/homebrew/bin/codex app-server` must
        // not become an HTTP sidecar launch.
        XCTAssertFalse(
            DistillServiceLaunch.shouldStartHTTPService(
                programName: "node",
                arguments: ["/opt/homebrew/bin/codex", "app-server"]
            )
        )
        XCTAssertFalse(
            DistillServiceLaunch.shouldStartHTTPService(
                programName: "/Users/me/.remote-code/bin/node",
                arguments: ["/opt/homebrew/bin/codex", "app-server"]
            )
        )
        XCTAssertFalse(
            DistillServiceLaunch.shouldStartHTTPService(
                programName: "env",
                arguments: ["node", "/opt/homebrew/bin/codex", "app-server"]
            )
        )
        XCTAssertFalse(
            DistillServiceLaunch.shouldStartHTTPService(
                programName: "RemoteCodeDistillService",
                arguments: ["/opt/homebrew/bin/codex", "app-server"]
            ),
            "a non-flag first arg must never reach DistillServiceConfiguration.parse"
        )
    }
}
