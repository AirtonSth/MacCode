import Foundation
import XCTest

final class CanaryAppScriptTests: XCTestCase {
    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var harnessURL: URL {
        repositoryRoot.appendingPathComponent("scripts/canary-app.sh")
    }

    private func temporaryCanaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCodeAgentCanary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func writeFakePackager(under root: URL) throws -> URL {
        let packager = root.appendingPathComponent("fake-package-app.sh")
        let source = #"""
        #!/usr/bin/env bash
        set -euo pipefail
        app="${RC2_PACKAGE_APP_OUTPUT:?}"
        mkdir -p "$app/Contents/MacOS"
        cat > "$app/Contents/Info.plist" <<PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>CFBundleDisplayName</key><string>RemoteCode</string>
          <key>CFBundleExecutable</key><string>RemoteCode</string>
          <key>CFBundleIdentifier</key><string>${RC2_BUNDLE_ID:?}</string>
          <key>CFBundleName</key><string>RemoteCode</string>
          <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        PLIST
        /usr/bin/xcrun clang -x c -o "$app/Contents/MacOS/RemoteCode" - <<'C'
        #include <signal.h>
        #include <unistd.h>
        static volatile sig_atomic_t running = 1;
        static void stop(int signal) { (void)signal; running = 0; }
        int main(void) {
          signal(SIGTERM, stop);
          signal(SIGINT, stop);
          while (running) pause();
          return 0;
        }
        C
        """#
        try source.write(to: packager, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packager.path)
        return packager
    }

    @discardableResult
    private func run(_ command: String, root: URL, packager: URL? = nil) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [harnessURL.path, command]
        var environment = ProcessInfo.processInfo.environment
        environment["RC2_CANARY_ROOT"] = root.path
        if let packager {
            environment["RC2_CANARY_PACKAGE_SCRIPT"] = packager.path
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(status: process.terminationStatus, output: output)
    }

    func testHarnessContractForbidsBroadProcessKills() throws {
        let source = try String(contentsOf: harnessURL, encoding: .utf8)

        XCTAssertFalse(source.contains("pkill"),
                       "the canary harness must never kill stable RemoteCode processes by shared process name")
        for command in ["build", "run", "stop", "status", "reset-state"] {
            XCTAssertTrue(source.contains(command), "the harness must expose the \(command) command")
        }
    }

    func testBuildRunStatusAndStopUseIsolatedCanaryIdentity() throws {
        let root = try temporaryCanaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packager = try writeFakePackager(under: root)
        defer { try? run("stop", root: root, packager: packager) }

        let build = try run("build", root: root, packager: packager)
        XCTAssertEqual(build.status, 0, build.output)

        let app = root.appendingPathComponent("app/RemoteCodeAgentCanary.app")
        let executable = app.appendingPathComponent("Contents/MacOS/RemoteCodeAgentCanary")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path),
                      "the canary must use its own executable name instead of RemoteCode")
        let plistData = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "io.remotecode.desktop.agent-canary")
        XCTAssertEqual(plist["CFBundleName"] as? String, "RemoteCodeAgentCanary")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "RemoteCodeAgentCanary")

        let start = try run("run", root: root, packager: packager)
        XCTAssertEqual(start.status, 0, start.output)
        let status = try run("status", root: root, packager: packager)
        XCTAssertEqual(status.status, 0, status.output)
        XCTAssertTrue(status.output.contains(executable.path),
                      "status must identify the exact canary executable, not a shared process name")

        let stop = try run("stop", root: root, packager: packager)
        XCTAssertEqual(stop.status, 0, stop.output)
        XCTAssertNotEqual(try run("status", root: root, packager: packager).status, 0)
    }

    func testResetStateDeletesOnlyValidatedCanaryState() throws {
        let root = try temporaryCanaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state/Application Support/RemoteCodeAgentCanary")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("keep app outside state".utf8).write(to: root.appendingPathComponent("outside.txt"))
        try Data("delete state".utf8).write(to: state.appendingPathComponent("RemoteCode.sqlite"))

        let reset = try run("reset-state", root: root)
        XCTAssertEqual(reset.status, 0, reset.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path),
                      "reset-state must not delete siblings outside the validated state directory")

        let unsafeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsafe-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: unsafeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unsafeRoot) }
        let sentinel = unsafeRoot.appendingPathComponent("sentinel")
        try Data("must survive".utf8).write(to: sentinel)
        let rejected = try run("reset-state", root: unsafeRoot)
        XCTAssertNotEqual(rejected.status, 0, "reset-state must reject roots without the canary identity marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
}
