import XCTest
import CoreModel
@testable import AgentRuntime

/// WHY: ArtifactRoot must be unique per commonDir; binary missing is fail-open unavailable;
/// real `graphify update` must produce a canonical graph.json when CLI is present.
final class GraphifyWorkspaceServiceTests: XCTestCase {
    private var tempRoot: URL!
    private var service: GraphifyWorkspaceService!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphify-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        service = GraphifyWorkspaceService(appSupportDirectory: tempRoot.appendingPathComponent("graphs"))
        service.enabled = true
        service.autoEnsure = false
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        service = nil
    }

    func test_artifactRootStableForSameCheckout() {
        let key = GraphifyRepoKey(commonDir: "/repo/.git")
        let checkout = GraphifyCheckout(key: key, displayRoot: "/repo")
        let a = service.artifactRoot(for: checkout)
        let b = service.artifactRoot(for: GraphifyCheckout(key: key, displayRoot: "/repo"))
        XCTAssertEqual(a.path, b.path)
        XCTAssertTrue(a.path.contains(checkout.artifactDirectoryName))
    }

    func test_verifyMissingBinaryIsUnavailable() {
        service.binaryPathOverride = "/nonexistent/graphify-\(UUID().uuidString)"
        let checkout = GraphifyCheckout(key: GraphifyRepoKey(commonDir: "/x/.git"), displayRoot: "/x")
        XCTAssertEqual(service.verify(checkout), .unavailable)
    }

    func test_resolveBinaryHonorsOverride() throws {
        let fake = tempRoot.appendingPathComponent("fake-graphify")
        try """
        #!/bin/sh
        exit 0
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        service.binaryPathOverride = fake.path
        XCTAssertEqual(service.resolveBinary(), fake.path)
    }

    func test_ensureSyncWithRealGraphifyCLI() throws {
        // Real e2e against installed graphify + real tiny git repo.
        let graphify = "/Users/samuelfajreldines/.local/bin/graphify"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: graphify), "graphify CLI not installed")

        let repo = try makeGitRepo(named: "tiny")
        service.binaryPathOverride = graphify
        service.enabled = true

        guard let id = GraphifyGitProbe.identity(at: repo.path) else {
            return XCTFail("repo identity")
        }
        service.writeInRepo = false
        let status = service.ensureSync(checkout: id.checkout, mode: .update)
        XCTAssertEqual(status, .fresh, "real graphify update must produce fresh status")
        let graph = service.graphJSONPath(for: id.checkout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: graph.path), "canonical ArtifactRoot graph.json")
        let data = try Data(contentsOf: graph)
        XCTAssertGreaterThan(data.count, 50)
        // Default: do not pollute the working tree
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repo.appendingPathComponent("graphify-out").path),
            "default writeInRepo=false must not create graphify-out in the repo"
        )
    }

    func test_softPreflightMultiRepoAutoBootstrapsOneChildNeverParent() throws {
        let container = tempRoot.appendingPathComponent("multi", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let a = try makeGitRepo(named: "a", parent: container)
        _ = try makeGitRepo(named: "b", parent: container)
        service.enabled = true
        service.autoEnsure = false
        let set = service.softPreflight(workspaceCwd: container.path)
        XCTAssertEqual(set.workspaceKind, "multiRepoContainer")
        XCTAssertEqual(set.roots.count, 1, "auto-bootstrap must pick one product child without user input")
        XCTAssertFalse(set.ambiguous)
        XCTAssertNotEqual(set.roots[0].checkout.displayRoot, container.path)
        XCTAssertTrue(
            set.roots[0].checkout.displayRoot.hasPrefix(container.path + "/"),
            "bootstrap root must be under the container"
        )
        _ = a
    }

    func test_graphifyProviderPromptInjectsWhenEnabled() {
        let base = "User request:\nhello"
        let off = AgentSkillInstaller.graphifyProviderPrompt(base, environment: [:])
        XCTAssertEqual(off, base)
        let on = AgentSkillInstaller.graphifyProviderPrompt(base, environment: [
            "RC_GRAPHIFY_ENABLED": "1",
            "RC_GRAPHIFY_GRAPH_JSON": "/tmp/g.json",
            "RC_GRAPHIFY_ROOTS": "/repo/a"
        ])
        XCTAssertTrue(on.contains("Graphify"), on)
        XCTAssertTrue(on.contains("graphify query"), on)
        XCTAssertTrue(on.contains("/tmp/g.json"), on)
        XCTAssertTrue(on.contains("/repo/a"), on)
    }

    func test_tokenSaverProviderPromptAlsoChainsGraphify() {
        let base = "hello"
        let combined = AgentSkillInstaller.tokenSaverProviderPrompt(base, environment: [
            "RC_GRAPHIFY_ENABLED": "1"
        ])
        XCTAssertTrue(combined.contains("graphify query"))
    }

    func test_failedUpdateWithExistingGraphReturnsStaleNotFresh() throws {
        let checkout = GraphifyCheckout(
            key: GraphifyRepoKey(commonDir: tempRoot.appendingPathComponent("fail.git").path),
            displayRoot: tempRoot.appendingPathComponent("fail-proj").path
        )
        try FileManager.default.createDirectory(atPath: checkout.displayRoot, withIntermediateDirectories: true)
        // Seed a previous good graph in the artifact root
        let dest = service.graphJSONPath(for: checkout)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"nodes\":[]}".write(to: dest, atomically: true, encoding: .utf8)

        service.binaryPathOverride = tempRoot.appendingPathComponent("failing-graphify").path
        try "#!/bin/sh\nexit 2\n".write(to: URL(fileURLWithPath: service.binaryPathOverride!), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: service.binaryPathOverride!)
        service.runProcess = { _, _, env in
            // Leave existing graph; fail the CLI
            return (2, "", "boom")
        }
        service.writeInRepo = false
        let status = service.ensureSync(checkout: checkout, mode: .update)
        XCTAssertEqual(status, .stale, "failed CLI must not advance fingerprint as fresh")
    }

    // MARK: helpers

    private func makeGitRepo(named: String, parent: URL? = nil) throws -> URL {
        let base = parent ?? tempRoot!
        let url = base.appendingPathComponent(named, isDirectory: true)
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
        try """
        export function add(a: number, b: number) { return a + b }
        export const name = "tiny"
        """.write(to: url.appendingPathComponent("lib.ts"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(["git", "add", "."]), 0)
        XCTAssertEqual(run(["git", "commit", "-m", "init"]), 0)
        return url.standardizedFileURL
    }
}
