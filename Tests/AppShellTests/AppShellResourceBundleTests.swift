import XCTest
@testable import AppShell

/// WHY: Customer launch crash (v2.0.63/v2.0.64) was EXC_BREAKPOINT in
/// SPM `Bundle.module` when the AppShell resource bundle lived only under
/// Contents/Resources. These tests lock the packaged-layout lookup that
/// `PetAtlas.bundled()` uses so a missing Resources path fails as a
/// catchable error, never a process-aborting fatalError.
final class AppShellResourceBundleTests: XCTestCase {

    func test_locate_findsContentsResourcesLayout() throws {
        let root = try makeTempApp(withResourcesMirror: true, withAppRootMirror: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let main = try XCTUnwrap(Bundle(path: root.path))
        // Disable SPM fallback so a local .build product cannot mask packaged-path preference.
        let found = AppShellResourceBundle.locate(main: main, includeSwiftPMFallback: false)
        XCTAssertNotNil(found, "must resolve Contents/Resources/RemoteCode_AppShell.bundle")
        XCTAssertTrue(
            found!.bundlePath.hasSuffix("Contents/Resources/RemoteCode_AppShell.bundle"),
            "preferred path is the canonical Resources layout, got \(found!.bundlePath)"
        )
    }

    func test_locate_findsAppRootMirrorWhenResourcesMissing() throws {
        let root = try makeTempApp(withResourcesMirror: false, withAppRootMirror: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let main = try XCTUnwrap(Bundle(path: root.path))
        let found = AppShellResourceBundle.locate(main: main, includeSwiftPMFallback: false)
        XCTAssertNotNil(found, "must resolve app-root RemoteCode_AppShell.bundle mirror")
        XCTAssertTrue(
            found!.bundlePath.hasSuffix("/RemoteCode_AppShell.bundle"),
            "got \(found!.bundlePath)"
        )
        XCTAssertFalse(
            found!.bundlePath.contains("/Contents/Resources/"),
            "this fixture only has the app-root mirror"
        )
    }

    func test_locate_returnsNilWhenBothLayoutsMissing() throws {
        let root = try makeTempApp(withResourcesMirror: false, withAppRootMirror: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let main = try XCTUnwrap(Bundle(path: root.path))
        XCTAssertNil(
            AppShellResourceBundle.locate(main: main, includeSwiftPMFallback: false),
            "empty package must not invent a bundle (and must not fatalError)"
        )
    }

    func test_bundle_throwsCatchableErrorWhenMissing() {
        // Intentionally use a path that cannot contain our resource bundle,
        // and disable the SPM .build fallback so the throw is deterministic.
        let bogus = Bundle(path: "/System")!
        XCTAssertThrowsError(
            try AppShellResourceBundle.bundle(mainOverride: bogus, includeSwiftPMFallback: false)
        ) { error in
            XCTAssertEqual(error as? PetAtlasError, .missingResource(AppShellResourceBundle.bundleFileName))
        }
    }

    func test_locate_prefersContentsResourcesOverAppRoot() throws {
        let root = try makeTempApp(withResourcesMirror: true, withAppRootMirror: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let main = try XCTUnwrap(Bundle(path: root.path))
        let found = try XCTUnwrap(
            AppShellResourceBundle.locate(main: main, includeSwiftPMFallback: false)
        )
        XCTAssertTrue(
            found.bundlePath.contains("/Contents/Resources/RemoteCode_AppShell.bundle"),
            "canonical Resources path must win when both mirrors exist; got \(found.bundlePath)"
        )
    }

    func test_computerGuestRecipeURL_findsDockerfile() throws {
        // WHY: BotsViewModel must pass this URL into proveReady so Studio
        // can build the base image without Bundle.module.
        let recipe = try XCTUnwrap(AppShellResourceBundle.computerGuestRecipeURL())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recipe.appendingPathComponent("Dockerfile").path)
        )
        let dockerfile = try String(
            contentsOf: recipe.appendingPathComponent("Dockerfile"),
            encoding: .utf8
        )
        XCTAssertTrue(dockerfile.lowercased().contains("debian"))
        XCTAssertFalse(dockerfile.lowercased().contains("alpine"))
    }

    @MainActor
    func test_bundledAtlas_loadsFromResolvedBundle() throws {
        // Live unit-test environment: SPM product layout under .build must resolve.
        let atlas = try PetAtlas.bundled()
        XCTAssertEqual(atlas.manifest.schemaVersion, 3)
        XCTAssertFalse(atlas.manifest.rows.isEmpty)
    }

    func test_packageScriptUsesContentsResourcesOnly() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/package-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(
            script.contains("Contents/Resources/RemoteCode_AppShell.bundle"),
            "package-app must ship AppShell resources under Contents/Resources"
        )
        // App-root copies break codesign ("unsealed contents present in the bundle root").
        XCTAssertFalse(
            script.contains("STAGING_APP/RemoteCode_AppShell.bundle\""),
            "package-app must not place resource bundles at the .app root"
        )
        XCTAssertTrue(
            script.contains("AppShellResourceBundle"),
            "package-app must document the Bundle.module ban / AppShellResourceBundle requirement"
        )
        XCTAssertTrue(
            script.contains("check-app-bundle.sh"),
            "package-app must invoke the structural gate before signing"
        )
    }

    func test_checkAppBundleForbidsAppRootResourceBundles() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/check-app-bundle.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(
            script.contains("unsealed app-root bundle"),
            "CI structural gate must reject app-root resource bundles that break codesign"
        )
        XCTAssertTrue(
            script.contains("launch crash class"),
            "the failure message must name the launch-crash regression class"
        )
    }

    /// WHY: Claude Agent SDK bridge must ship under Contents/Resources (Airton
    /// CI-path bake-in class). Contract-test the packaging scripts like Pet.
    func test_packageScriptsShipClaudeAgentSDKBridge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageApp = try String(
            contentsOf: root.appendingPathComponent("scripts/package-app.sh"),
            encoding: .utf8
        )
        let checkBundle = try String(
            contentsOf: root.appendingPathComponent("scripts/check-app-bundle.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(
            packageApp.contains("Contents/Resources/ClaudeAgentSDKBridge.mjs"),
            "package-app must copy ClaudeAgentSDKBridge.mjs into Contents/Resources"
        )
        XCTAssertTrue(
            packageApp.contains("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs"),
            "package-app must source the bridge from AgentRuntime sources"
        )
        XCTAssertTrue(
            checkBundle.contains("ClaudeAgentSDKBridge.mjs"),
            "check-app-bundle must fail closed when the Claude bridge is missing"
        )
        XCTAssertTrue(
            checkBundle.contains("Claude provider fails on customer machines"),
            "missing-bridge failure message must name the customer impact class"
        )
    }

    // MARK: - fixtures

    private func makeTempApp(withResourcesMirror: Bool, withAppRootMirror: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCode-resource-bundle-test-\(UUID().uuidString).app", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)

        if withResourcesMirror {
            let bundle = resources.appendingPathComponent("RemoteCode_AppShell.bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Pet", isDirectory: true), withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        }

        if withAppRootMirror {
            let bundle = root.appendingPathComponent("RemoteCode_AppShell.bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Pet", isDirectory: true), withIntermediateDirectories: true)
        }

        // Minimal Info.plist so Bundle(path:) accepts the fake .app
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>io.remotecode.test.resourcebundle</string>
          <key>CFBundleExecutable</key><string>RemoteCode</string>
          <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        // Dummy executable so Bundle.main.executableURL style paths can exist if needed
        try Data().write(to: macos.appendingPathComponent("RemoteCode"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macos.appendingPathComponent("RemoteCode").path)
        return root
    }
}

// Test-only hook so we can inject a fake main bundle without touching process global state.
extension AppShellResourceBundle {
    static func bundle(mainOverride: Bundle, includeSwiftPMFallback: Bool = true) throws -> Bundle {
        if let found = locate(main: mainOverride, includeSwiftPMFallback: includeSwiftPMFallback) {
            return found
        }
        throw PetAtlasError.missingResource(bundleFileName)
    }
}
