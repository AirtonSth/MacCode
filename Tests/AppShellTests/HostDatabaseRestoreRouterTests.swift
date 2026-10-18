import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

@MainActor
final class HostDatabaseRestoreRouterTests: XCTestCase {
    private struct Fixture: Decodable {
        let thread: AgentThreadID
        let queued: AgentQueuedMessageID
        let stoppedRun: AgentRunID
        let orphanRun: AgentRunID
    }

    func testRestoredOldQueueCannotExecuteThroughHostDrainOrForceNow() async throws {
        guard ProcessInfo.processInfo.environment["RC_HOST_RESTORE_VERIFY"] == "1",
              let path = ProcessInfo.processInfo.environment["RC_HOST_RESTORE_FIXTURE_ROOT"] else {
            throw XCTSkip("set isolated restored-host fixture to verify router entry points")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.path.contains("/.sandbox-worktrees/"), root.path.contains("/.sandbox-state/host-restore-") else {
            throw SQLiteError.open("router verification requires an isolated restore directory")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        let context = try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent("current.sqlite").path,
                                     appSupportOverride: root.appendingPathComponent("app-support").path,
                                     privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: false)
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        router.rememberProviderSnapshotsForSend([AgentProviderSnapshotFactory.snapshot(
            provider: .distill, models: [AgentModelDescriptor(id: "test", label: "Test", provider: .distill)],
            binaryPath: "/usr/bin/true", authenticated: true, id: "distill-acp")])
        XCTAssertEqual(try CommandReceiptRepository(db: context.db).claim(method: "agent.message.send", clientRequestId: "after-backup-request", ownerFingerprint: "restore-test-owner", paramsHash: "stable-hash"), .unknown)
        let before = try XCTUnwrap(context.queuedMessageRepo.get(id: fixture.queued))
        var attachmentsResolved = false
        router.sendAgentMessageResolvedAttachmentsProbeForTesting = { _ in attachmentsResolved = true }
        for _ in 0..<2 {
            do {
                try await router.drainNextQueuedAgentMessage(thread: fixture.thread, recoverPreparedFromPriorProcess: true)
                XCTFail("restored old intent must not regain automatic authority")
            } catch let error as JSONRPCError {
                XCTAssertEqual(error.code, -32602)
            }
            do {
                _ = try await router.forceAgentQueuedMessageNow(id: fixture.queued)
                XCTFail("explicit force cannot override the restored revoked context")
            } catch let error as JSONRPCError {
                XCTAssertEqual(error.code, -32602)
            }
        }
        await Task.yield()
        XCTAssertEqual(try context.queuedMessageRepo.get(id: fixture.queued), before)
        XCTAssertEqual(try context.runRepo.get(id: fixture.stoppedRun)?.status, .cancelled)
        XCTAssertEqual(try context.runRepo.get(id: fixture.orphanRun)?.status, .interrupted)
        XCTAssertTrue(try context.messageRepo.list(threadId: fixture.thread).isEmpty)
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertFalse(attachmentsResolved)
        XCTAssertFalse(router.preflightListedProviderSnapshotsForTesting)
    }
}
