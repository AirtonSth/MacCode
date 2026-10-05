import XCTest
import CoreModel
import Persistence
@testable import AppShell

final class BotVMExecutionTests: XCTestCase {
    private let botID = BotID()
    private let threadA = AgentThreadID()
    private let threadB = AgentThreadID()
    private let runA = AgentRunID()
    private let workspace = "/tmp/rc-vm-exec/project"

    private func entry() -> BotVMRunRegistry.Entry {
        .init(threadID: threadA, runID: runA, title: "Tarefa A", workspace: workspace)
    }

    func test_otherThreadSeesBusyMessageButOwnerDoesNot() {
        // WHY: one VM runs one thread at a time; only a different thread must be queued.
        let registry = BotVMRunRegistry()
        registry.begin(botID: botID, entry: entry())
        XCTAssertEqual(registry.busyMessage(botID: botID, threadID: threadB), "bot ocupado em Tarefa A")
        XCTAssertNil(registry.busyMessage(botID: botID, threadID: threadA))
    }

    func test_endWithWrongRunKeepsEntryAndRightRunClears() {
        // WHY: a stale finish event must not free the VM held by a newer run.
        let registry = BotVMRunRegistry()
        registry.begin(botID: botID, entry: entry())
        registry.end(botID: botID, runID: AgentRunID())
        XCTAssertNotNil(registry.active(botID: botID))
        registry.endRun(runID: runA)
        XCTAssertNil(registry.active(botID: botID))
    }

    func test_applyExecRunsInRunWorkspaceWithHostUserAndGitIdentity() throws {
        // WHY: bot commands must edit the thread's workspace as the host user, not the VM home.
        var recorded: [[String]] = []
        let lock = NSLock()
        let docker = BotComputerDockerCLI(run: { args in
            lock.withLock { recorded.append(args) }
            switch args.first {
            case "inspect":
                if args.contains(where: { $0.contains("Config.Labels\"") }) {
                    return Data(BotComputerGuestSpec.recipeRevision.utf8)
                }
                if args.contains("{{.Id}}") { return Data("img".utf8) }
                return Data("true img 49152  {}".utf8)
            case "create": return Data("cid".utf8)
            case "exec": return BotComputerGuestObserve.pngSignature + Data(repeating: 1, count: 16)
            default: return Data()
            }
        })
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-vmexec-\(UUID().uuidString)", isDirectory: true)
        let registry = BotVMRunRegistry()
        registry.begin(botID: botID, entry: entry())
        let service = BotComputerGuestService(
            appSupport: support,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0,
            vmRuns: registry,
            gitRun: { $0.last == "user.name" ? "Ada" : "ada@example.com" }
        )
        let result = try service.apply(BotComputerPendingAction(
            id: "1",
            botID: botID.value.uuidString,
            kind: BotComputerCatalog.exec,
            command: "git status"
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        let exec = try XCTUnwrap(lock.withLock { recorded }.last { $0.first == "exec" && $0.contains("-w") })
        XCTAssertEqual(exec[exec.firstIndex(of: "-w")! + 1], workspace)
        XCTAssertTrue(exec.joined(separator: " ").contains("-u \(getuid()):\(getgid())"))
        XCTAssertTrue(exec.contains("GIT_AUTHOR_NAME=Ada"))
    }

    func test_vmThreadRulesCoverToolchainScreenshotAndManualActionFamilies() {
        // WHY: the VM bot must know Linux limits, when to screenshot, and when to ask a human.
        let rules = BotStandingInstructions.vmThreadRules
        XCTAssertTrue(rules.contains("request_mac_execution(reason)"))
        XCTAssertTrue(rules.contains("bot_post_screenshot"))
        XCTAssertTrue(rules.contains("Nunca peça senha, código ou dados de cartão no chat."))
        XCTAssertTrue(rules.contains("sempre tire screenshot antes de agir"))
    }
}
