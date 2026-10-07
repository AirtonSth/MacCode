import XCTest
@testable import AgentRuntime

/// Upgraded machines can still hold symlinks to `RemoteCodeDistillService`
/// from the removed Token Saver (PATH wrappers, a `distill` link, Grok hook
/// files). These tests pin that none of them can break a shell or a provider
/// turn once the compression modes are gone.
final class RemoteCodeServiceFallbackArgvTests: XCTestCase {
    func test_leftoverWrapperSymlink_runsTheRealCommandWithItsArguments() {
        // WHY: the managed bin stays first on PATH, so a surviving `rg` or
        // `node` wrapper must still run the real tool, or the user's shell and
        // Codex's `#!/usr/bin/env node` launch would fail.
        XCTAssertEqual(
            RemoteCodeServiceFallbackArgv.route(programName: "/Users/me/.remote-code/bin/rg", arguments: ["pattern", "src"]),
            .passthrough(command: "rg", arguments: ["pattern", "src"])
        )
        XCTAssertEqual(
            RemoteCodeServiceFallbackArgv.route(programName: "node", arguments: ["/opt/homebrew/bin/codex", "app-server"]),
            .passthrough(command: "node", arguments: ["/opt/homebrew/bin/codex", "app-server"])
        )
    }

    func test_wrapperWhoseFirstArgumentIsCli_stillRunsTheRealCommand() {
        // WHY: only the service binary itself understood the legacy `cli`
        // form; `git cli …` through a leftover wrapper is an ordinary command.
        XCTAssertEqual(
            RemoteCodeServiceFallbackArgv.route(programName: "git", arguments: ["cli", "hook"]),
            .passthrough(command: "git", arguments: ["cli", "hook"])
        )
    }

    func test_staleGrokHook_isANoOpSoTheProviderKeepsOriginalToolOutput() {
        // WHY: old `~/.grok/hooks` files run `distill hook …`; anything other
        // than a quiet success could block or rewrite a Grok tool call.
        XCTAssertEqual(
            RemoteCodeServiceFallbackArgv.route(programName: "distill", arguments: ["hook", "pre-tool-pipe"]),
            .legacyHookNoOp
        )
        XCTAssertEqual(
            RemoteCodeServiceFallbackArgv.route(
                programName: "/App/Contents/MacOS/RemoteCodeDistillService",
                arguments: ["cli", "hook", "post-tool-use-grok"]
            ),
            .legacyHookNoOp
        )
    }

    func test_otherDistillCalls_goToTheRealDistillOnPath() {
        // WHY: a bare `distill` must reach the Distill agent harness CLI, not
        // a compression mode that no longer exists.
        XCTAssertEqual(
            RemoteCodeServiceFallbackArgv.route(programName: "distill", arguments: ["summarize the log"]),
            .passthrough(command: "distill", arguments: ["summarize the log"])
        )
        XCTAssertEqual(
            RemoteCodeServiceFallbackArgv.route(programName: "RemoteCodeDistillService", arguments: ["cli", "--version"]),
            .passthrough(command: "distill", arguments: ["--version"])
        )
    }

    func test_serviceBinaryWithUnknownArguments_isAUsageError_notAPassthroughToItself() {
        // WHY: passing `RemoteCodeDistillService` through would look itself up
        // on PATH; the removed HTTP sidecar, `mcp` and `wrap` modes must fail
        // loudly instead.
        for arguments in [[], ["--auth-token", "t", "--app-support-dir", "/tmp"], ["mcp"], ["wrap", "rg", "x"]] {
            XCTAssertEqual(
                RemoteCodeServiceFallbackArgv.route(programName: "RemoteCodeDistillService", arguments: arguments),
                .usage,
                "\(arguments)"
            )
        }
    }
}
