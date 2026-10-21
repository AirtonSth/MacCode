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

    private func rebuild() -> BotVMRunRegistry.Entry {
        .init(threadID: AgentThreadID(), runID: AgentRunID(), title: "Linux desktop rebuild", workspace: "", exclusive: true)
    }

    func test_conversationsOnOneVMRunInParallel() {
        // WHY: a bot VM has no parallelism limit; a second conversation must
        // start at once instead of failing with "The VM is busy".
        let registry = BotVMRunRegistry()
        XCTAssertNil(registry.tryBegin(botID: botID, entry: entry()))
        let other = BotVMRunRegistry.Entry(threadID: threadB, runID: AgentRunID(), title: "B", workspace: workspace)
        XCTAssertNil(registry.tryBegin(botID: botID, entry: other))
        let third = BotVMRunRegistry.Entry(threadID: AgentThreadID(), runID: AgentRunID(), title: "C", workspace: workspace)
        XCTAssertNil(registry.tryBegin(botID: botID, entry: third))
        XCTAssertNil(registry.busyMessage(botID: botID, threadID: threadB))
        XCTAssertEqual(registry.claim(botID: botID, threadID: threadB), other, "each run keeps its own workspace")
        registry.endRun(runID: runA)
        XCTAssertEqual(registry.active(botID: botID), other, "ending one run keeps the others")
    }

    func test_rebuildWaitsForEveryRunAndRunsWaitForTheRebuild() {
        // WHY: a rebuild replaces the container, so it must never stop it
        // under a running conversation, and no conversation may start on the
        // old container while it builds.
        let registry = BotVMRunRegistry()
        XCTAssertNil(registry.tryBegin(botID: botID, entry: entry()))
        XCTAssertEqual(registry.tryBegin(botID: botID, entry: rebuild()), entry())
        registry.endRun(runID: runA)
        let build = rebuild()
        XCTAssertNil(registry.tryBegin(botID: botID, entry: build))
        let other = BotVMRunRegistry.Entry(threadID: threadB, runID: AgentRunID(), title: "B", workspace: workspace)
        XCTAssertEqual(registry.tryBegin(botID: botID, entry: other), build)
        XCTAssertEqual(registry.busyMessage(botID: botID, threadID: threadB), "The VM is busy in Linux desktop rebuild")
        registry.addWaiting(botID: botID, threadID: threadB)
        XCTAssertNil(registry.popWaitingIfFree(botID: botID), "no hand-off while the rebuild holds the VM")
        XCTAssertEqual(registry.releaseAndNextWaiting(runID: build.runID), threadB)
        XCTAssertNil(registry.tryBegin(botID: botID, entry: other))
    }

    func test_theRequestingThreadsOwnRunKeepsGoingDuringItsRebuild() {
        // WHY: a bot's own agent rebuilds its VM mid-run; its claim must not
        // block that rebuild, while other threads' runs still do.
        let registry = BotVMRunRegistry()
        XCTAssertNil(registry.tryBegin(botID: botID, entry: entry()))
        let own = BotVMRunRegistry.Entry(threadID: threadA, runID: AgentRunID(), title: "rebuild", workspace: "", exclusive: true)
        XCTAssertNil(registry.tryBegin(botID: botID, entry: own))
        let other = BotVMRunRegistry.Entry(threadID: threadB, runID: AgentRunID(), title: "B", workspace: workspace)
        XCTAssertEqual(registry.tryBegin(botID: botID, entry: other), own)
    }

    func test_anUnstartedSecondClaimOfTheSameThreadNeverFreesTheVMUnderTheRunThatStarted() {
        // WHY: two starts on one thread (router + tab, iOS + Mac) both claim.
        // Whichever does not start releases its claim; that must not free the
        // VM for a rebuild while the other run is still running.
        for startedFirst in [true, false] {
            let registry = BotVMRunRegistry()
            let first = entry()
            let second = BotVMRunRegistry.Entry(threadID: threadA, runID: AgentRunID(), title: "A", workspace: workspace)
            XCTAssertNil(registry.tryBegin(botID: botID, entry: first))
            XCTAssertNil(registry.tryBegin(botID: botID, entry: second))
            let (started, unstarted) = startedFirst ? (first, second) : (second, first)
            _ = registry.releaseAndNextWaiting(runID: unstarted.runID)
            XCTAssertEqual(registry.tryBegin(botID: botID, entry: rebuild()), started)
            _ = registry.releaseAndNextWaiting(runID: started.runID)
            XCTAssertNil(registry.active(botID: botID))
        }
    }

    func test_releaseAndNextWaitingFreesTheVMAndPopsFirstWaiterOnce() {
        // WHY: threads queued behind a rebuild resume when it ends, in order, exactly once.
        let registry = BotVMRunRegistry()
        let build = rebuild()
        _ = registry.tryBegin(botID: botID, entry: build)
        registry.addWaiting(botID: botID, threadID: threadB)
        registry.addWaiting(botID: botID, threadID: threadB)
        let threadC = AgentThreadID()
        registry.addWaiting(botID: botID, threadID: threadC)
        XCTAssertEqual(registry.releaseAndNextWaiting(runID: AgentRunID()), nil)
        XCTAssertNotNil(registry.active(botID: botID), "unknown run must not free the bot")
        XCTAssertEqual(registry.releaseAndNextWaiting(runID: build.runID), threadB)
        XCTAssertNil(registry.active(botID: botID))
        XCTAssertEqual(registry.waitingThreads(botID: botID), [threadC])
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
