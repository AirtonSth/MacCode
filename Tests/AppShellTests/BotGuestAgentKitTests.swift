import XCTest
import CryptoKit
import CoreModel
@testable import AppShell

/// The agent kit is what the Mac relies on to start, find and stop an in-guest
/// agent run. Its run-time behaviour (tagging, session/descendant kill, lease
/// reaper) needs Linux /proc and is proven in a throwaway container; these
/// tests pin what the Mac side controls: what lands in guest-tools, with which
/// modes, how it is replaced, and that malformed input is refused.
final class BotGuestAgentKitTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-kit-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private var tools: URL { BotComputerGuestSpec.guestToolsURL(appSupport: support) }

    private func kitSource() throws -> URL {
        try XCTUnwrap(AppShellResourceBundle.guestAgentKitURL(), "GuestAgentKit resource must resolve")
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func inode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    func test_materialize_copiesEveryKitFileWithGuestModes_andKeepsTheDistillCache() throws {
        // The distill cache shares guest-tools; materializing must not wipe a 220 MB download.
        let cached = tools.appendingPathComponent("distill/2.0.31/distill-linux-aarch64")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: cached)

        try BotGuestAgentKit.materialize(appSupport: support)

        let source = try kitSource()
        for file in BotGuestAgentKit.files {
            let target = tools.appendingPathComponent(file.path)
            XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: source.appendingPathComponent(file.path)), file.path)
            // The read-only bind keeps host modes: the guest can only exec what is 0755 here.
            XCTAssertEqual(try mode(target), file.mode, file.path)
        }
        XCTAssertEqual(try Data(contentsOf: cached), Data("binary".utf8))
    }

    func test_materialize_leavesCurrentFilesAlone_andReplacesStaleOnesByRename() throws {
        try BotGuestAgentKit.materialize(appSupport: support)
        let killAgent = tools.appendingPathComponent("bin/kill-agent")
        let unchanged = try inode(killAgent)
        try BotGuestAgentKit.materialize(appSupport: support)
        XCTAssertEqual(try inode(killAgent), unchanged, "a current file is not rewritten on every provision")

        // A kit from an older app version, or a mode someone changed.
        try Data("#!/bin/bash\necho old\n".utf8).write(to: killAgent)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: killAgent.path)
        let stale = try inode(killAgent)
        try BotGuestAgentKit.materialize(appSupport: support)

        XCTAssertEqual(try Data(contentsOf: killAgent), try Data(contentsOf: try kitSource().appendingPathComponent("bin/kill-agent")))
        XCTAssertEqual(try mode(killAgent), 0o755)
        // bash reads a script while it runs (the lease reaper loops in kill-agent);
        // rewriting it in place would corrupt a live reaper, a rename does not.
        XCTAssertNotEqual(try inode(killAgent), stale, "replaced by rename, never rewritten in place")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: killAgent.deletingLastPathComponent().path)
        XCTAssertEqual(Set(leftovers), ["kill-agent", "run-agent"], "no temporary files left behind")
    }

    func test_materialize_failsLoudWhenTheKitIsMissing() {
        XCTAssertThrowsError(try BotGuestAgentKit.materialize(appSupport: support, source: nil)) { error in
            XCTAssertEqual(error as? BotGuestAgentKit.Failure, .missingKit)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tools.appendingPathComponent("bin").path))
    }

    func test_bundledKit_holdsExactlyTheMaterializedFiles() throws {
        // A file added to the resource but not to `files` would never reach the guest;
        // the linux-use Chrome extension must not ship in the guest kit at all.
        let source = try kitSource()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]))
        var found = Set<String>()
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            found.insert(String(url.standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count + 1)))
        }
        XCTAssertEqual(found, Set(BotGuestAgentKit.files.map(\.path)))
    }

    func test_vendoredLinuxUse_isTheRecordedUpstreamCommitUnmodified() throws {
        let source = try kitSource()
        let upstream = try String(contentsOf: source.appendingPathComponent("linux-use/UPSTREAM"), encoding: .utf8)
        XCTAssertTrue(upstream.contains("commit ee0231ce80c56bbeec2daa68363c9e4477a4a923"))
        let server = try Data(contentsOf: source.appendingPathComponent("linux-use/server.py"))
        let digest = SHA256.hash(data: server).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(upstream.contains("server.py sha256 \(digest)"), "server.py differs from the recorded upstream copy")
    }

    func test_scripts_useTheSpecPathsTheMacWrites() throws {
        // The Mac renews leases where the reaper reads them; a mismatch reaps every run after 45 s.
        let source = try kitSource()
        let killAgent = try String(contentsOf: source.appendingPathComponent("bin/kill-agent"), encoding: .utf8)
        XCTAssertTrue(killAgent.contains("lease_dir=\(BotComputerGuestSpec.agentLeaseDirectory)\n"))
        XCTAssertTrue(BotComputerGuestSpec.runAgentPath.hasPrefix(BotComputerGuestSpec.agentKitMountPoint + "/"))
        XCTAssertEqual(BotComputerGuestSpec.runAgentPath, "/opt/remotecode-agent/bin/run-agent")
        XCTAssertEqual(BotComputerGuestSpec.killAgentPath, "/opt/remotecode-agent/bin/kill-agent")
        XCTAssertEqual(BotComputerGuestSpec.linuxUseServerPath, "/opt/remotecode-agent/linux-use/server.py")
    }

    // MARK: - Input validation (runs the real scripts; refused before any Linux-only step)

    private func run(_ script: String, _ arguments: [String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        // Each script's own shebang interpreter (sh for run-agent, bash for kill-agent).
        process.executableURL = URL(fileURLWithPath: script == "run-agent" ? "/bin/sh" : "/bin/bash")
        process.arguments = [try kitSource().appendingPathComponent("bin/\(script)").path] + arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, message)
    }

    func test_runAgent_refusesMalformedRunIDsAndArguments() throws {
        // The run id names the pid file and the lease path: it must never be a path.
        let valid = AgentRunID().description
        let refused: [[String]] = [
            [],
            ["", "--", "true"],
            ["../../../../etc/passwd-0000000000000", "--", "true"],
            [String(valid.dropLast()), "--", "true"],
            [String(valid.dropLast()) + "/", "--", "true"],
            [valid, "true"],
            [valid, "--"],
        ]
        for arguments in refused {
            let result = try run("run-agent", arguments)
            XCTAssertEqual(result.status, 64, "\(arguments)")
            XCTAssertTrue(result.stderr.contains("usage: run-agent"), "\(arguments)")
        }
    }

    func test_killAgent_refusesMalformedArguments() throws {
        let valid = AgentRunID().description
        let refused: [[String]] = [
            [],
            ["../../tmp/x-00000000000000000000000000000"],
            [valid, valid],
            ["--all", valid],
            ["--reap"],
            ["--reap", "not-a-run"],
        ]
        for arguments in refused {
            let result = try run("kill-agent", arguments)
            XCTAssertEqual(result.status, 64, "\(arguments)")
            XCTAssertTrue(result.stderr.contains("usage: kill-agent"), "\(arguments)")
        }
    }
}
