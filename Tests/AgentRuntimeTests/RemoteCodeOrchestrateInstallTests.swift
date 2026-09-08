import XCTest
@testable import AgentRuntime

final class RemoteCodeOrchestrateInstallTests: XCTestCase {
    func testWorkerPromptContractProtectsSkillContentAndOrdinaryDistillOnly() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let promptContract = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/AgentRuntime/Resources/remote-code-orchestrate/references/prompt-contract.md"
            ),
            encoding: .utf8
        )
        let skill = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/AgentRuntime/Resources/remote-code-orchestrate/SKILL.md"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(promptContract.contains("Distill:"))
        XCTAssertTrue(promptContract.contains("never Distill skill content")
                      || promptContract.contains("Never Distill skill"),
                      "prompt contract must protect skill bodies")
        XCTAssertTrue(promptContract.contains("must stay complete")
                      || promptContract.contains("skill content must stay complete"),
                      "requested/returned skill content must be complete")
        XCTAssertTrue(promptContract.contains("do not require every worker")
                      || promptContract.contains("Do not require every worker"),
                      "workers must not restate Distill rules")
        XCTAssertFalse(promptContract.contains("repeat this rule in every descendant prompt"),
                       "removed: requiring Distill restatement in every descendant")

        XCTAssertTrue(skill.contains("Never Distill skill content")
                      || skill.contains("never Distill skill content"))
        XCTAssertTrue(skill.contains("stay complete"),
                      "SKILL.md must require complete skill bodies")
        XCTAssertTrue(skill.contains("requested/returned skill bodies")
                      || skill.contains("requested/returned skill content"),
                      "SKILL.md must cover requested and returned skill content")
        XCTAssertFalse(skill.contains("Put the Distill rule in every worker/reviewer prompt"))
        XCTAssertTrue(
            skill.contains("remote-code agent-app <codex|claude|grok>"),
            "controlled provider workers must use the full Agent App middleware"
        )
        XCTAssertTrue(
            skill.contains("telemetry alone is not evidence of token savings"),
            "raw compatibility paths must not be reported as measured Token Saver savings"
        )
        XCTAssertTrue(
            skill.contains("The exact `sam-grok-worker` one-shot")
                && skill.contains("automatically to `remote-code agent-app grok`"),
            "the exact supported Grok worker ABI must document native Agent App promotion"
        )
        XCTAssertTrue(
            skill.contains("Other explicit provider CLI contracts remain raw"),
            "unsupported specialized provider ABIs must retain honest raw-path boundaries"
        )
        XCTAssertFalse(
            skill.contains("python3 "),
            "core orchestration instructions must not require an unbundled Python command"
        )
        XCTAssertTrue(
            skill.contains("optional development validator")
                && skill.contains("review the required"),
            "formal validation may be optional, but contract review remains required"
        )
        XCTAssertTrue(
            skill.contains("Provider-native collaboration whose child prompt is hidden"),
            "the contract must disclose the provider-native prompt boundary"
        )
    }

    func testPinnedManifestMatchesEmbeddedResourceTreeDigest() throws {
        let package = AgentSkillInstaller.remoteCodeOrchestratePinnedPackage
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let embedded = packageRoot.appendingPathComponent(
            "Sources/AgentRuntime/Resources/remote-code-orchestrate",
            isDirectory: true
        )

        XCTAssertEqual(package.skillID, "remote-code-orchestrate")
        XCTAssertEqual(package.sourceRevision, "2c77fa48431bc20e5dc841652079594a3ea918c9")
        XCTAssertEqual(package.localVersion, "6")
        XCTAssertEqual(package.sourceTreeSHA256, "310b92e081a792eb0d755153af1ef62fd98f166be6fca669eee90ddd7298ad48")
        XCTAssertEqual(package.allowedPaths, [
            "SKILL.md",
            "agents/openai.yaml",
            "references/host-runtime-matrix.md",
            "references/output-contract.md",
            "references/prompt-contract.md",
            "references/routing-policy.md",
            "scripts/test_orchestration_harness.py",
            "scripts/validate_orchestration.py"
        ])

        // WHY: pin must match the on-disk embedded package byte-for-byte tree digest.
        // Inventing a digest would let reconcile fail open against the resource bundle.
        var entries: [RemoteCodeOrchestrateFile] = []
        for relativePath in package.allowedPaths {
            let url = embedded.appendingPathComponent(relativePath)
            let data = try Data(contentsOf: url)
            entries.append(RemoteCodeOrchestrateFile(
                relativePath: relativePath,
                byteCount: data.count,
                sha256: AgentSkillInstaller.sha256Hex(data)
            ))
        }
        let actual = AgentSkillInstaller.remoteCodeOrchestrateTreeDigest(entries)
        XCTAssertEqual(actual, package.sourceTreeSHA256,
                       "embedded resource tree digest must match the pin (recompute; do not invent)")
    }

    func testInstallIsIdempotentAndReportsReadyStatus() throws {
        let fixture = try makeFixture(files: [
            "SKILL.md": "# Orchestrate\n",
            "references/policy.md": "policy\n"
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try fixture.installer.installRemoteCodeOrchestrate(from: fixture.source)
        let second = try fixture.installer.installRemoteCodeOrchestrate(from: fixture.source)
        let status = fixture.installer.remoteCodeOrchestrateStatus()

        XCTAssertEqual(first.action, .installed)
        XCTAssertEqual(second.action, .skipped)
        XCTAssertEqual(first.manifest, second.manifest)
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.manifest, first.manifest)
        XCTAssertFalse(status.lastKnownGoodAvailable)
        XCTAssertEqual(
            try String(contentsOf: fixture.installer.remoteCodeOrchestrateDirectory().appendingPathComponent("SKILL.md")),
            "# Orchestrate\n"
        )
    }

    func testRejectsTraversalAndSymlinksBeforeWritingStaging() throws {
        let traversal = try makeFixture(
            files: ["SKILL.md": "safe\n"],
            allowedPaths: ["../outside", "SKILL.md"]
        )
        defer { try? FileManager.default.removeItem(at: traversal.root) }

        XCTAssertThrowsError(try traversal.installer.installRemoteCodeOrchestrate(from: traversal.source)) { error in
            XCTAssertEqual(error as? RemoteCodeOrchestrateInstallError, .unsafeRelativePath("../outside"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: traversal.installer.remoteCodeOrchestrateDirectory().path))

        let symlink = try makeFixture(files: [
            "SKILL.md": "safe\n",
            "references/policy.md": "policy\n"
        ])
        defer { try? FileManager.default.removeItem(at: symlink.root) }
        let outside = symlink.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside\n".utf8).write(to: outside.appendingPathComponent("policy.md"))
        try FileManager.default.removeItem(at: symlink.source.appendingPathComponent("references"))
        try FileManager.default.createSymbolicLink(
            at: symlink.source.appendingPathComponent("references"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try symlink.installer.installRemoteCodeOrchestrate(from: symlink.source)) { error in
            XCTAssertEqual(error as? RemoteCodeOrchestrateInstallError, .symbolicLink("references"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: symlink.installer.remoteCodeOrchestrateDirectory().path))
    }

    func testUnmanagedCollisionIsNeverOverwritten() throws {
        let fixture = try makeFixture(files: ["SKILL.md": "managed\n"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.installer.remoteCodeOrchestrateDirectory()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("user content\n".utf8).write(to: destination.appendingPathComponent("SKILL.md"))

        XCTAssertThrowsError(try fixture.installer.installRemoteCodeOrchestrate(from: fixture.source)) { error in
            XCTAssertEqual(error as? RemoteCodeOrchestrateInstallError, .unmanagedCollision(destination.path))
        }
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("SKILL.md")), "user content\n")
        XCTAssertEqual(fixture.installer.remoteCodeOrchestrateStatus().state, .unmanagedCollision)
    }

    func testUpdatePreservesLastKnownGoodAndRepairRestoresIt() throws {
        let first = try makeFixture(files: ["SKILL.md": "version one\n"], revision: "rev-1")
        defer { try? FileManager.default.removeItem(at: first.root) }
        _ = try first.installer.installRemoteCodeOrchestrate(from: first.source)

        let secondSource = first.root.appendingPathComponent("source-2", isDirectory: true)
        try writeFiles(["SKILL.md": "version two\n"], under: secondSource)
        let secondPackage = package(files: ["SKILL.md": "version two\n"], revision: "rev-2")
        let secondInstaller = first.makeInstaller(secondPackage)
        let update = try secondInstaller.installRemoteCodeOrchestrate(from: secondSource)

        XCTAssertEqual(update.action, .updated)
        XCTAssertTrue(secondInstaller.remoteCodeOrchestrateStatus().lastKnownGoodAvailable)

        let activeSkill = secondInstaller.remoteCodeOrchestrateDirectory().appendingPathComponent("SKILL.md")
        try Data("corrupt\n".utf8).write(to: activeSkill)
        XCTAssertEqual(secondInstaller.remoteCodeOrchestrateStatus().state, .repairRequired)

        let restored = try secondInstaller.restoreRemoteCodeOrchestrateLastKnownGood()
        XCTAssertEqual(restored.sourceRevision, "rev-1")
        XCTAssertEqual(try String(contentsOf: activeSkill), "version one\n")
        XCTAssertEqual(secondInstaller.remoteCodeOrchestrateStatus().state, .updateRequired)
    }

    func testInvalidSourceDoesNotReplaceLastKnownGoodInstall() throws {
        let fixture = try makeFixture(files: ["SKILL.md": "known good\n"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.installer.installRemoteCodeOrchestrate(from: fixture.source)
        try Data("tampered\n".utf8).write(to: fixture.source.appendingPathComponent("SKILL.md"))

        XCTAssertThrowsError(try fixture.installer.installRemoteCodeOrchestrate(from: fixture.source))
        XCTAssertEqual(
            try String(contentsOf: fixture.installer.remoteCodeOrchestrateDirectory().appendingPathComponent("SKILL.md")),
            "known good\n"
        )
    }

    /// WHY: RemoteCode.app and the scheduled-task LaunchAgent both reconcile at
    /// login. Before the loser-tolerant reconcile, the loser's moveItem threw
    /// "file exists" and the error persisted for the whole app session even
    /// though the identical pinned package was already installed.
    func testLoserOfConcurrentInstallRaceConvergesToSkipped() throws {
        let fixture = try makeFixture(files: ["SKILL.md": "# Orchestrate\n"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let racingFileManager = WinnerRacingFileManager()
        racingFileManager.winnerInstall = {
            _ = try fixture.installer.installRemoteCodeOrchestrate(from: fixture.source)
        }
        let loser = AgentSkillInstaller(
            appPrivateSkillsRoot: fixture.skillsRoot,
            remoteCodeOrchestratePackage: fixture.package,
            fileManager: racingFileManager
        )

        let result = try loser.installRemoteCodeOrchestrate(from: fixture.source)

        XCTAssertTrue(racingFileManager.raced, "fixture must actually exercise the race")
        XCTAssertEqual(result.action, .skipped, "losing to an identical pinned install is success")
        XCTAssertEqual(fixture.installer.remoteCodeOrchestrateStatus().state, .ready)
        XCTAssertEqual(
            try String(contentsOf: fixture.installer.remoteCodeOrchestrateDirectory().appendingPathComponent("SKILL.md")),
            "# Orchestrate\n"
        )
    }

    /// The loser-tolerant catch must never mask a real failure: when the
    /// destination does not hold the pinned package, the original error rethrows.
    func testInstallRaceLoserRethrowsWhenDestinationDoesNotMatchPin() throws {
        let fixture = try makeFixture(files: ["SKILL.md": "# Orchestrate\n"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let racingFileManager = WinnerRacingFileManager()
        racingFileManager.winnerInstall = {}
        let loser = AgentSkillInstaller(
            appPrivateSkillsRoot: fixture.skillsRoot,
            remoteCodeOrchestratePackage: fixture.package,
            fileManager: racingFileManager
        )

        XCTAssertThrowsError(try loser.installRemoteCodeOrchestrate(from: fixture.source)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let skillsRoot: URL
        let package: RemoteCodeOrchestratePackage
        let installer: AgentSkillInstaller

        func makeInstaller(_ package: RemoteCodeOrchestratePackage) -> AgentSkillInstaller {
            AgentSkillInstaller(
                appPrivateSkillsRoot: skillsRoot,
                remoteCodeOrchestratePackage: package
            )
        }
    }

    private func makeFixture(
        files: [String: String],
        allowedPaths: [String]? = nil,
        revision: String = "test-revision"
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-orchestrate-tests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try writeFiles(files, under: source)
        let package = package(files: files, allowedPaths: allowedPaths, revision: revision)
        let skillsRoot = root.appendingPathComponent("app-private-skills", isDirectory: true)
        return Fixture(
            root: root,
            source: source,
            skillsRoot: skillsRoot,
            package: package,
            installer: AgentSkillInstaller(
                appPrivateSkillsRoot: skillsRoot,
                remoteCodeOrchestratePackage: package
            )
        )
    }

    private func package(
        files: [String: String],
        allowedPaths: [String]? = nil,
        revision: String
    ) -> RemoteCodeOrchestratePackage {
        let entries = files.map { path, text in
            RemoteCodeOrchestrateFile(
                relativePath: path,
                byteCount: Data(text.utf8).count,
                sha256: AgentSkillInstaller.sha256Hex(Data(text.utf8))
            )
        }
        return RemoteCodeOrchestratePackage(
            skillID: "remote-code-orchestrate",
            sourceURL: "https://example.invalid/sam-orchestrate",
            sourceRevision: revision,
            sourceTreeSHA256: AgentSkillInstaller.remoteCodeOrchestrateTreeDigest(entries),
            localVersion: "1",
            allowedPaths: allowedPaths ?? files.keys.sorted()
        )
    }

    private func writeFiles(_ files: [String: String], under root: URL) throws {
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }
}

/// Simulates the concurrent-reconcile winner: the first move onto the orchestrate
/// destination runs `winnerInstall` (the other process finishing first) and then
/// fails the way FileManager does when the destination already exists.
private final class WinnerRacingFileManager: FileManager, @unchecked Sendable {
    var raced = false
    var winnerInstall: () throws -> Void = {}

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if !raced, dstURL.lastPathComponent == "remote-code-orchestrate" {
            raced = true
            try winnerInstall()
            throw CocoaError(.fileWriteFileExists)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
