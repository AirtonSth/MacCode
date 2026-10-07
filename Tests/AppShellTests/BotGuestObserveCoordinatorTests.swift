import XCTest
import CoreModel
@testable import AppShell
@testable import Persistence

/// P6: `bot.guest.state` with `observe: true` captures a fresh frame at 1-2 fps,
/// latest wins, and only while a viewer asks.
@MainActor
final class BotGuestObserveCoordinatorTests: XCTestCase {
    private let hostID = "test-host"
    private var db: SQLiteDB!
    private var authority: BotRemoteControlAuthority!
    private var supportDir: URL!
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var captures = 0
    private var captureGate: CheckedContinuation<Void, Never>?
    private var gated = false
    private var captureError: Error?
    private var containerRunning = true

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-guest-observe-coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        authority = BotRemoteControlAuthority(
            db: db,
            store: BotStore(db: db),
            settings: SettingsStore(db: db),
            appSupportDirectory: supportDir
        )
        authority.computerControl = BotComputerControl()
    }

    override func tearDown() {
        authority = nil
        db = nil
        if let supportDir { try? FileManager.default.removeItem(at: supportDir) }
        supportDir = nil
    }

    private func makeCoordinator() -> BotGuestObserveCoordinator {
        BotGuestObserveCoordinator(
            authority: authority,
            capture: { [unowned self] _ in
                self.captures += 1
                if self.gated {
                    await withCheckedContinuation { self.captureGate = $0 }
                }
                if let error = self.captureError { throw error }
                return .init(
                    containerID: "container",
                    viewerPath: "/vnc.html",
                    pixelWidth: 1_280,
                    pixelHeight: 800,
                    pngBase64: "cG5n",
                    pngHash: "capture-\(self.captures)"
                )
            },
            isContainerRunning: { [unowned self] _ in self.containerRunning },
            now: { [unowned self] in self.clock }
        )
    }

    private func createBot() throws -> (id: String, botID: BotID) {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "create-\(UUID().uuidString)",
            "name": "Piper",
        ])
        let id = try XCTUnwrap(created["bot_id"] as? String)
        return (id, BotID(try XCTUnwrap(UUID(uuidString: id))))
    }

    private func params(_ botID: String) -> [String: Any] {
        ["bot_id": botID, "host_id": hostID, "observe": true]
    }

    private func plainState(_ botID: String) throws -> [String: Any] {
        try authority.dispatch(method: "bot.guest.state", params: ["bot_id": botID, "host_id": hostID])
    }

    private func frameID(_ state: [String: Any]) -> String? {
        (state["frame"] as? [String: Any])?["frame_id"] as? String
    }

    private func outcome(_ state: [String: Any]) -> String? {
        (state["observe"] as? [String: Any])?["outcome"] as? String
    }

    private func waitForCaptureToBlock() async {
        for _ in 0..<1_000 where captureGate == nil { await Task.yield() }
    }

    func test_observeOnARunningBotReturnsANewFrameEveryCaptureAndIsRateLimited() async throws {
        // WHY: the viewer's whole point is a fresh frame (new frame_id) while
        // the bot works; a client polling faster than 2 fps gets the cached
        // frame instead of a new Docker screenshot.
        let bot = try createBot()
        let coordinator = makeCoordinator()

        let first = try await coordinator.state(params: params(bot.id))
        XCTAssertEqual(outcome(first), "captured", "the bot's own running container is adopted")
        XCTAssertEqual(first["status"] as? String, "running")
        XCTAssertEqual((first["observe"] as? [String: Any])?["min_interval_ms"] as? Int, 500)
        XCTAssertEqual(first["controlled_by_user"] as? Bool, false)
        let firstFrame = try XCTUnwrap(frameID(first))

        clock = clock.addingTimeInterval(0.2)
        let fast = try await coordinator.state(params: params(bot.id))
        XCTAssertEqual(outcome(fast), "rate_limited")
        XCTAssertEqual(frameID(fast), firstFrame)
        XCTAssertEqual(captures, 1)

        clock = clock.addingTimeInterval(0.4)
        let next = try await coordinator.state(params: params(bot.id))
        XCTAssertEqual(outcome(next), "captured")
        XCTAssertNotEqual(frameID(next), firstFrame)
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(((next["frame"] as? [String: Any])?["sequence"] as? Int), 1)
        XCTAssertEqual(frameID(try plainState(bot.id)), frameID(next), "a plain read serves the latest frame")
    }

    func test_concurrentObserversShareOneCapture() async throws {
        let bot = try createBot()
        let coordinator = makeCoordinator()
        gated = true
        let a = Task { try await coordinator.state(params: self.params(bot.id)) }
        await waitForCaptureToBlock()
        let b = Task { try await coordinator.state(params: self.params(bot.id)) }
        for _ in 0..<50 { await Task.yield() }
        captureGate?.resume()
        let first = try await a.value
        let second = try await b.value
        XCTAssertEqual(captures, 1, "the second viewer joins the capture in flight")
        XCTAssertEqual(outcome(first), "captured")
        XCTAssertEqual(outcome(second), "coalesced")
        XCTAssertEqual(frameID(first), frameID(second))
    }

    func test_aCaptureThatFinishesAfterTheGuestStoppedIsDropped() async throws {
        // WHY (A->B race): a stop that lands during a capture is newer; the old
        // capture must not revive the grant or paint over the stopped state.
        let bot = try createBot()
        let coordinator = makeCoordinator()
        let adopted = try await coordinator.state(params: params(bot.id))
        let runtime = try XCTUnwrap(adopted["runtime"] as? [String: Any])
        let grant = try XCTUnwrap(runtime["grant_id"] as? String)

        clock = clock.addingTimeInterval(1)
        gated = true
        let observing = Task { try await coordinator.state(params: self.params(bot.id)) }
        await waitForCaptureToBlock()
        XCTAssertTrue(authority.markObservedGuestStopped(botID: bot.botID, grantID: grant))
        captureGate?.resume()
        let result = try await observing.value
        XCTAssertEqual(outcome(result), "stale_dropped")
        XCTAssertEqual(result["status"] as? String, "stopped")
        XCTAssertNil(result["frame"])
    }

    func test_captureFailureIsReportedAndKeepsTheLastFrame() async throws {
        let bot = try createBot()
        let coordinator = makeCoordinator()
        let first = try await coordinator.state(params: params(bot.id))
        let shown = try XCTUnwrap(frameID(first))

        clock = clock.addingTimeInterval(1)
        captureError = BotComputerGuestError.observeFailed
        let failed = try await coordinator.state(params: params(bot.id))
        XCTAssertEqual(outcome(failed), "capture_failed")
        XCTAssertNotNil((failed["observe"] as? [String: Any])?["error"] as? String)
        XCTAssertEqual(failed["status"] as? String, "running")
        XCTAssertEqual(frameID(failed), shown, "the cached frame stays; nothing pretends to be fresh")

        clock = clock.addingTimeInterval(1)
        captureError = BotComputerGuestError.notReady
        let gone = try await coordinator.state(params: params(bot.id))
        XCTAssertEqual(outcome(gone), "stopped")
        XCTAssertEqual(gone["status"] as? String, "stopped")
    }

    func test_noContainerMeansNoAdoptionAndNoCapture() async throws {
        let bot = try createBot()
        containerRunning = false
        let coordinator = makeCoordinator()
        let result = try await coordinator.state(params: params(bot.id))
        XCTAssertEqual(outcome(result), "not_running")
        XCTAssertEqual(result["status"] as? String, "stopped")
        XCTAssertEqual(captures, 0)
    }

    func test_watchingLastsOnlyAShortWhileAfterTheLastObserve() async throws {
        // WHY: agent-step events are sent only while a viewer is watching.
        let bot = try createBot()
        let coordinator = makeCoordinator()
        XCTAssertFalse(coordinator.isWatching(bot.botID))
        _ = try await coordinator.state(params: params(bot.id))
        XCTAssertTrue(coordinator.isWatching(bot.botID))
        clock = clock.addingTimeInterval(BotGuestObserveCoordinator.watchWindow + 0.1)
        XCTAssertFalse(coordinator.isWatching(bot.botID))
    }

    func test_anotherHostsBindingIsRefusedBeforeAnyCapture() async throws {
        let bot = try createBot()
        _ = try plainState(bot.id)
        let coordinator = makeCoordinator()
        do {
            _ = try await coordinator.state(params: ["bot_id": bot.id, "host_id": "other-host", "observe": true])
            XCTFail("expected a guest conflict")
        } catch {
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .guestConflict)
        }
        XCTAssertEqual(captures, 0)
    }
}
