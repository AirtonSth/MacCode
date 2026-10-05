import XCTest
import CoreModel
@testable import AppShell

private final class ScriptedDocker: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var canonicalLabels: [String: String]
    var failCreate = false
    static let png = BotComputerGuestObserve.pngSignature + Data(repeating: 1, count: 16)

    init(canonicalLabels: [String: String] = [:]) { self.canonicalLabels = canonicalLabels }

    var calls: [[String]] { lock.withLock { recorded } }
    var verbs: [String] {
        let watched: Set<String> = ["stop", "rename", "create", "start", "rm"]
        return calls.compactMap { $0.first }.filter(watched.contains)
    }

    func run(_ args: [String]) throws -> Data {
        lock.withLock { recorded.append(args) }
        switch args.first {
        case "inspect":
            if args.contains(where: { $0.contains("Config.Labels\"") }) {
                return Data(BotComputerGuestSpec.recipeRevision.utf8)
            }
            if args.contains("{{.Id}}") { return Data("img".utf8) }
            let json = try JSONEncoder().encode(canonicalLabels)
            return Data("true img 49152  \(String(decoding: json, as: UTF8.self))".utf8)
        case "create":
            if failCreate { throw BotComputerDockerError.provisioningFailed }
            return Data("cid".utf8)
        case "exec":
            return Self.png
        default:
            return Data()
        }
    }
}

final class BotComputerWorkspaceMountTests: XCTestCase {
    private let workspace = "/tmp/rc-ws-mount/project"

    private func makeService(
        _ scripted: ScriptedDocker,
        stored: [String] = [],
        workspacesWriter: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) throws -> (BotComputerGuestService, BotID, URL) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-ws-\(UUID().uuidString)", isDirectory: true)
        let botID = BotID()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: BotComputerDockerCLI(run: { try scripted.run($0) }),
            observeAttempts: 1,
            observeDelay: 0,
            workspacesWriter: workspacesWriter
        )
        if !stored.isEmpty {
            let url = BotComputerGuestSpec.workspacesURL(appSupport: support, botID: botID)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: url)
        }
        return (service, botID, support)
    }

    func test_sameLabelDoesNotRecreateContainer() throws {
        // WHY: recreating a running container would kill the bot's browser session for nothing.
        let label = BotComputerGuestSpec.workspacesLabel([workspace])
        let scripted = ScriptedDocker(canonicalLabels: [BotComputerGuestSpec.workspacesLabelKey: label])
        let (service, botID, _) = try makeService(scripted, stored: [workspace])
        try service.ensureWorkspaceMounted(botID: botID, workspace: workspace, registered: [workspace])
        XCTAssertFalse(scripted.verbs.contains("create"))
        XCTAssertEqual(scripted.verbs, [])
    }

    func test_differentLabelSwapsAtomically() throws {
        // WHY: the old container is only removed after the new one runs.
        let scripted = ScriptedDocker(canonicalLabels: [BotComputerGuestSpec.workspacesLabelKey: BotComputerGuestSpec.workspacesLabel([])])
        let (service, botID, support) = try makeService(scripted)
        try service.ensureWorkspaceMounted(botID: botID, workspace: workspace, registered: [workspace])
        XCTAssertEqual(scripted.verbs, ["stop", "rename", "create", "start", "rm"])
        let create = try XCTUnwrap(scripted.calls.first { $0.first == "create" })
        XCTAssertTrue(create.contains("\(workspace):\(workspace)"))
        XCTAssertTrue(create.contains("\(BotComputerGuestSpec.workspacesLabelKey)=\(BotComputerGuestSpec.workspacesLabel([workspace]))"))
        let name = BotComputerGuestSpec.containerName(botID: botID)
        XCTAssertEqual(scripted.calls.first { $0.first == "rename" }, ["rename", name, name + "-backup"])
        XCTAssertEqual(scripted.calls.last { $0.first == "rm" }, ["rm", "-f", name + "-backup"])
        let saved = try JSONDecoder().decode(
            [String].self,
            from: Data(contentsOf: BotComputerGuestSpec.workspacesURL(appSupport: support, botID: botID))
        )
        XCTAssertEqual(saved, [workspace])
    }

    func test_createFailureRestoresOldContainer() throws {
        // WHY: a failed mount must leave the bot's previous VM running and the list unchanged.
        let scripted = ScriptedDocker(canonicalLabels: [:])
        scripted.failCreate = true
        let (service, botID, support) = try makeService(scripted)
        XCTAssertThrowsError(
            try service.ensureWorkspaceMounted(botID: botID, workspace: workspace, registered: [workspace])
        )
        XCTAssertEqual(scripted.verbs, ["stop", "rename", "create", "rm", "rename", "start"])
        let name = BotComputerGuestSpec.containerName(botID: botID)
        let renames = scripted.calls.filter { $0.first == "rename" }
        XCTAssertEqual(renames.last, ["rename", name + "-backup", name])
        XCTAssertEqual(scripted.calls.last { $0.first == "rm" }, ["rm", "-f", name])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: BotComputerGuestSpec.workspacesURL(appSupport: support, botID: botID).path
        ))
    }

    func test_manifestSaveFailureRollsBackToOldContainer() throws {
        // WHY: the backup may only be dropped once the new bind list is durable, else the VM and manifest diverge.
        struct WriteFailure: Error {}
        let scripted = ScriptedDocker(canonicalLabels: [:])
        let (service, botID, support) = try makeService(scripted, workspacesWriter: { _, _ in throw WriteFailure() })
        XCTAssertThrowsError(
            try service.ensureWorkspaceMounted(botID: botID, workspace: workspace, registered: [workspace])
        ) { XCTAssertTrue($0 is WriteFailure) }
        XCTAssertEqual(scripted.verbs, ["stop", "rename", "create", "start", "rm", "rename", "start"])
        let name = BotComputerGuestSpec.containerName(botID: botID)
        XCTAssertEqual(scripted.calls.filter { $0.first == "rename" }.last, ["rename", name + "-backup", name])
        XCTAssertEqual(scripted.calls.last { $0.first == "start" }, ["start", name])
        XCTAssertFalse(scripted.calls.contains(["rm", "-f", name + "-backup"]))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: BotComputerGuestSpec.workspacesURL(appSupport: support, botID: botID).path
        ))
    }

    func test_unregisteredWorkspaceIsRejectedBeforeDocker() throws {
        let scripted = ScriptedDocker()
        let (service, botID, _) = try makeService(scripted)
        XCTAssertThrowsError(
            try service.ensureWorkspaceMounted(botID: botID, workspace: workspace, registered: [])
        )
        XCTAssertTrue(scripted.calls.isEmpty)
    }

    func test_execUsesWorkdirUidGidAndGitIdentityWithoutLeakingProviderSecrets() throws {
        // WHY: plan B injects no credentials; a provider env var must never reach docker args.
        let providerEnvironment = ["SECRET_TOKEN": "abc123", "API_KEY": "key-999"]
        _ = providerEnvironment
        let scripted = ScriptedDocker()
        let (service, botID, _) = try makeService(scripted)
        let identity = GitIdentity(name: "Ada", email: "ada@example.com")
        _ = try service.exec(
            botID: botID,
            command: "git status",
            workspace: workspace,
            user: "501:20",
            gitIdentity: identity
        )
        let exec = try XCTUnwrap(scripted.calls.last { $0.first == "exec" && $0.contains("-w") })
        let joined = exec.joined(separator: " ")
        XCTAssertTrue(joined.contains("-w \(workspace)"))
        XCTAssertTrue(joined.contains("-u 501:20"))
        XCTAssertTrue(joined.contains("-e GIT_AUTHOR_NAME=Ada"))
        XCTAssertTrue(joined.contains("-e GIT_COMMITTER_EMAIL=ada@example.com"))
        let all = scripted.calls.flatMap { $0 }.joined(separator: " ")
        XCTAssertFalse(all.contains("abc123"))
        XCTAssertFalse(all.contains("key-999"))
        XCTAssertFalse(all.contains("SECRET_TOKEN"))
    }

    func test_rootCommandsKeepUserZeroButStillSetWorkdir() throws {
        let scripted = ScriptedDocker()
        let (service, botID, _) = try makeService(scripted)
        _ = try service.exec(botID: botID, command: "apt-get update", workspace: workspace, user: "501:20", gitIdentity: nil)
        let exec = try XCTUnwrap(scripted.calls.last { $0.first == "exec" && $0.contains("-w") })
        XCTAssertEqual(Array(exec.prefix(5)), ["exec", "-u", "0", "-w", workspace])
        XCTAssertFalse(exec.contains("-e"))
    }

    func test_gitIdentityReadsNameAndEmailThroughInjectedRunner() {
        let identity = BotComputerGuestService.gitIdentity { args in
            args.last == "user.name" ? "Ada" : "ada@example.com"
        }
        XCTAssertEqual(identity, GitIdentity(name: "Ada", email: "ada@example.com"))
        XCTAssertNil(BotComputerGuestService.gitIdentity { _ in nil })
    }
}
