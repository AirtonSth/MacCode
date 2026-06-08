import XCTest
@testable import AgentRuntime

final class ManagedDistillCLIInstallTests: XCTestCase {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-cli-\(UUID().uuidString)", isDirectory: true)
    }

    func test_installCreatesNativeSymlink_notAPythonScript() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let binary = home.appendingPathComponent("fake/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary-content-not-python".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let installer = AgentSkillInstaller(homeDirectory: home)
        let url = try installer.installDistillCLI(appSupportDirectory: home, serviceBinaryURL: binary)

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        XCTAssertEqual(dest, binary.path, "managed distill is a symlink to the native binary")

        let content = try Data(contentsOf: url) // follows symlink
        XCTAssertFalse(String(decoding: content, as: UTF8.self).contains("#!/usr/bin/env python3"), "N1: no Python shebang")

        let result = try installer.uninstallDistillCLI()
        XCTAssertEqual(result, .removed)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
    }

    func test_installResolvesRealBuiltBinaryWhenNotProvided() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        let url = try installer.installDistillCLI(appSupportDirectory: home) // nil => resolveServiceBinary
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        XCTAssertTrue(dest.hasSuffix("RemoteCodeDistillService"), "resolves the real built service binary")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest), "the resolved target is an executable")
    }

    func test_uninstallRemovesLegacyPythonScript() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        let url = installer.distillCLIURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Simulate a pre-native managed Python CLI carrying our markers.
        let legacy = "#!/usr/bin/env python3\n\(AgentSkillInstaller.distillCLIBeginMarker)\nprint('x')\n\(AgentSkillInstaller.distillCLIEndMarker)\n"
        try Data(legacy.utf8).write(to: url)
        let result = try installer.uninstallDistillCLI()
        XCTAssertEqual(result, .removed, "legacy Python CLI is cleaned up on uninstall (migration)")
    }
}
