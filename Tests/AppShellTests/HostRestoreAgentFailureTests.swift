import XCTest
import AgentRuntime
import CoreModel
import Persistence
import Surfaces
@testable import AppShell

@MainActor
final class HostRestoreAgentFailureTests: XCTestCase {
    func testForceFailureRepausesRestoredQueueBeforeAutomaticDrain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer {
            let surfaces = SurfaceRegistry.shared.all()
            surfaces.forEach { $0.close() }
            surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        }

        let context = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "restore-force-failure", cwd: workspaceDir.path)
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "restored queue",
            provider: .codex,
            model: "test-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.status = .failed
        try context.threadRepo.upsert(thread)
        let queued = try context.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "review before sending again",
            attachments: [],
            interactionMode: .default
        )
        let queueID = queued.id.value.uuidString
        try HostDatabaseRestore.pauseQueue(kind: .agent, id: queueID, db: context.db)
        let runner = FailingQueueRunner()
        context.coordinator.replaceProvider(.codex, runner: runner)

        do {
            _ = try await router.forceAgentQueuedMessageNow(id: queued.id)
            XCTFail("explicit Force must surface provider failure")
        } catch {}

        XCTAssertEqual(try context.queuedMessageRepo.list(threadId: thread.id).map(\.id), [queued.id])
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: queueID, db: context.db))
        XCTAssertEqual(try HostDatabaseRestore.queueAttempt(kind: .agent, id: queueID, db: context.db), AgentRunID(queued.id.value))

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(runner.startCount, 1, "the scheduled automatic drain must not retry an explicitly failed Force")
        XCTAssertEqual(try context.queuedMessageRepo.list(threadId: thread.id).map(\.id), [queued.id])
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: queueID, db: context.db))
    }
}

private final class FailingQueueRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var starts = 0

    var startCount: Int { lock.withLock { starts } }
    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.withLock { starts += 1 }
        throw AgentRunError.spawnFailed("intentional restored-queue start failure")
    }
}
