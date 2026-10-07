import XCTest
import AppKit
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

// UX-XPLAT-REVERT-UNDO: a checkpoint revert is destructive (it overwrites the
// working tree and drops the newer checkpoint + assistant rows). The coordinator
// already makes the revert reversible within a 10s window; these tests pin the
// ADDITIVE view-model toast layer that surfaces that capability: arming the toast
// on a successful revert, clearing it on undo, and the pure window predicate the
// toast relies on. WHY: the revert toast must offer Undo for exactly the 10s
// window - neither too short nor unbounded.
@MainActor
final class CheckpointRevertUndoToastTests: XCTestCase {
    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }


    private func runShell(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    private func mkTmpRepo(prefix: String) throws -> String {
        let dir = NSTemporaryDirectory() + prefix + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        runShell(["git", "init", "-q", "-b", "main", dir])
        runShell(["git", "-C", dir, "config", "user.email", "t@t.t"])
        runShell(["git", "-C", dir, "config", "user.name", "test"])
        try "hello\n".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
        runShell(["git", "-C", dir, "add", "README.md"])
        runShell(["git", "-C", dir, "commit", "-q", "-m", "init"])
        return dir
    }

    /// Build a VM over a real repo with two checkpoints (turn 1 target, turn 2
    /// forward) so revertSelectedCheckpoint(turn 1) succeeds through the
    /// coordinator and arms the toast. Returns (vm, threadId, repoDir, appSupport).
    private func makeRevertableVM() throws -> (AgentAppViewModel, AgentThreadID, String, String) {
        let appSupport = NSTemporaryDirectory() + "rc2-cru-toast-db-" + UUID().uuidString
        let repoDir = try mkTmpRepo(prefix: "rc2-cru-toast-repo-")
        let targetBody = "hello\nturn one\n"
        let forwardBody = "hello\nturn two\n"
        // Forward (pre-revert) on-disk state.
        try forwardBody.write(toFile: repoDir + "/README.md", atomically: true, encoding: .utf8)
        try "later\n".write(toFile: repoDir + "/later.txt", atomically: true, encoding: .utf8)

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        // selectThread refuses a persisted thread from another workspace (a nil
        // workspace included), so the fixture thread must belong to the VM's.
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "revert-undo", provider: .codex, model: "fake-model")
        let runOne = AgentRunID()
        let runTwo = AgentRunID()
        let assistantOne = AgentMessage(threadId: thread.id, role: .assistant, content: "turn one")
        let assistantTwo = AgentMessage(threadId: thread.id, role: .assistant, content: "turn two")
        try threadRepo.upsert(thread)
        try runRepo.upsert(AgentRun(id: runOne, threadId: thread.id, provider: .codex, model: "fake-model", status: .completed))
        try runRepo.upsert(AgentRun(id: runTwo, threadId: thread.id, provider: .codex, model: "fake-model", status: .completed))
        try messageRepo.append(assistantOne)
        try messageRepo.append(assistantTwo)
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id, runId: runOne, turnId: "turn-1", checkpointTurnCount: 1,
            checkpointRef: "local-diff:\(runOne.value.uuidString):turn-1", status: .ready,
            files: [AgentTurnCheckpointFile(path: "README.md", kind: "modified", additions: 1, deletions: 0)],
            fileSnapshots: [AgentTurnCheckpointFileSnapshot(path: "README.md", kind: "modified", contentsBase64: Data(targetBody.utf8).base64EncodedString())],
            assistantMessageId: assistantOne.id
        ))
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id, runId: runTwo, turnId: "turn-2", checkpointTurnCount: 2,
            checkpointRef: "local-diff:\(runTwo.value.uuidString):turn-2", status: .ready,
            files: [AgentTurnCheckpointFile(path: "README.md", kind: "modified", additions: 1, deletions: 0),
                    AgentTurnCheckpointFile(path: "later.txt", kind: "untracked", additions: 0, deletions: 0)],
            fileSnapshots: [
                AgentTurnCheckpointFileSnapshot(path: "README.md", kind: "modified", contentsBase64: Data(forwardBody.utf8).base64EncodedString()),
                AgentTurnCheckpointFileSnapshot(path: "later.txt", kind: "untracked", contentsBase64: Data("later\n".utf8).base64EncodedString())
            ],
            assistantMessageId: assistantTwo.id
        ))
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo, checkpointRepo: checkpointRepo,
                                              providerAdapters: [.codex: StubRollbackAdapter(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: repoDir,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo, checkpointRepo: checkpointRepo)
        vm.selectThread(thread.id)
        XCTAssertEqual(vm.selectedThreadId, thread.id, "revert acts on the selected thread")
        vm.providerSnapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake model", provider: .codex)]
            )
        ]
        vm.selectedCheckpointTurnCount = 1
        return (vm, thread.id, repoDir, appSupport)
    }

    /// Spin the main actor until `predicate` holds or the deadline passes.
    /// revertSelectedCheckpoint / undoLastCheckpointRevert dispatch their work in
    /// detached @MainActor Tasks, so the side effects land asynchronously.
    private func waitUntil(_ message: String, timeout: TimeInterval = 5,
                           _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), message)
    }

    // MARK: - Pure window seam (no git, no disk)

    // WHY: the toast must stay actionable for the full 10s and then become inert.
    // This pins the exact boundary the arm/expiry logic relies on (the same seam
    // the coordinator uses), so the toast is neither too short nor unbounded.
    func test_isWithinUndoWindow_trueAt5sFalseAt11s() {
        let captured = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(CheckpointRevertUndo.isWithinUndoWindow(
            capturedAt: captured, now: captured.addingTimeInterval(5), window: 10),
            "an undo at 5s is inside the 10s window")
        XCTAssertFalse(CheckpointRevertUndo.isWithinUndoWindow(
            capturedAt: captured, now: captured.addingTimeInterval(11), window: 10),
            "an undo at 11s is past the 10s window and must be refused")
    }

    // WHY: the toast handle carries the data undo needs (thread, cwd, turn count,
    // capture instant). Value equality guards arm/expiry from clobbering a newer
    // toast - only the toast with the same capturedAt is cleared on lapse.
    func test_toast_equatableByValue() {
        let t = AgentThreadID()
        let at = Date(timeIntervalSince1970: 42)
        let a = AgentAppViewModel.CheckpointRevertUndoToast(threadId: t, cwd: "/tmp/x", checkpointTurnCount: 1, capturedAt: at)
        let b = AgentAppViewModel.CheckpointRevertUndoToast(threadId: t, cwd: "/tmp/x", checkpointTurnCount: 1, capturedAt: at)
        let c = AgentAppViewModel.CheckpointRevertUndoToast(threadId: t, cwd: "/tmp/x", checkpointTurnCount: 1, capturedAt: at.addingTimeInterval(1))
        XCTAssertEqual(a, b, "identical reverts must compare equal")
        XCTAssertNotEqual(a, c, "a later capture is a different toast")
    }

    // MARK: - VM arm/undo state machine (real coordinator, stub adapter)

    // WHY: a successful revert must surface the Undo affordance. This proves the
    // revert ran (forward state destroyed) AND the toast was armed with the
    // reverted turn count so the banner can offer recovery.
    func test_revertSelectedCheckpoint_armsUndoToast() async throws {
        let (vm, threadId, repoDir, appSupport) = try makeRevertableVM()
        defer {
            try? FileManager.default.removeItem(atPath: repoDir)
            try? FileManager.default.removeItem(atPath: appSupport)
        }

        vm.revertSelectedCheckpoint()

        await waitUntil("revert must arm the undo toast") { vm.pendingCheckpointRevertUndo != nil }
        let toast = try XCTUnwrap(vm.pendingCheckpointRevertUndo)
        XCTAssertEqual(toast.threadId, threadId)
        XCTAssertEqual(toast.checkpointTurnCount, 1, "the toast must name the reverted checkpoint")
        XCTAssertEqual(toast.cwd, repoDir)
        // Sanity: the revert actually happened (forward-only file gone).
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoDir + "/later.txt"),
                       "the toast only arms on a real revert success")
    }

    // WHY: tapping Undo must reverse the revert AND dismiss the toast. This proves
    // both: the workspace returns to its pre-revert (forward) bytes and the
    // pending toast is cleared so the banner disappears.
    func test_undoLastCheckpointRevert_restoresAndClearsToast() async throws {
        let (vm, _, repoDir, appSupport) = try makeRevertableVM()
        defer {
            try? FileManager.default.removeItem(atPath: repoDir)
            try? FileManager.default.removeItem(atPath: appSupport)
        }
        vm.revertSelectedCheckpoint()
        await waitUntil("toast armed before undo") { vm.pendingCheckpointRevertUndo != nil }

        vm.undoLastCheckpointRevert()

        // Toast is dismissed immediately on tap.
        XCTAssertNil(vm.pendingCheckpointRevertUndo, "tapping Undo must clear the toast at once")
        // Undo restores forward bytes + the forward-only file.
        await waitUntil("undo must restore the forward working tree") {
            (try? String(contentsOfFile: repoDir + "/README.md", encoding: .utf8)) == "hello\nturn two\n"
            && FileManager.default.fileExists(atPath: repoDir + "/later.txt")
        }
    }

    // WHY: Undo with no pending toast must be a harmless no-op - a stray tap (or
    // a tap after the toast expired) must not touch the coordinator or crash.
    func test_undoLastCheckpointRevert_noopWhenNothingPending() throws {
        let (vm, _, repoDir, appSupport) = try makeRevertableVM()
        defer {
            try? FileManager.default.removeItem(atPath: repoDir)
            try? FileManager.default.removeItem(atPath: appSupport)
        }
        XCTAssertNil(vm.pendingCheckpointRevertUndo)
        vm.undoLastCheckpointRevert()
        XCTAssertNil(vm.pendingCheckpointRevertUndo, "no toast means undo does nothing")
    }
}

/// Minimal adapter: only rollbackThread is exercised by the revert path; the
/// rest are inert stubs. Mirrors the AgentRuntimeTests stub.
private final class StubRollbackAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    init(provider: AgentProvider) { self.provider = provider }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil, cancel: {})
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { true }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}
