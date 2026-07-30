import XCTest
@testable import AgentRuntime

/// WHY: Customer launch crash (v2.0.85–v2.0.87) was EXC_BREAKPOINT in SPM
/// `Bundle.module` when `reconcileRemoteCodeOrchestrate` ran in a packaged app:
/// the generated accessor only checks the .app root and a hardcoded builder
/// `.build` path, then fatalErrors, and package-app.sh never shipped
/// RemoteCode_AgentRuntime.bundle. These tests lock the packaged-layout lookup
/// (with the SPM fallback disabled, so a local .build product cannot mask a
/// packaging regression the way it masked the original defect) and the
/// packaging/check gates that keep the bundle in the .app.
final class AgentRuntimeResourceBundleTests: XCTestCase {

    func test_locate_findsContentsResourcesLayout() throws {
        let root = try makeTempApp(withResourcesMirror: true, withAppRootMirror: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let main = try XCTUnwrap(Bundle(path: root.path))
        let found = AgentRuntimeResourceBundle.locate(main: main, includeSwiftPMFallback: false)
        XCTAssertNotNil(found, "must resolve Contents/Resources/RemoteCode_AgentRuntime.bundle")
        XCTAssertTrue(
            found!.bundlePath.hasSuffix("Contents/Resources/RemoteCode_AgentRuntime.bundle"),
            "preferred path is the canonical Resources layout, got \(found!.bundlePath)"
        )
        XCTAssertNotNil(
            found!.url(forResource: "remote-code-orchestrate", withExtension: nil),
            "resolved bundle must expose the embedded skill directory"
        )
    }

    func test_locate_prefersContentsResourcesOverAppRoot() throws {
        let root = try makeTempApp(withResourcesMirror: true, withAppRootMirror: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let main = try XCTUnwrap(Bundle(path: root.path))
        let found = try XCTUnwrap(
            AgentRuntimeResourceBundle.locate(main: main, includeSwiftPMFallback: false)
        )
        XCTAssertTrue(
            found.bundlePath.contains("/Contents/Resources/RemoteCode_AgentRuntime.bundle"),
            "canonical Resources path must win when both mirrors exist; got \(found.bundlePath)"
        )
    }

    /// The scheduled-task LaunchAgent executable lives directly under
    /// Contents/Resources (BundleProgram), so its Bundle.main resolves to that
    /// directory, not Contents/MacOS. On v2.0.85–v2.0.87 the agent crash-looped
    /// under launchd KeepAlive through the same Bundle.module abort.
    func test_locate_resolvesScheduledTaskAgentGeometry() throws {
        let root = try makeTempApp(withResourcesMirror: true, withAppRootMirror: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let resourcesDir = root
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let main = try XCTUnwrap(Bundle(path: resourcesDir.path))
        let found = AgentRuntimeResourceBundle.locate(main: main, includeSwiftPMFallback: false)
        XCTAssertNotNil(
            found,
            "agent-geometry main bundle (Contents/Resources) must resolve the sibling bundle"
        )
        XCTAssertTrue(
            found!.bundlePath.hasSuffix("Contents/Resources/RemoteCode_AgentRuntime.bundle"),
            "got \(found!.bundlePath)"
        )
    }

    func test_locate_returnsNilWhenBundleMissing() throws {
        let root = try makeTempApp(withResourcesMirror: false, withAppRootMirror: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let main = try XCTUnwrap(Bundle(path: root.path))
        XCTAssertNil(
            AgentRuntimeResourceBundle.locate(main: main, includeSwiftPMFallback: false),
            "empty package must not invent a bundle (and must not fatalError)"
        )
    }

    func test_bundle_throwsCatchableErrorWhenMissing() {
        // Intentionally use a path that cannot contain our resource bundle,
        // and disable the SPM .build fallback so the throw is deterministic.
        let bogus = Bundle(path: "/System")!
        XCTAssertThrowsError(
            try AgentRuntimeResourceBundle.bundle(main: bogus, includeSwiftPMFallback: false)
        ) { error in
            XCTAssertEqual(
                error as? AgentRuntimeResourceBundleError,
                .missingResource(AgentRuntimeResourceBundle.bundleFileName)
            )
        }
    }

    func test_bundle_resolvesUnderSwiftTestViaSwiftPMFallback() throws {
        // Live unit-test environment: SPM product layout under .build must resolve
        // so reconcile keeps working in tests. The selected bundle must be the
        // active product, not a stale Xcode index-build resource copy.
        let bundle = try AgentRuntimeResourceBundle.bundle()
        let embedded = try XCTUnwrap(
            bundle.url(forResource: "remote-code-orchestrate", withExtension: nil),
            "SPM fallback must expose the embedded orchestrate package"
        )
        let package = AgentSkillInstaller.remoteCodeOrchestratePinnedPackage
        let files = try package.allowedPaths.map { relativePath in
            let data = try Data(contentsOf: embedded.appendingPathComponent(relativePath))
            return RemoteCodeOrchestrateFile(
                relativePath: relativePath,
                byteCount: data.count,
                sha256: AgentSkillInstaller.sha256Hex(data)
            )
        }
        XCTAssertEqual(
            AgentSkillInstaller.remoteCodeOrchestrateTreeDigest(files),
            package.sourceTreeSHA256,
            "SwiftPM fallback must not select a stale copied resource bundle"
        )
    }

    /// The regression class guard: no executable Bundle.module use may exist in
    /// shipped Sources/ — its SPM accessor fatalErrors on customer machines.
    /// Comment mentions (the ban documentation itself) are allowed.
    func test_sourcesContainNoExecutableBundleModuleUse() throws {
        let sourcesRoot = packageRoot().appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let content = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in content.components(separatedBy: "\n").enumerated() {
                guard line.contains("Bundle.module") else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1): \(trimmed)")
            }
        }
        XCTAssertEqual(
            offenders, [],
            "Bundle.module fatalErrors in packaged apps; use AppShellResourceBundle/AgentRuntimeResourceBundle"
        )
    }

    func test_packageScriptShipsFirstPartyResourceBundles() throws {
        let script = try String(
            contentsOf: packageRoot().appendingPathComponent("scripts/package-app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(
            script.contains(#"for resource_bundle in "$BIN_DIR"/RemoteCode_*.bundle"#),
            "package-app must glob-copy every first-party resource bundle"
        )
        XCTAssertTrue(
            script.contains("*Tests.bundle) continue"),
            "package-app must exclude SwiftPM test bundles from the glob"
        )
        XCTAssertTrue(
            script.contains("Contents/Resources/RemoteCode_AgentRuntime.bundle"),
            "package-app must fail closed when the AgentRuntime bundle is missing"
        )
        XCTAssertTrue(
            script.contains("AgentRuntimeResourceBundle"),
            "package-app must document the Bundle.module ban for AgentRuntime"
        )
    }

    func test_checkAppBundleAssertsAgentRuntimeBundleContents() throws {
        let script = try String(
            contentsOf: packageRoot().appendingPathComponent("scripts/check-app-bundle.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(
            script.contains("RemoteCode_AgentRuntime.bundle"),
            "structural gate must assert the AgentRuntime bundle ships"
        )
        XCTAssertTrue(
            script.contains("remote-code-orchestrate/SKILL.md"),
            "structural gate must assert the orchestrate skill content, not just the bundle dir"
        )
        XCTAssertTrue(
            script.contains(".DS_Store"),
            "structural gate must reject entries the pinned source validation would refuse"
        )
        let package = AgentSkillInstaller.remoteCodeOrchestratePinnedPackage
        XCTAssertTrue(
            script.contains(
                #"ORCHESTRATE_EXPECTED_TREE_SHA256="\#(package.sourceTreeSHA256)""#
            ),
            "bundle gate digest must match the v\(package.localVersion) compiled package pin"
        )
        for relativePath in package.allowedPaths {
            XCTAssertTrue(
                script.contains(#""\#(relativePath)""#),
                "bundle gate must include pinned path \(relativePath)"
            )
        }
        XCTAssertTrue(
            script.contains("exact eight-file pinned tree"),
            "bundle gate must reject mixed, stale, missing, and extra resource trees"
        )
        XCTAssertTrue(
            script.contains("RemoteCode_Surfaces.bundle\""),
            "structural gate must assert Surfaces resources ship (copy is glob-driven)"
        )
    }

    // MARK: - fixtures

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeTempApp(withResourcesMirror: Bool, withAppRootMirror: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCode-agentruntime-bundle-test-\(UUID().uuidString).app", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        if withResourcesMirror {
            try writeBundleFixture(at: resources.appendingPathComponent("RemoteCode_AgentRuntime.bundle", isDirectory: true))
        }
        if withAppRootMirror {
            try writeBundleFixture(at: root.appendingPathComponent("RemoteCode_AgentRuntime.bundle", isDirectory: true))
        }

        // Minimal Info.plist so Bundle(path:) accepts the fake .app
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>io.remotecode.test.agentruntimebundle</string>
          <key>CFBundleExecutable</key><string>RemoteCode</string>
          <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try Data().write(to: macos.appendingPathComponent("RemoteCode"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macos.appendingPathComponent("RemoteCode").path)
        return root
    }

    private func writeBundleFixture(at bundle: URL) throws {
        let skill = bundle.appendingPathComponent("remote-code-orchestrate", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("# fixture\n".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
    }
}
