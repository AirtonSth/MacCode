import XCTest
import CoreModel
@testable import AgentRuntime

final class ProviderProxyInstallTests: XCTestCase {
    private func tempHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ProviderProxy-\(UUID().uuidString)", isDirectory: true)
    }

    private func fakeServiceBinary(in home: URL) throws -> URL {
        let binary = home.appendingPathComponent("fake/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    private func fakeProviderBins(in home: URL, names: [String]) throws -> URL {
        let dir = home.appendingPathComponent("provider-bins", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let path = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        return dir
    }

    func test_installProviderProxies_symlinksAllThreeWhenRealBinsExist() throws {
        // WHY: nested shell `grok|claude|codex` must resolve to the controller for every provider.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ProviderProxyCatalog.providers)
        let installer = AgentSkillInstaller(homeDirectory: home)

        let installed = try installer.installProviderProxies(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [realBins.path]
        )
        XCTAssertEqual(Set(installed), Set(ProviderProxyCatalog.providers))
        for name in ProviderProxyCatalog.providers {
            let link = home.appendingPathComponent(".remote-code/bin/\(name)")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), binary.path)
        }
        // Idempotent
        XCTAssertEqual(
            Set(try installer.installProviderProxies(
                serviceBinaryURL: binary,
                searchDirectoriesOverride: [realBins.path]
            )),
            Set(installed)
        )
    }

    func test_installAgentAppMiddleware_installsOwnershipSafeRemoteCodeAlias() throws {
        // WHY: orchestrators need one provider-neutral command that always
        // enters the host Agent App pipeline.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)

        let installed = try XCTUnwrap(installer.installAgentAppMiddleware(serviceBinaryURL: binary))
        XCTAssertEqual(installed.lastPathComponent, "remote-code")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: installed.path),
            binary.path
        )
        XCTAssertEqual(
            try installer.installAgentAppMiddleware(serviceBinaryURL: binary),
            installed,
            "reconcile must be idempotent"
        )

        let replacement = home
            .appendingPathComponent("Replacement", isDirectory: true)
            .appendingPathComponent("RemoteCodeDistillService")
        try FileManager.default.createDirectory(
            at: replacement.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: replacement.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: replacement.path
        )
        XCTAssertEqual(
            try installer.installAgentAppMiddleware(serviceBinaryURL: replacement),
            installed
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: installed.path),
            replacement.path,
            "an owned alias must follow the current app bundle after replacement"
        )
    }

    func test_installAgentAppMiddleware_preservesUserOwnedSymlink() throws {
        // WHY: reconciling a new bundle must never hijack an unrelated command
        // the user placed under the same managed directory.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let binDirectory = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true
        )
        let link = binDirectory.appendingPathComponent("remote-code")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "/usr/local/bin/user-remote-code"
        )

        XCTAssertNil(try installer.installAgentAppMiddleware(serviceBinaryURL: binary))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            "/usr/local/bin/user-remote-code"
        )
    }

    func test_installProviderProxies_neverShadowsMissingProvider() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        // Only codex exists as a real CLI.
        let realBins = try fakeProviderBins(in: home, names: ["codex"])
        let installer = AgentSkillInstaller(homeDirectory: home)
        let installed = try installer.installProviderProxies(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [realBins.path]
        )
        XCTAssertEqual(installed, ["codex"])
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: home.appendingPathComponent(".remote-code/bin/grok").path
        ))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: home.appendingPathComponent(".remote-code/bin/claude").path
        ))
    }

    func test_installProviderProxies_neverClobbersUserOwnedRegularFile() throws {
        // WHY: ownership-safe install must leave a user file in managed bin untouched.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ["grok"])
        let binDir = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let userFile = binDir.appendingPathComponent("grok")
        try Data("user owned\n".utf8).write(to: userFile)

        let installer = AgentSkillInstaller(homeDirectory: home)
        let installed = try installer.installProviderProxies(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [realBins.path]
        )
        XCTAssertFalse(installed.contains("grok"))
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "user owned\n")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: userFile.path))
    }

    func test_uninstallProviderProxies_removesOnlyOurSymlinks() throws {
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ProviderProxyCatalog.providers)
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installProviderProxies(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [realBins.path]
        )
        // User-owned regular file next to our links must survive uninstall.
        let userFile = home.appendingPathComponent(".remote-code/bin/user-tool")
        try Data("keep\n".utf8).write(to: userFile)

        let removed = try installer.uninstallProviderProxies()
        XCTAssertEqual(Set(removed), Set(ProviderProxyCatalog.providers))
        for name in ProviderProxyCatalog.providers {
            XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
                atPath: home.appendingPathComponent(".remote-code/bin/\(name)").path
            ))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
    }

    func test_uninstallCommandWrappers_doesNotRemoveProviderProxies() throws {
        // WHY: Token Saver off must drop compression wrappers, not the provider controller.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let binary = try fakeServiceBinary(in: home)
        let realBins = try fakeProviderBins(in: home, names: ["claude"])
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installProviderProxies(
            serviceBinaryURL: binary,
            searchDirectoriesOverride: [realBins.path]
        )
        // Also plant a compression wrapper.
        let lsLink = home.appendingPathComponent(".remote-code/bin/ls")
        try FileManager.default.createSymbolicLink(at: lsLink, withDestinationURL: binary)

        _ = try installer.uninstallCommandWrappers()
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: lsLink.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: home.appendingPathComponent(".remote-code/bin/claude").path
            ),
            binary.path,
            "provider proxy must survive Token Saver wrapper uninstall"
        )
    }

    func test_processLocator_skipsManagedProviderProxyForMainLaunch() throws {
        // WHY: top-level Agent App turns must not spawn through the PATH proxy.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let managed = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        let realDir = home.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

        let proxy = managed.appendingPathComponent("codex")
        let real = realDir.appendingPathComponent("codex")
        try Data("proxy".utf8).write(to: proxy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proxy.path)
        try Data("real".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)

        let path = "\(managed.path):\(realDir.path)"
        let resolved = ProcessLocator.resolve(
            "codex",
            environmentPath: path,
            homeDirectory: home.path
        )
        XCTAssertEqual(resolved, real.path, "ProcessLocator must skip managed provider proxy")
    }

    func test_processLocator_stillResolvesNonProviderFromManagedBin() throws {
        // WHY: managed distill/wrappers remain first for non-provider commands.
        let home = tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let managed = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let distill = managed.appendingPathComponent("distill")
        try Data("distill".utf8).write(to: distill)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: distill.path)

        let resolved = ProcessLocator.resolve(
            "distill",
            environmentPath: managed.path,
            homeDirectory: home.path
        )
        XCTAssertEqual(resolved, distill.path)
    }
}
