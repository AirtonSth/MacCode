import XCTest
import CoreModel
@testable import AgentRuntime

/// WHY: Default must never create `graphify-out/` in the user's working tree.
/// App Support is the sole output root unless writeInRepo is explicitly enabled.
final class GraphifyOutputLocationTests: XCTestCase {
    private var tempRoot: URL!
    private var service: GraphifyWorkspaceService!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphify-outloc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        service = GraphifyWorkspaceService(appSupportDirectory: tempRoot.appendingPathComponent("app-support"))
        service.enabled = true
        service.autoEnsure = false
        service.writeInRepo = false
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func test_defaultWriteInRepoFalse_usesAppSupportAndLeavesRepoClean() throws {
        let graphify = "/Users/samuelfajreldines/.local/bin/graphify"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: graphify), "graphify CLI required")
        service.binaryPathOverride = graphify

        let repo = try makeGitRepo(named: "clean-repo")
        guard let id = GraphifyGitProbe.identity(at: repo.path) else { return XCTFail("identity") }

        service.writeInRepo = false
        let status = service.ensureSync(checkout: id.checkout, mode: .update)
        XCTAssertEqual(status, .fresh)

        let artifactGraph = service.graphJSONPath(for: id.checkout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactGraph.path), "graph must live in App Support artifact root")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repo.appendingPathComponent("graphify-out").path),
            "default must NOT create graphify-out in the user repository"
        )
        XCTAssertGreaterThan((try Data(contentsOf: artifactGraph)).count, 50)
    }

    func test_writeInRepoTrue_createsRepoGraphifyOutAndMirrorsArtifact() throws {
        let graphify = "/Users/samuelfajreldines/.local/bin/graphify"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: graphify), "graphify CLI required")
        service.binaryPathOverride = graphify

        let repo = try makeGitRepo(named: "pollute-ok")
        guard let id = GraphifyGitProbe.identity(at: repo.path) else { return XCTFail("identity") }

        service.writeInRepo = true
        let status = service.ensureSync(checkout: id.checkout, mode: .update)
        XCTAssertEqual(status, .fresh)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: repo.appendingPathComponent("graphify-out/graph.json").path),
            "opt-in must write graphify-out inside the project"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: service.graphJSONPath(for: id.checkout).path),
            "artifact mirror must still exist for stable agent paths"
        )
    }

    func test_envGraphifyOutIsSetWhenNotWriteInRepo() throws {
        var capturedEnv: [String: String]?
        var called = false
        let fake = tempRoot.appendingPathComponent("fake-bin")
        try "#!/bin/sh\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        service.binaryPathOverride = fake.path

        service.runProcess = { args, cwd, env in
            // Only capture the graphify update invocation (git HEAD probes share runProcess).
            if args.contains("update") {
                called = true
                capturedEnv = env
                if let out = env?["GRAPHIFY_OUT"] {
                    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
                    try? "{\"nodes\":[]}".write(
                        toFile: (out as NSString).appendingPathComponent("graph.json"),
                        atomically: true,
                        encoding: .utf8
                    )
                }
            }
            if args.contains("rev-parse") {
                return (0, "deadbeef\n", "")
            }
            return (0, "", "")
        }
        service.writeInRepo = false
        let proj = tempRoot.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: tempRoot.appendingPathComponent("c.git").path),
            displayRoot: proj.path
        )
        let status = service.ensureSync(checkout: checkout, mode: .update)
        XCTAssertTrue(called, "runProcess must be invoked")
        XCTAssertEqual(status, .fresh)
        XCTAssertEqual(capturedEnv?["GRAPHIFY_OUT"], service.artifactRoot(for: checkout).path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: proj.appendingPathComponent("graphify-out").path))
    }

    private func makeGitRepo(named: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(named, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        func run(_ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args
            p.currentDirectoryURL = url
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        XCTAssertEqual(run(["git", "init"]), 0)
        XCTAssertEqual(run(["git", "config", "user.email", "t@example.com"]), 0)
        XCTAssertEqual(run(["git", "config", "user.name", "T"]), 0)
        try "export const z = 1\n".write(to: url.appendingPathComponent("z.ts"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(["git", "add", "."]), 0)
        XCTAssertEqual(run(["git", "commit", "-m", "i"]), 0)
        return url.standardizedFileURL
    }
}
