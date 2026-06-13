import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// UX-MAC-CHECKPOINT-REVERT-UNDO: a checkpoint revert overwrites the git
/// working tree and deletes the newer checkpoint + assistant-message rows. That
/// is destructive, so it must be reversible within the toast window WITHOUT
/// corrupting the workspace. These tests pin the capture+restore contract:
/// undo writes back the exact pre-revert bytes, recreates files the revert
/// removed, removes files the revert created, and re-inserts the deleted DB
/// rows — and refuses once the window has lapsed.
final class CheckpointRevertUndoTests: XCTestCase {
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

    // MARK: - Pure seams (no git, no disk)

    func test_affectedPaths_isTargetUnionNewer() {
        // WHY: undo must capture exactly the path set the revert can touch — the
        // target snapshot paths UNION every newer snapshot path. A narrower set
        // would leave a reverted file un-restorable; a wider set would clobber an
        // untouched file on undo.
        let target = makeCheckpoint(turnCount: 1, snapshotPaths: ["a.txt", "b.txt"])
        let newer = [
            makeCheckpoint(turnCount: 2, snapshotPaths: ["b.txt", "c.txt"]),
            makeCheckpoint(turnCount: 3, snapshotPaths: ["d.txt"])
        ]
        XCTAssertEqual(
            CheckpointRevertUndo.affectedPaths(target: target, newer: newer),
            ["a.txt", "b.txt", "c.txt", "d.txt"]
        )
    }

    func test_isWithinUndoWindow_trueBeforeAndFalseAfter() {
        // WHY: a revert must be reversible briefly, then become final. The window
        // boundary is the contract the toast relies on.
        let captured = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(CheckpointRevertUndo.isWithinUndoWindow(
            capturedAt: captured, now: captured.addingTimeInterval(5), window: 10))
        XCTAssertFalse(CheckpointRevertUndo.isWithinUndoWindow(
            capturedAt: captured, now: captured.addingTimeInterval(11), window: 10))
    }

    // MARK: - Git round-trip

    func test_undoRestoresForwardFilesAndDeletedRows() async throws {
        // WHY: the whole point of the undo is that a mis-clicked revert can be
        // taken back and the workspace + thread look exactly as they did before.
        let appSupport = NSTemporaryDirectory() + "rc2-cru-roundtrip-db-" + UUID().uuidString
        let repoDir = try mkTmpRepo(prefix: "rc2-cru-roundtrip-repo-")
        defer {
            try? FileManager.default.removeItem(atPath: appSupport)
            try? FileManager.default.removeItem(atPath: repoDir)
        }
        let targetBody = "hello\nturn one\n"
        let forwardBody = "hello\nturn two\n"
        // Forward (pre-revert) on-disk state: README has turn-two content and a
        // forward-only file later.txt exists.
        try forwardBody.write(toFile: repoDir + "/README.md", atomically: true, encoding: .utf8)
        try "later\n".write(toFile: repoDir + "/later.txt", atomically: true, encoding: .utf8)

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let thread = AgentThread(title: "revert-undo", provider: .codex, model: "fake-model")
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

        _ = try await coordinator.revertThreadToCheckpoint(threadId: thread.id, checkpointTurnCount: 1, cwd: repoDir)

        // Sanity: the revert destroyed forward state as before.
        XCTAssertEqual(try String(contentsOfFile: repoDir + "/README.md", encoding: .utf8), targetBody)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoDir + "/later.txt"))
        XCTAssertEqual(try checkpointRepo.list(threadId: thread.id).map(\.checkpointTurnCount), [1])
        XCTAssertEqual(try messageRepo.list(threadId: thread.id).map(\.content), ["turn one"])

        try coordinator.undoLastCheckpointRevert(threadId: thread.id, cwd: repoDir)

        // Files restored to FORWARD bytes.
        XCTAssertEqual(try String(contentsOfFile: repoDir + "/README.md", encoding: .utf8), forwardBody,
                       "undo must write back the exact pre-revert file bytes")
        XCTAssertEqual(try String(contentsOfFile: repoDir + "/later.txt", encoding: .utf8), "later\n",
                       "undo must recreate a forward-only file the revert removed")
        // DB rows restored.
        XCTAssertEqual(try checkpointRepo.list(threadId: thread.id).map(\.checkpointTurnCount), [1, 2],
                       "undo must re-insert the newer checkpoint row")
        XCTAssertEqual(try messageRepo.list(threadId: thread.id).map(\.content).sorted(), ["turn one", "turn two"],
                       "undo must re-insert the deleted assistant message row")
    }

    func test_undoRemovesFileThatWasAbsentPreRevert() async throws {
        // WHY: if a file did not exist before the revert (the revert created it
        // from a target snapshot), undo must REMOVE it — not leave a stale file.
        let appSupport = NSTemporaryDirectory() + "rc2-cru-absent-db-" + UUID().uuidString
        let repoDir = try mkTmpRepo(prefix: "rc2-cru-absent-repo-")
        defer {
            try? FileManager.default.removeItem(atPath: appSupport)
            try? FileManager.default.removeItem(atPath: repoDir)
        }
        let targetBody = "created by revert\n"
        // newPath does NOT exist on disk pre-revert; the target snapshot creates it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoDir + "/new.txt"))

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let thread = AgentThread(title: "absent", provider: .codex, model: "fake-model")
        let runOne = AgentRunID()
        try threadRepo.upsert(thread)
        try runRepo.upsert(AgentRun(id: runOne, threadId: thread.id, provider: .codex, model: "fake-model", status: .completed))
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id, runId: runOne, turnId: "turn-1", checkpointTurnCount: 1,
            checkpointRef: "local-diff:\(runOne.value.uuidString):turn-1", status: .ready,
            files: [AgentTurnCheckpointFile(path: "new.txt", kind: "modified", additions: 1, deletions: 0)],
            fileSnapshots: [AgentTurnCheckpointFileSnapshot(path: "new.txt", kind: "modified", contentsBase64: Data(targetBody.utf8).base64EncodedString())]
        ))
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo, checkpointRepo: checkpointRepo,
                                              providerAdapters: [.codex: StubRollbackAdapter(provider: .codex)])

        _ = try await coordinator.revertThreadToCheckpoint(threadId: thread.id, checkpointTurnCount: 1, cwd: repoDir)
        XCTAssertEqual(try String(contentsOfFile: repoDir + "/new.txt", encoding: .utf8), targetBody,
                       "revert creates the file from the target snapshot")

        try coordinator.undoLastCheckpointRevert(threadId: thread.id, cwd: repoDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoDir + "/new.txt"),
                       "undo must remove a file that was absent before the revert")
    }

    func test_undoOutsideWindowThrowsAndLeavesStateUnchanged() async throws {
        // WHY: after the window the revert is final. A late undo must refuse and
        // must NOT mutate files or DB rows.
        let appSupport = NSTemporaryDirectory() + "rc2-cru-window-db-" + UUID().uuidString
        let repoDir = try mkTmpRepo(prefix: "rc2-cru-window-repo-")
        defer {
            try? FileManager.default.removeItem(atPath: appSupport)
            try? FileManager.default.removeItem(atPath: repoDir)
        }
        let targetBody = "hello\ntarget\n"
        let forwardBody = "hello\nforward\n"
        try forwardBody.write(toFile: repoDir + "/README.md", atomically: true, encoding: .utf8)

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let thread = AgentThread(title: "window", provider: .codex, model: "fake-model")
        let runOne = AgentRunID()
        try threadRepo.upsert(thread)
        try runRepo.upsert(AgentRun(id: runOne, threadId: thread.id, provider: .codex, model: "fake-model", status: .completed))
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id, runId: runOne, turnId: "turn-1", checkpointTurnCount: 1,
            checkpointRef: "local-diff:\(runOne.value.uuidString):turn-1", status: .ready,
            files: [AgentTurnCheckpointFile(path: "README.md", kind: "modified", additions: 1, deletions: 0)],
            fileSnapshots: [AgentTurnCheckpointFileSnapshot(path: "README.md", kind: "modified", contentsBase64: Data(targetBody.utf8).base64EncodedString())]
        ))
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo, checkpointRepo: checkpointRepo,
                                              providerAdapters: [.codex: StubRollbackAdapter(provider: .codex)])

        _ = try await coordinator.revertThreadToCheckpoint(threadId: thread.id, checkpointTurnCount: 1, cwd: repoDir)
        XCTAssertEqual(try String(contentsOfFile: repoDir + "/README.md", encoding: .utf8), targetBody)

        // 11s past capture -> outside the 10s window.
        XCTAssertThrowsError(try coordinator.undoLastCheckpointRevert(
            threadId: thread.id, cwd: repoDir, now: Date().addingTimeInterval(11)))
        XCTAssertEqual(try String(contentsOfFile: repoDir + "/README.md", encoding: .utf8), targetBody,
                       "a late undo must not touch the workspace")
    }

    // MARK: - Helpers

    private func makeCheckpoint(turnCount: Int, snapshotPaths: [String]) -> AgentTurnCheckpointSummary {
        AgentTurnCheckpointSummary(
            threadId: AgentThreadID(),
            runId: AgentRunID(),
            turnId: "turn-\(turnCount)",
            checkpointTurnCount: turnCount,
            checkpointRef: "ref-\(turnCount)",
            status: .ready,
            files: [],
            fileSnapshots: snapshotPaths.map {
                AgentTurnCheckpointFileSnapshot(path: $0, kind: "modified", contentsBase64: Data("x".utf8).base64EncodedString())
            }
        )
    }
}

/// Minimal adapter: only rollbackThread is exercised by the revert path; the
/// rest are inert stubs.
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
