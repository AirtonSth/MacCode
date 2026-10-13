import XCTest
@testable import AgentRuntime

/// The bot's Linux guest must ask ChatGPT for models as the same Codex client
/// version the Mac's Distill uses: the backend lists newer models only to
/// newer clients, and the model picker offers what the Mac lists.
final class DistillCodexClientVersionTests: XCTestCase {
    /// Counts how often `codex --version` would have been run.
    private final class ProbeCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func probe(answering output: String?) -> DistillCodexClientVersion.Probe {
            { _ in
                self.lock.withLock { self.count += 1 }
                return output
            }
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-client-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Precedence (codex_auth.rs codex_client_version)

    func test_overridesWinInDistillsOrderAndTheInstalledCLIIsNotEvenAsked() async {
        let calls = ProbeCalls()
        let probe = calls.probe(answering: "codex-cli 0.162.1\n")
        let both = await DistillCodexClientVersion.resolve(environment: [
            "DISTILL_CODEX_CLIENT_VERSION": "0.170.0", "REMOTE_CODE_CODEX_CLIENT_VERSION": "0.150.0",
        ], probe: probe)
        XCTAssertEqual(both, "0.170.0", "Distill reads DISTILL_CODEX_CLIENT_VERSION first")
        let legacy = await DistillCodexClientVersion.resolve(
            environment: ["REMOTE_CODE_CODEX_CLIENT_VERSION": "0.150.0"], probe: probe)
        XCTAssertEqual(legacy, "0.150.0", "the legacy name is still an override on the Mac")
        let blank = await DistillCodexClientVersion.resolve(environment: [
            "DISTILL_CODEX_CLIENT_VERSION": "  ", "REMOTE_CODE_CODEX_CLIENT_VERSION": "0.150.0",
        ], probe: probe)
        XCTAssertEqual(blank, "0.150.0", "Distill skips a blank override, so the guest must too")
        XCTAssertEqual(calls.value, 0, "with an override the Mac's Distill never runs codex; asking it could only disagree")
    }

    func test_withoutAnOverrideTheInstalledCodexVersionIsUsed() async {
        let version = await DistillCodexClientVersion.resolve(
            environment: ["DISTILL_CODEX_CLIENT_VERSION": ""],
            probe: { _ in "codex-cli 0.162.1\n" })
        XCTAssertEqual(version, "0.162.1", "this is the version that makes ChatGPT list the Mac's newest models")
    }

    func test_noOverrideAndNoCodexResolvesNothingSoBothSidesUseDistillsDefault() async {
        let version = await DistillCodexClientVersion.resolve(environment: [:], probe: { _ in nil })
        XCTAssertNil(version, "inventing a version here would make the guest differ from a Mac without codex")
    }

    // MARK: Parsing (codex_auth.rs parse_codex_cli_version)

    func test_parsesCodexVersionOutputTheWayDistillDoes() {
        XCTAssertEqual(DistillCodexClientVersion.parse("codex-cli 0.162.1\n"), "0.162.1")
        XCTAssertEqual(DistillCodexClientVersion.parse("  codex-cli 0.163.0-alpha.3  "), "0.163.0-alpha.3")
        for garbage in ["", "\n", "codex-cli", "codex-cli ", "codex 0.162.1", "0.162.1", "zsh: command not found: codex"] {
            XCTAssertNil(DistillCodexClientVersion.parse(garbage),
                         "Distill reads no version from \(garbage.debugDescription), so the guest must get none")
        }
    }

    func test_outputThatIsNotOneVersionResolvesNothing() async {
        for output in ["codex-cli 0.162.1\nA new release is available", "codex-cli not a version", "codex-cli v0.162.1"] {
            let version = await DistillCodexClientVersion.resolve(environment: [:], probe: { _ in output })
            XCTAssertNil(version, "\(output.debugDescription) must not reach the guest's env file")
        }
    }

    // MARK: What may reach the env file

    func test_onlyAVersionIsAcceptable() {
        for version in ["0.162.1", "0.156.0", "1", "0.163.0-alpha.3", "1.0.0+build.5"] {
            XCTAssertTrue(DistillCodexClientVersion.isAcceptable(version), version)
        }
        let unsafe = [
            "", " ", "0.162.1 ", " 0.162.1", "0.162.1\nHOME=/Users/me", "0.162.1\r", "0.1\u{0}", "latest", "v0.162.1",
            "0.162.1=x", "0.162.1\"", "0.162.1;id", "０.162.1", String(repeating: "1", count: 65),
        ]
        for value in unsafe {
            XCTAssertFalse(DistillCodexClientVersion.isAcceptable(value),
                           "\(value.debugDescription) is not a version; in an env file it could add or break a line")
        }
    }

    func test_anOverrideThatIsNotAVersionResolvesNothingInsteadOfFallingBackToCodex() async {
        let calls = ProbeCalls()
        for override in ["latest", "0.170.0\nHOME=/Users/me", " 0.170.0"] {
            let version = await DistillCodexClientVersion.resolve(
                environment: ["DISTILL_CODEX_CLIENT_VERSION": override],
                probe: calls.probe(answering: "codex-cli 0.162.1\n"))
            XCTAssertNil(version, "the Mac's Distill would use \(override.debugDescription), never codex's version; neither may be passed off as the Mac's")
        }
        XCTAssertEqual(calls.value, 0)
    }

    // MARK: The real probe

    private func writeCodex(_ body: String) throws -> [String: String] {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        try "#!/bin/sh\n\(body)\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        // A HOME of its own: the fallback folders under the real one may hold a codex.
        return ["PATH": bin.path, "HOME": root.path]
    }

    func test_theVersionComesFromTheCodexOnTheRunsPATH() async throws {
        let environment = try writeCodex("echo 'codex-cli 0.162.1'")
        let version = await DistillCodexClientVersion.resolve(environment: environment)
        XCTAssertEqual(version, "0.162.1", "the Mac's Distill reads `codex --version` from its PATH; the guest has no codex to ask")
    }

    func test_aCodexThatFailsGivesNoVersion() async throws {
        let environment = try writeCodex("echo 'codex-cli 0.162.1'; exit 3")
        let version = await DistillCodexClientVersion.resolve(environment: environment)
        XCTAssertNil(version, "Distill ignores the output of a failed `codex --version`")
    }

    func test_aWarningOnStderrDoesNotCostTheGuestTheMacsVersion() async throws {
        let environment = try writeCodex("echo '(node:1) DeprecationWarning: x' >&2; echo 'codex-cli 0.162.1'")
        let version = await DistillCodexClientVersion.resolve(environment: environment)
        XCTAssertEqual(version, "0.162.1", "Distill reads only stdout of `codex --version`; mixing stderr in would leave no version and send the guest back to Distill's default")
    }

    func test_aVersionPrintedOnlyOnStderrGivesNoVersion() async throws {
        let environment = try writeCodex("echo 'codex-cli 0.162.1' >&2")
        let version = await DistillCodexClientVersion.resolve(environment: environment)
        XCTAssertNil(version, "the Mac's Distill reads nothing from stderr and uses its default, so the guest must too")
    }

    func test_aCodexThatHangsIsGivenUpOnSoItCannotHoldAGuestRun() async throws {
        let environment = try writeCodex("exec sleep 30")
        let started = Date()
        let output = await DistillCodexClientVersion.installedCodexVersionOutput(environment: environment, timeout: 0.3)
        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the probe is awaited before every guest run's env file is written")
    }
}
