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

    func test_argvMode_sidecarHTTPFlagsTakePrecedenceOverWrap() {
        // WHY: wrap-first treats RemoteCodeDistillService as a wrappable
        // basename and prints `RemoteCodeDistillService: command not found`
        // (exit 127) for the host spawn. HTTP identity must win. This is the
        // shipped argvMode main calls — not shouldStartHTTPService alone.
        XCTAssertTrue(
            CommandWrapPolicy.isWrapped("RemoteCodeDistillService"),
            "interceptor still admits the sidecar basename; argv order is the gate"
        )
        XCTAssertEqual(
            DistillServiceLaunch.argvMode(
                programName: "RemoteCodeDistillService",
                arguments: ["--auth-token", "t", "--app-support-dir", "/tmp"]
            ),
            .httpService
        )
        XCTAssertEqual(
            DistillServiceLaunch.argvMode(
                programName: "RemoteCodeDistillService",
                arguments: ["--help"]
            ),
            .httpService
        )
        XCTAssertNotEqual(
            DistillServiceLaunch.argvMode(
                programName: "RemoteCodeDistillService",
                arguments: ["--help"]
            ),
            .wrap(command: "RemoteCodeDistillService", arguments: ["--help"])
        )
        XCTAssertNotEqual(
            DistillServiceLaunch.argvMode(
                programName: "RemoteCodeDistillService",
                arguments: ["--auth-token", "t"]
            ),
            .passthrough
        )
    }

    func test_argvMode_arbitraryCommandStillWrapsAndShebangIsNotHTTP() {
        // WHY: fixing sidecar HTTP identity must not shrink PATH wrap for
        // arbitrary tools, and leftover node/env shebang wrappers must not
        // become an HTTP sidecar launch.
        XCTAssertEqual(
            DistillServiceLaunch.argvMode(
                programName: "workspace-report",
                arguments: ["--summary"]
            ),
            .wrap(command: "workspace-report", arguments: ["--summary"])
        )
        XCTAssertEqual(
            DistillServiceLaunch.argvMode(
                programName: "rg",
                arguments: ["pattern"]
            ),
            .wrap(command: "rg", arguments: ["pattern"])
        )
        XCTAssertEqual(
            DistillServiceLaunch.argvMode(
                programName: "node",
                arguments: ["/opt/homebrew/bin/codex", "app-server"]
            ),
            .passthrough
        )
        XCTAssertEqual(
            DistillServiceLaunch.argvMode(
                programName: "env",
                arguments: ["node", "/opt/homebrew/bin/codex", "app-server"]
            ),
            .passthrough
        )
        XCTAssertNotEqual(
            DistillServiceLaunch.argvMode(
                programName: "node",
                arguments: ["/opt/homebrew/bin/codex", "app-server"]
            ),
            .httpService
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
