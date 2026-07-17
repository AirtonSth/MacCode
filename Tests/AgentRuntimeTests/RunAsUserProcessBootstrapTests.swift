import XCTest
@testable import AgentRuntime
import CoreModel

/// WHY: Cross-user execution must only wrap allowlisted absolute binaries and
/// must no-op for the current uid — otherwise every local run would fail when
/// the privileged helper is not installed.
final class RunAsUserProcessBootstrapTests: XCTestCase {
    func test_currentUser_doesNotUseHelper() throws {
        let current = AgentRunAsUser.current()
        let plan = try RunAsUserProcessBootstrap.plan(
            executablePath: "/usr/local/bin/codex",
            arguments: ["exec", "hi"],
            environment: ["FOO": "1"],
            currentDirectory: "/tmp",
            runAsUser: current,
            helperLocator: { _ in "/Library/PrivilegedHelperTools/RemoteCodeRunAsUserHelper" },
            currentUID: current.uid
        )
        XCTAssertFalse(plan.usesHelper)
        XCTAssertEqual(plan.executablePath, "/usr/local/bin/codex")
        XCTAssertEqual(plan.arguments, ["exec", "hi"])
    }

    func test_otherUser_rewritesToHelper() throws {
        let other = AgentRunAsUser(
            generatedUID: "local-work-502",
            shortName: "work",
            uid: 502,
            gid: 20,
            homePath: "/Users/work"
        )
        let plan = try RunAsUserProcessBootstrap.plan(
            executablePath: "/opt/homebrew/bin/claude",
            arguments: ["-p", "hello"],
            environment: ["PATH": "/usr/bin"],
            currentDirectory: "/Users/shared/project",
            runAsUser: other,
            helperLocator: { name in
                name == "RemoteCodeRunAsUserHelper" ? "/tmp/RemoteCodeRunAsUserHelper" : nil
            },
            currentUID: 501
        )
        XCTAssertTrue(plan.usesHelper)
        XCTAssertEqual(plan.executablePath, "/tmp/RemoteCodeRunAsUserHelper")
        XCTAssertEqual(plan.arguments.first, "exec")
        XCTAssertTrue(plan.arguments.contains("--uid"))
        XCTAssertTrue(plan.arguments.contains("502"))
        XCTAssertTrue(plan.arguments.contains("--user"))
        XCTAssertTrue(plan.arguments.contains("work"))
        XCTAssertTrue(plan.arguments.contains("/opt/homebrew/bin/claude"))
        XCTAssertTrue(plan.arguments.contains("hello"))
    }

    func test_rejectsRelativeBinaryAndUnknownBasename() {
        let other = AgentRunAsUser(
            generatedUID: "x", shortName: "work", uid: 502, gid: 20, homePath: "/Users/work"
        )
        XCTAssertThrowsError(
            try RunAsUserProcessBootstrap.plan(
                executablePath: "codex",
                arguments: [],
                environment: [:],
                currentDirectory: "/tmp",
                runAsUser: other,
                helperLocator: { _ in "/tmp/helper" },
                currentUID: 501
            )
        )
        XCTAssertThrowsError(
            try RunAsUserProcessBootstrap.plan(
                executablePath: "/usr/bin/python3",
                arguments: [],
                environment: [:],
                currentDirectory: "/tmp",
                runAsUser: other,
                helperLocator: { _ in "/tmp/helper" },
                currentUID: 501
            )
        )
    }

    func test_missingHelper_failsLoudly() {
        let other = AgentRunAsUser(
            generatedUID: "x", shortName: "work", uid: 502, gid: 20, homePath: "/Users/work"
        )
        XCTAssertThrowsError(
            try RunAsUserProcessBootstrap.plan(
                executablePath: "/usr/local/bin/codex",
                arguments: [],
                environment: [:],
                currentDirectory: "/tmp",
                runAsUser: other,
                helperLocator: { _ in nil },
                currentUID: 501
            )
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("helper") || message.lowercased().contains("unavailable"),
                          "missing helper must surface a clear install error, got: \(message)")
        }
    }
}
