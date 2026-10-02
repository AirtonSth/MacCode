import AppKit
import XCTest
@testable import AppShell
import CoreModel
@testable import SocketServer
@testable import Surfaces

/// WHY: an scp result is arbitrary-size. It must stream through the terminal's
/// single system-output source, and a busy terminal must refuse before scp runs.
@MainActor
final class SSHTransferSystemOutputTests: XCTestCase {
    private struct NoopSSHPasswordStore: SSHPasswordStoring {
        func save(account: String, password: String) {}
        func load(account: String) -> String? { nil }
        func delete(account: String) {}
    }

    private final class TerminalBackedTransferSurface: NSObject, SSHTransferSurface {
        let descriptor = SurfaceDescriptor(
            type: .ssh, title: "scp stream", metadata: ["workspace": WorkspaceID().value.uuidString])
        let view = NSView()
        let sshTransferProfile: SSHHostProfile? = SSHHostProfile(label: "T", destination: "example.invalid")
        let terminal: TerminalSurface
        var transferTerminal: TerminalSurface? { terminal }

        init(terminal: TerminalSurface) { self.terminal = terminal }
        var isBusy: Bool { false }
        func focus() {}
        func unfocus() {}
        func close() { terminal.close() }
        func sendText(_ text: String) {}
        func readText() -> String { terminal.readText() }
        func snapshot() -> [String: String] { [:] }
        func appendSystemText(_ raw: String) { terminal.appendSystemText(raw) }
    }

    private final class RunCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static let eightMiB = String(repeating: "x", count: 8 * 1024 * 1024 - 1) + "\n"

    private func makeFixture(counter: RunCounter) throws -> (AppCommandRouter, TerminalBackedTransferSurface) {
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: NSTemporaryDirectory() + "RC2SCPStream-" + UUID().uuidString
        )
        let router = AppCommandRouter(
            context: context,
            sshPasswordStore: NoopSSHPasswordStore(),
            sshCommandRunner: { _, _, _ in
                counter.bump()
                return (exitCode: 0, output: Self.eightMiB)
            }
        )
        context.router = router
        let terminal = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "scp terminal",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        let surface = TerminalBackedTransferSurface(terminal: terminal)
        SurfaceRegistry.shared.register(surface)
        return (router, surface)
    }

    override func tearDown() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        super.tearDown()
    }

    private func waitForStreamEnd(_ terminal: TerminalSurface) async {
        let deadline = Date().addingTimeInterval(30)
        while terminal.systemOutputOwnedForTesting, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(terminal.systemOutputOwnedForTesting)
    }

    func testSyncTransferStreamsEightMiBResultThenCompletionNotice() async throws {
        let counter = RunCounter()
        let (router, surface) = try makeFixture(counter: counter)
        let result = try router.sshTransferUpload(
            surface: surface.descriptor.id, localPath: "/tmp/a", remotePath: "/tmp/b")
        XCTAssertEqual(result.objectValue?["ok"], .bool(true))
        XCTAssertEqual(result.objectValue?["output"]?.stringValue?.utf8.count, Self.eightMiB.utf8.count)
        await waitForStreamEnd(surface.terminal)
        XCTAssertTrue(surface.terminal.readText().contains("[ssh upload completed]"))
        XCTAssertFalse(surface.terminal.runtimeHealth().outputPartial)
    }

    func testBusyTerminalRefusesSyncTransferBeforeTheCommandRuns() async throws {
        let counter = RunCounter()
        let (router, surface) = try makeFixture(counter: counter)
        let held = try XCTUnwrap(surface.terminal.reserveSystemOutput())
        XCTAssertThrowsError(try router.sshTransferUpload(
            surface: surface.descriptor.id, localPath: "/tmp/a", remotePath: "/tmp/b")
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32021)
        }
        XCTAssertEqual(counter.count, 0, "scp must not run when the output slot is taken")
        held.cancel()
    }

    func testAsyncTransferNeverRunsAfterItsTargetIsRemovedWhileWaitingForAdmission() async throws {
        let counter = RunCounter()
        let (router, surface) = try makeFixture(counter: counter)
        let held = try XCTUnwrap(surface.terminal.reserveSystemOutput())
        let id = surface.descriptor.id
        let task = Task { @MainActor in
            try await router.sshTransferDownloadAsync(surface: id, remotePath: "/tmp/b", localPath: "/tmp/a")
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(counter.count, 0)
        SurfaceRegistry.shared.unregister(id)
        surface.close()
        do {
            _ = try await task.value
            XCTFail("a removed target must never become an admitted legacy fallback")
        } catch {
            XCTAssertEqual(error as? LayoutError, .surfaceNotFound)
        }
        XCTAssertEqual(counter.count, 0)
        held.cancel()
    }

    func testAsyncTransferWaitsForAdmissionThenStreamsOnce() async throws {
        let counter = RunCounter()
        let (router, surface) = try makeFixture(counter: counter)
        let held = try XCTUnwrap(surface.terminal.reserveSystemOutput())
        let id = surface.descriptor.id
        let task = Task { @MainActor in
            try await router.sshTransferDownloadAsync(surface: id, remotePath: "/tmp/b", localPath: "/tmp/a")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counter.count, 0, "no result may be produced while admission is pending")
        held.cancel()
        let result = try await task.value
        XCTAssertEqual(result.objectValue?["ok"], .bool(true))
        XCTAssertEqual(counter.count, 1)
        await waitForStreamEnd(surface.terminal)
        XCTAssertTrue(surface.terminal.readText().contains("[ssh download completed]"))
    }
}
