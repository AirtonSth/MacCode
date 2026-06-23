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

    func test_resolveServiceBinaryFindsSwiftPMPlatformTripleBuildDirectory() throws {
        let root = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent(".build/arm64-apple-macosx/debug/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let original = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(root.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(original) }

        XCTAssertEqual(
            AgentSkillInstaller.resolveServiceBinary()?.resolvingSymlinksInPath().path,
            binary.resolvingSymlinksInPath().path,
            "SwiftPM on modern macOS places executable products under .build/<platform-triple>/debug, not .build/debug"
        )
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

    // MARK: - RTK transparent command wrappers

    private func fakeServiceBinary(in home: URL) throws -> URL {
        let binary = home.appendingPathComponent("fake/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    func test_installCommandWrappers_symlinksExistingCommandsToServiceBinary() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)

        let installed = try installer.installCommandWrappers(serviceBinaryURL: binary)
        // cat and ls exist on every macOS system, so they must be wrapped and point at our binary.
        XCTAssertTrue(installed.contains("cat") && installed.contains("ls"))
        for command in ["cat", "ls"] {
            let link = home.appendingPathComponent(".remote-code/bin/\(command)")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), binary.path)
        }
        // Idempotent: a second install keeps the same links, no throw.
        XCTAssertEqual(Set(try installer.installCommandWrappers(serviceBinaryURL: binary)), Set(installed))

        let removed = try installer.uninstallCommandWrappers()
        XCTAssertTrue(removed.contains("cat") && removed.contains("ls"))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".remote-code/bin/cat").path))
    }

    func test_installCommandWrappers_neverShadowsAMissingCommand() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let installed = try installer.installCommandWrappers(serviceBinaryURL: binary)
        // Only commands that actually resolve on the system are wrapped; a wrapper is never
        // created for an absent command (which would then fail with "command not found").
        for command in installed {
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".remote-code/bin/\(command)").path))
        }
    }

    func test_uninstallCommandWrappers_leavesAUserOwnedFileUntouched() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binDir = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // A real (non-symlink) file the user placed at our managed path for `cat`.
        let userFile = binDir.appendingPathComponent("cat")
        try Data("not ours".utf8).write(to: userFile)
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.uninstallCommandWrappers()
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path), "a non-symlink we did not create must never be removed")
    }
}
