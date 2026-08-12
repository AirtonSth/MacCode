import XCTest
@testable import AgentRuntime
import CoreModel

/// Fix B (login-shell env parity) — pure parser fixtures + the processEnvironment
/// merge policy, exercised deterministically via injected captured env (no real
/// shell spawn) so the Finder-minimal-parent behavior is testable in `swift test`,
/// which itself runs with a full inherited env.
final class LoginShellEnvironmentTests: XCTestCase {

    override func tearDown() {
        LoginShellEnvironment.resetForTesting()
        super.tearDown()
    }

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: Pure parser

    func test_parse_discardsNoiseBeforeSentinel_andReadsNulRecords() {
        let s = LoginShellEnvironment.sentinel
        let blob = "p10k instant prompt noise\r\n\u{0}\(s)\u{0}FOO=bar\u{0}RUNPOD_API_KEY=secret123\u{0}"
        let env = LoginShellEnvironment.parse(data(blob))
        XCTAssertEqual(env?["FOO"], "bar")
        XCTAssertEqual(env?["RUNPOD_API_KEY"], "secret123",
                       "a profile-exported secret must survive parsing")
    }

    func test_parse_splitsOnFirstEqualsOnly_keepingMultiEqualsValues() {
        let s = LoginShellEnvironment.sentinel
        let blob = "\u{0}\(s)\u{0}LS_COLORS=di=1;34:ln=35\u{0}"
        let env = LoginShellEnvironment.parse(data(blob))
        XCTAssertEqual(env?["LS_COLORS"], "di=1;34:ln=35",
                       "values containing '=' must not be rejected or truncated")
    }

    func test_parse_returnsNilWhenSentinelAbsent() {
        // No sentinel -> capture produced only noise/failure -> fail-open, never a
        // partial dictionary.
        XCTAssertNil(LoginShellEnvironment.parse(data("FOO=bar\u{0}oops no sentinel")))
    }

    func test_captureOnce_drainsOverCapStdout_andRejectsPartialEnvironment() throws {
        // Exercise the real Process reader: a child that emits beyond the cap
        // must still reach EOF, or it can block forever on the pipe before the
        // parser gets a chance to reject its incomplete environment.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shell = dir.appendingPathComponent("noisy-login-shell")
        try """
        #!/bin/sh
        /usr/bin/printf '\\000__RC_LOGIN_ENV_V1__\\000PARTIAL=kept\\000'
        /bin/dd if=/dev/zero bs=1048576 count=2 2>/dev/null
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)

        let result = LoginShellEnvironment.captureOnce(
            parentEnvironment: [:],
            shellPath: shell.path
        )

        XCTAssertNil(result,
                     "an over-cap child must be drained to completion and then rejected instead of caching its sentinel-bearing prefix")
    }

    func test_captureOnce_scrubsManagedIntegrationHomeBeforeSupportShellSpawn() {
        // WHY: prewarm can run before any provider environment is constructed.
        // The login-shell capture itself is a support child and must never inherit
        // the app-owned integration root.
        var spawnedEnvironment: [String: String] = [:]
        let result = LoginShellEnvironment.captureOnce(
            parentEnvironment: [
                "SHELL": "/bin/zsh",
                "RC2_MANAGED_INTEGRATION_HOME": "/tmp/app-owned-home",
            ],
            spawn: { _, _, environment, _ in
                spawnedEnvironment = environment
                return self.data("\u{0}\(LoginShellEnvironment.sentinel)\u{0}OK=1\u{0}")
            }
        )

        XCTAssertEqual(result?["OK"], "1")
        XCTAssertNil(spawnedEnvironment["RC2_MANAGED_INTEGRATION_HOME"])
    }

    func test_parse_skipsRecordsWithNoEquals() {
        let s = LoginShellEnvironment.sentinel
        let env = LoginShellEnvironment.parse(data("\u{0}\(s)\u{0}garbage\u{0}OK=1\u{0}"))
        XCTAssertNil(env?["garbage"])
        XCTAssertEqual(env?["OK"], "1")
    }

    // MARK: processEnvironment merge policy (login env injected)

    private let guiBase = ["HOME": "/Users/dev", "PATH": "/usr/bin", "TMPDIR": "/gui/tmp"]

    func test_agentTurn_importsProfileSecretButKeepsWrapperPathFirst() {
        LoginShellEnvironment.setForTesting([
            "RUNPOD_API_KEY": "secret", "PATH": "/Users/dev/.custom/bin:/usr/bin"
        ])
        let env = CodexRunner.processEnvironment(
            overrides: [:], purpose: .agentTurn(.codex), base: guiBase)
        XCTAssertEqual(env["RUNPOD_API_KEY"], "secret",
                       "agent turns must inherit a profile-only secret (parity with the terminal)")
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertEqual(path.first, "/Users/dev/.remote-code/bin",
                       "managed wrapper dir must remain first on PATH")
        XCTAssertTrue(path.contains("/Users/dev/.custom/bin"),
                      "profile PATH additions must be reachable by agent tools")
    }

    func test_supportProcess_neverImportsLoginEnv() {
        LoginShellEnvironment.setForTesting(["RUNPOD_API_KEY": "secret"])
        let env = CodexRunner.processEnvironment(
            overrides: [:], purpose: .supportProcess, base: guiBase)
        XCTAssertNil(env["RUNPOD_API_KEY"],
                     "support processes (model discovery, probes, npm) must NOT receive profile secrets")
        XCTAssertNil(env["REMOTE_CODE_AGENT_PROVIDER"],
                     "support processes carry no provider attribution")
    }

    func test_managedIntegrationHomeIsScrubbedFromAllProviderAndSupportChildren() {
        // WHY: RC2_MANAGED_INTEGRATION_HOME controls app-owned filesystem
        // integration. It is host bootstrap state, not provider run state, and
        // must stay private even when inherited from GUI, login shell, or an
        // explicit provider-instance override.
        LoginShellEnvironment.setForTesting([
            "RC2_MANAGED_INTEGRATION_HOME": "/tmp/from-login"
        ])
        let purposes: [(String, CodexRunner.EnvironmentPurpose)] = [
            ("Claude", .agentTurn(.claude)),
            ("Codex", .agentTurn(.codex)),
            ("Grok", .agentTurn(.grok)),
            ("support", .supportProcess),
        ]

        for (label, purpose) in purposes {
            let env = CodexRunner.processEnvironment(
                overrides: ["RC2_MANAGED_INTEGRATION_HOME": "/tmp/from-override"],
                purpose: purpose,
                base: guiBase.merging([
                    "RC2_MANAGED_INTEGRATION_HOME": "/tmp/from-gui",
                ]) { _, override in override }
            )
            XCTAssertNil(
                env["RC2_MANAGED_INTEGRATION_HOME"],
                "\(label) child environment must scrub the app-host-only managed integration root"
            )
        }
    }

    func test_claudeAgentTurn_stripsAuthKeysOnBothBranches_soOAuthStaysDefault() {
        // success branch: login exports auth tokens incl. an unknown future variant
        LoginShellEnvironment.setForTesting([
            "ANTHROPIC_AUTH_TOKEN": "t", "ANTHROPIC_API_KEY": "k", "ANTHROPIC_FUTURE_ROUTE": "z"
        ])
        let onSuccess = CodexRunner.processEnvironment(
            overrides: [:], purpose: .agentTurn(.claude), base: guiBase)
        XCTAssertNil(onSuccess["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(onSuccess["ANTHROPIC_API_KEY"],
                     "a profile auth token must not silently flip Claude off claude.ai OAuth")
        XCTAssertNil(onSuccess["ANTHROPIC_FUTURE_ROUTE"],
                     "prefix strip must fail-safe against unknown future ANTHROPIC_* routing keys")

        // fail-open branch: capture failed, GUI env carries the key
        LoginShellEnvironment.setForTesting(nil)
        let onFailOpen = CodexRunner.processEnvironment(
            overrides: [:], purpose: .agentTurn(.claude),
            base: guiBase.merging(["ANTHROPIC_API_KEY": "k"]) { _, b in b })
        XCTAssertNil(onFailOpen["ANTHROPIC_API_KEY"],
                     "auth strip must apply on the fail-open branch too")
    }

    func test_perInstanceOverrideCanReAddAuthKey_optIn() {
        LoginShellEnvironment.setForTesting([:])
        let env = CodexRunner.processEnvironment(
            overrides: ["ANTHROPIC_API_KEY": "explicit"],
            purpose: .agentTurn(.claude), base: guiBase)
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "explicit",
                       "an explicit per-instance override must still be able to opt into an API key")
    }

    func test_agentTurn_stripsLoaderControlInjectionIncludingUnknownDyldVariant() {
        LoginShellEnvironment.setForTesting([
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "DYLD_SOME_FUTURE_KNOB": "x",
            "NODE_OPTIONS": "--require=/tmp/x.js",
            "http_proxy": "http://attacker",   // secret-shaped but not a loader control: kept
            "RUNPOD_API_KEY": "ok"
        ])
        let env = CodexRunner.processEnvironment(
            overrides: [:], purpose: .agentTurn(.codex), base: guiBase)
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"], "loader injection must be stripped")
        XCTAssertNil(env["DYLD_SOME_FUTURE_KNOB"],
                     "prefix match must strip unknown future DYLD_* variants (fail-safe)")
        XCTAssertNil(env["NODE_OPTIONS"], "code-injection env must be stripped")
        XCTAssertEqual(env["RUNPOD_API_KEY"], "ok", "ordinary secrets must still flow")
    }

    func test_killSwitchDisablesImport_restoringGuiOnlyBehavior() {
        LoginShellEnvironment.setForTesting(["RUNPOD_API_KEY": "secret"])
        let env = CodexRunner.processEnvironment(
            overrides: [:], purpose: .agentTurn(.claude),
            base: guiBase.merging(["RC_LOGIN_SHELL_ENV_IMPORT": "0", "ANTHROPIC_API_KEY": "k"]) { _, b in b })
        XCTAssertNil(env["RUNPOD_API_KEY"], "kill-switch off must not import login env")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "k",
                       "kill-switch off restores exact pre-parity behavior (no strips)")
    }

    func test_guiOwnedIdentityKeysAreNotOverlaidFromLogin() {
        LoginShellEnvironment.setForTesting(["HOME": "/login/home", "TMPDIR": "/login/tmp", "OK": "1"])
        let env = CodexRunner.processEnvironment(
            overrides: [:], purpose: .agentTurn(.codex), base: guiBase)
        XCTAssertEqual(env["HOME"], "/Users/dev", "GUI-owned HOME must not be overlaid by the login shell")
        XCTAssertEqual(env["TMPDIR"], "/gui/tmp", "GUI-owned TMPDIR must win")
        XCTAssertEqual(env["OK"], "1", "non-owned login keys still overlay")
    }
}
