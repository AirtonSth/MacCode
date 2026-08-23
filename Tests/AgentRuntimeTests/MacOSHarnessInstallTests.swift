import XCTest
import CoreModel
@testable import AgentRuntime

final class MacOSHarnessInstallTests: XCTestCase {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-native-host-install-\(UUID().uuidString)", isDirectory: true)
    }

    func test_runtimeNoLongerInstallsExternalHostHarness() throws {
        // WHY: native host control must be shipped by RemoteCode; a provider
        // run must remove only the old managed harness artifacts.
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        let managedSource = "https://github.com/browser-use/" + AgentSkillInstaller.legacyExternalHostSkillID
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for provider in AgentProvider.allCases {
            let directory = installer.skillDirectory(
                provider: provider,
                skillID: AgentSkillInstaller.legacyExternalHostSkillID
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("legacy".utf8).write(to: directory.appendingPathComponent("SKILL.md"))
            let manifest = AgentSkillManifest(
                provider: provider,
                skillID: AgentSkillInstaller.legacyExternalHostSkillID,
                sourceURL: managedSource,
                sourceRevision: "0.1.2",
                localVersion: "1",
                sha256: AgentSkillInstaller.sha256Hex(Data("legacy".utf8)),
                installPath: directory.appendingPathComponent("SKILL.md").path,
                installedAt: Date()
            )
            try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        }
        let userSkill = installer.skillDirectory(
            provider: .claude,
            skillID: AgentSkillInstaller.legacyExternalHostSkillID
        ).appendingPathComponent("user.txt")
        // Replace the managed Claude directory with a user-owned copy; cleanup
        // must not delete a same-named skill without RemoteCode metadata.
        try FileManager.default.removeItem(at: userSkill.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: userSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user".utf8).write(to: userSkill)

        let external = home.appendingPathComponent("external/macos-harness")
        try FileManager.default.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: external)
        try FileManager.default.createDirectory(at: installer.managedCLIBinURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: installer.managedCLIBinURL.appendingPathComponent(AgentSkillInstaller.legacyExternalHostSkillID),
            withDestinationURL: external
        )
        try installer.uninstallLegacyExternalHostArtifacts()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.skillDirectory(provider: .codex, skillID: AgentSkillInstaller.legacyExternalHostSkillID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userSkill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.managedCLIBinURL.appendingPathComponent(AgentSkillInstaller.legacyExternalHostSkillID).path))
    }

    func test_installComputerUseMCPIsIdempotentAndPreservesUserServers() throws {
        // WHY: provider-global config remains a compatibility utility, but it
        // must only ever contain RemoteCode's bundled MCP and user entries.
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("bin/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"other":{"command":"x"}}}"#.utf8).write(to: claudeSettings)
        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installComputerUseMCP(serviceBinaryURL: binary)
        try installer.installComputerUseMCP(serviceBinaryURL: binary)

        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
        let servers = try XCTUnwrap(settings["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        XCTAssertEqual(
            (servers[ComputerUseMCPAdmit.serverName] as? [String: Any])?["command"] as? String,
            binary.path
        )
    }
}
