import XCTest
import CoreModel
@testable import Persistence

/// P6 host authority: the paired live viewer's frame CAS, observe target,
/// input tolerance and `bot.guest.control`.
final class BotGuestObserveAuthorityTests: XCTestCase {
    private let hostID = "test-host"
    private var db: SQLiteDB!
    private var authority: BotRemoteControlAuthority!
    private var control: BotComputerControl!
    private var supportDir: URL!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-guest-observe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        authority = BotRemoteControlAuthority(
            db: db,
            store: BotStore(db: db),
            settings: SettingsStore(db: db),
            appSupportDirectory: supportDir
        )
        control = BotComputerControl()
        authority.computerControl = control
    }

    override func tearDown() {
        authority = nil
        db = nil
        control = nil
        if let supportDir { try? FileManager.default.removeItem(at: supportDir) }
        supportDir = nil
    }

    // MARK: - Helpers

    private func createBot() throws -> (id: String, botID: BotID) {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "create-\(UUID().uuidString)",
            "name": "Piper",
        ])
        let id = try XCTUnwrap(created["bot_id"] as? String)
        return (id, BotID(try XCTUnwrap(UUID(uuidString: id))))
    }

    private func state(_ botID: String) throws -> [String: Any] {
        try authority.dispatch(method: "bot.guest.state", params: ["bot_id": botID, "host_id": hostID])
    }

    private func task(_ botID: String, axis: String) throws -> [String: Any] {
        let catalog = try XCTUnwrap(try state(botID)["task_catalog"] as? [String: Any])
        let tasks = try XCTUnwrap(catalog["tasks"] as? [[String: Any]])
        return try XCTUnwrap(tasks.first { $0["axis"] as? String == axis })
    }

    /// A guest a paired client started and the host settled with one frame.
    private func runningGuest(_ botID: String) throws -> [String: Any] {
        let start = try task(botID, axis: "start")
        let started = try authority.dispatch(method: "bot.guest.start", params: [
            "client_request_id": "start-\(UUID().uuidString)",
            "bot_id": botID,
            "host_id": hostID,
            "task_id": try XCTUnwrap(start["id"] as? String),
            "recipe_id": try XCTUnwrap(start["recipe_id"] as? String),
        ])
        var readback = try XCTUnwrap(started["readback"] as? [String: Any])
        let runtime = try XCTUnwrap(readback["runtime"] as? [String: Any])
        readback["status"] = "running"
        readback["frame"] = [
            "runtime": runtime,
            "frame_id": UUID().uuidString.lowercased(),
            "sequence": 0,
            "pixel_width": 1_600,
            "pixel_height": 1_200,
            "png_base64": "",
            "png_hash": "first",
        ]
        authority.settle(
            requestID: try XCTUnwrap(started["request_id"] as? String),
            status: .completed,
            readback: readback
        )
        return try state(botID)
    }

    private func frame(_ hash: String, width: Int = 1_600, height: Int = 1_200) -> BotRemoteControlAuthority.ObservedGuestFrame {
        .init(
            containerID: "container",
            viewerPath: "/vnc.html",
            pixelWidth: width,
            pixelHeight: height,
            pngBase64: "cG5n",
            pngHash: hash
        )
    }

    private func grantAndFrame(_ state: [String: Any]) throws -> (grant: String, frame: String?) {
        let runtime = try XCTUnwrap(state["runtime"] as? [String: Any])
        return (
            try XCTUnwrap(runtime["grant_id"] as? String),
            (state["frame"] as? [String: Any])?["frame_id"] as? String
        )
    }

    private func pointer(_ botID: String, runtime: [String: Any], beforeFrameID: String, requestID: String) throws -> [String: Any] {
        let pointer = try task(botID, axis: "pointer")
        return try authority.dispatch(method: "bot.guest.input", params: [
            "client_request_id": requestID,
            "bot_id": botID,
            "host_id": hostID,
            "task_id": try XCTUnwrap(pointer["id"] as? String),
            "runtime": runtime,
            "before_frame_id": beforeFrameID,
            "input": ["kind": "pointer", "x": 1, "y": 1],
        ])
    }

    // MARK: - Observed frames

    func test_observedFrameGetsNewIDAndHigherSequenceOnlyOnSameGrantAndFrame() throws {
        // WHY: a viewer must see a new frame each capture, but a capture that
        // started before a newer frame or a stop/rebuild must never overwrite it.
        let bot = try createBot()
        let before = try runningGuest(bot.id)
        let (grant, firstFrame) = try grantAndFrame(before)

        XCTAssertTrue(authority.applyObservedGuestFrame(
            botID: bot.botID, grantID: grant, expectedFrameID: firstFrame, frame: frame("second")
        ))
        let after = try state(bot.id)
        let second = try XCTUnwrap(after["frame"] as? [String: Any])
        XCTAssertNotEqual(second["frame_id"] as? String, firstFrame)
        XCTAssertEqual(second["sequence"] as? Int, 1)
        XCTAssertEqual(second["png_hash"] as? String, "second")
        XCTAssertEqual(after["before_frame_id"] as? String, firstFrame)
        XCTAssertEqual(after["after_frame_id"] as? String, second["frame_id"] as? String)
        XCTAssertEqual(
            (second["runtime"] as? NSDictionary), (after["runtime"] as? NSDictionary),
            "the iPhone codec requires frame.runtime == runtime"
        )

        XCTAssertFalse(authority.applyObservedGuestFrame(
            botID: bot.botID, grantID: grant, expectedFrameID: firstFrame, frame: frame("stale")
        ), "a capture started on the replaced frame loses")
        XCTAssertFalse(authority.applyObservedGuestFrame(
            botID: bot.botID, grantID: UUID().uuidString, expectedFrameID: second["frame_id"] as? String, frame: frame("other")
        ), "a capture from another grant loses")
        XCTAssertEqual(((try state(bot.id))["frame"] as? [String: Any])?["png_hash"] as? String, "second")
    }

    func test_inputAcceptsFramesAnObserveJustReplacedButNotOlderOnesOrOtherGrants() throws {
        // WHY: at 1-2 fps an observe can replace the frame between the user's
        // tap and its arrival; that tap is still on the screen they saw. Frames
        // from long ago or from another runtime grant stay rejected.
        let bot = try createBot()
        authority.onGuestInput = { _, _, _, _ in }
        let running = try runningGuest(bot.id)
        let grant = try grantAndFrame(running).grant
        var current = try grantAndFrame(running).frame
        let tapped = try XCTUnwrap(current)
        var seen: [String] = []
        for index in 0..<5 {
            XCTAssertTrue(authority.applyObservedGuestFrame(
                botID: bot.botID, grantID: grant, expectedFrameID: current, frame: frame("f\(index)")
            ))
            seen.append(try XCTUnwrap(current))
            current = try grantAndFrame(try state(bot.id)).frame
        }
        let runtime = try XCTUnwrap(try state(bot.id)["runtime"] as? [String: Any])
        // `tapped` is 5 replacements old: outside the last 4.
        XCTAssertThrowsError(try pointer(bot.id, runtime: runtime, beforeFrameID: tapped, requestID: "old"))
        let recent = try XCTUnwrap(seen.last)
        XCTAssertEqual(
            try pointer(bot.id, runtime: runtime, beforeFrameID: recent, requestID: "recent")["status"] as? String,
            "accepted"
        )
        XCTAssertThrowsError(
            try pointer(bot.id, runtime: runtime, beforeFrameID: UUID().uuidString, requestID: "unknown")
        )
    }

    func test_aSettledInputFrameRetiresTheFramesAnObserveReplaced() throws {
        // WHY: after an input lands, the screen changed; a second tap aimed at
        // a frame from before that input would hit something else.
        let bot = try createBot()
        var stored: [String: Any] = [:]
        authority.onGuestInput = { _, _, _, context in stored = context }
        let running = try runningGuest(bot.id)
        let (grant, first) = try grantAndFrame(running)
        let firstID = try XCTUnwrap(first)
        XCTAssertTrue(authority.applyObservedGuestFrame(
            botID: bot.botID, grantID: grant, expectedFrameID: first, frame: frame("observed")
        ))
        // An observe refreshes the runtime's container id: input names the current runtime.
        let runtime = try XCTUnwrap(try state(bot.id)["runtime"] as? [String: Any])
        let observed = try XCTUnwrap(try grantAndFrame(try state(bot.id)).frame)
        let accepted = try pointer(bot.id, runtime: runtime, beforeFrameID: firstID, requestID: "tap-on-replaced")
        XCTAssertEqual(accepted["status"] as? String, "accepted", "the replaced frame is still the screen the user saw")

        var readback = stored
        readback["status"] = "running"
        readback["frame"] = [
            "runtime": runtime,
            "frame_id": UUID().uuidString.lowercased(),
            "sequence": 2,
            "pixel_width": 1_600,
            "pixel_height": 1_200,
            "png_base64": "",
            "png_hash": "after-tap",
        ]
        authority.settle(requestID: try XCTUnwrap(accepted["request_id"] as? String), status: .completed, readback: readback)
        XCTAssertThrowsError(try pointer(bot.id, runtime: runtime, beforeFrameID: firstID, requestID: "second-tap")) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .guestConflict)
        }
        XCTAssertThrowsError(try pointer(bot.id, runtime: runtime, beforeFrameID: observed, requestID: "third-tap"))
    }

    func test_aReplacedFrameOfAnotherSizeIsNotAnInputTarget() throws {
        // WHY: coordinates are in the named frame's pixels and run on the
        // screen as it is now; after a resolution change they would land elsewhere.
        let bot = try createBot()
        authority.onGuestInput = { _, _, _, _ in }
        let running = try runningGuest(bot.id)
        let (grant, first) = try grantAndFrame(running)
        XCTAssertTrue(authority.applyObservedGuestFrame(
            botID: bot.botID, grantID: grant, expectedFrameID: first, frame: frame("small", width: 800, height: 600)
        ))
        let runtime = try XCTUnwrap(try state(bot.id)["runtime"] as? [String: Any])
        XCTAssertThrowsError(try pointer(bot.id, runtime: runtime, beforeFrameID: try XCTUnwrap(first), requestID: "old-size")) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .guestConflict)
        }
        let current = try XCTUnwrap(try grantAndFrame(try state(bot.id)).frame)
        XCTAssertEqual(try pointer(bot.id, runtime: runtime, beforeFrameID: current, requestID: "new-size")["status"] as? String, "accepted")
    }

    func test_settleAfterAnObservedFrameKeepsSequenceIncreasing() throws {
        // WHY: an input result is built on the frame the input started from; if
        // an observe replaced it meanwhile, the iPhone still needs a newer sequence.
        let bot = try createBot()
        var stored: [String: Any] = [:]
        authority.onGuestInput = { _, _, _, context in stored = context }
        let running = try runningGuest(bot.id)
        let runtime = try XCTUnwrap(running["runtime"] as? [String: Any])
        let (grant, first) = try grantAndFrame(running)
        let accepted = try pointer(bot.id, runtime: runtime, beforeFrameID: try XCTUnwrap(first), requestID: "tap")
        XCTAssertTrue(authority.applyObservedGuestFrame(
            botID: bot.botID, grantID: grant, expectedFrameID: first, frame: frame("observed")
        ))
        var readback = stored
        readback["frame"] = [
            "runtime": runtime,
            "frame_id": UUID().uuidString.lowercased(),
            "sequence": 1,
            "pixel_width": 1_600,
            "pixel_height": 1_200,
            "png_base64": "",
            "png_hash": "after-tap",
        ]
        readback["status"] = "running"
        authority.settle(requestID: try XCTUnwrap(accepted["request_id"] as? String), status: .completed, readback: readback)
        let settled = try XCTUnwrap(try state(bot.id)["frame"] as? [String: Any])
        XCTAssertEqual(settled["png_hash"] as? String, "after-tap")
        XCTAssertEqual(settled["sequence"] as? Int, 2)
    }

    // MARK: - Adoption and stop

    func test_observeTargetIsAdoptableOnlyForAStoppedStateOfThisHostAndNeverAfterRevoke() throws {
        // WHY: a VM bot's own run starts its guest; observe reports it as
        // adoptable (the client adopts with bot.guest.start), but never for
        // another host's binding or a grant the user revoked.
        let bot = try createBot()
        XCTAssertEqual(try state(bot.id)["status"] as? String, "stopped")
        XCTAssertEqual(authority.guestObserveTarget(botID: bot.botID, hostID: hostID), .adoptable)
        XCTAssertEqual(authority.guestObserveTarget(botID: bot.botID, hostID: "other-host"), .unavailable)

        let running = try runningGuest(bot.id)
        let (grant, frameID) = try grantAndFrame(running)
        XCTAssertEqual(authority.guestObserveTarget(botID: bot.botID, hostID: hostID), .running(grantID: grant, frameID: frameID))

        // Revoked access is the user's choice: observe must not undo it.
        let revoke = try task(bot.id, axis: "grantRevoke")
        _ = try authority.dispatch(method: "bot.guest.revoke", params: [
            "client_request_id": "revoke",
            "bot_id": bot.id,
            "host_id": hostID,
            "task_id": try XCTUnwrap(revoke["id"] as? String),
            "runtime": try XCTUnwrap(running["runtime"] as? [String: Any]),
        ])
        XCTAssertEqual(authority.guestObserveTarget(botID: bot.botID, hostID: hostID), .unavailable)
    }

    func test_markStoppedEndsOnlyTheWatchedGrant() throws {
        let bot = try createBot()
        let (grant, _) = try grantAndFrame(try runningGuest(bot.id))
        XCTAssertFalse(authority.markObservedGuestStopped(botID: bot.botID, grantID: "older-grant"))
        XCTAssertEqual(try state(bot.id)["status"] as? String, "running")
        XCTAssertTrue(authority.markObservedGuestStopped(botID: bot.botID, grantID: grant))
        let stopped = try state(bot.id)
        XCTAssertEqual(stopped["status"] as? String, "stopped")
        XCTAssertNil(stopped["runtime"])
        XCTAssertNil(stopped["frame"])
        XCTAssertEqual(stopped["grant_invalidated"] as? Bool, true)
    }

    // MARK: - bot.guest.control

    func test_guestControlTakesAndReleasesTheBotComputerWithIdempotentReceipts() throws {
        // WHY: Take must actually stop the bot's act/exec (BotComputerControl),
        // be visible as controlled_by_user, and a retried request must not flip it twice.
        let bot = try createBot()
        var changes: [Bool] = []
        authority.onGuestControlChanged = { _, took in changes.append(took) }
        XCTAssertEqual(try state(bot.id)["controlled_by_user"] as? Bool, false)

        let params: [String: Any] = ["client_request_id": "take-1", "bot_id": bot.id, "host_id": hostID, "action": "take"]
        let taken = try authority.dispatch(method: "bot.guest.control", params: params)
        XCTAssertEqual(taken["status"] as? String, "completed")
        let readback = try XCTUnwrap(taken["readback"] as? [String: Any])
        XCTAssertEqual(readback["controlled_by_user"] as? Bool, true)
        XCTAssertEqual(readback["control_action"] as? String, "take")
        XCTAssertEqual(readback["host_id"] as? String, hostID)
        XCTAssertTrue(control.isControlledByUser(bot.botID))
        XCTAssertEqual(try state(bot.id)["controlled_by_user"] as? Bool, true)

        let replay = try authority.dispatch(method: "bot.guest.control", params: params)
        XCTAssertEqual(replay["receipt_id"] as? String, taken["receipt_id"] as? String)
        XCTAssertEqual(changes, [true], "a replay does not run the effect again")

        let released = try authority.dispatch(method: "bot.guest.control", params: [
            "client_request_id": "release-1", "bot_id": bot.id, "host_id": hostID, "action": "release",
        ])
        XCTAssertEqual((released["readback"] as? [String: Any])?["controlled_by_user"] as? Bool, false)
        XCTAssertFalse(control.isControlledByUser(bot.botID))
        XCTAssertEqual(changes, [true, false])
    }

    func test_guestControlReceiptCarriesNoScreenshot() throws {
        // WHY: receipts are stored and replayed; a multi-MB PNG in each take or
        // release receipt would bloat the sidecar and every retry.
        let bot = try createBot()
        XCTAssertNotNil(try runningGuest(bot.id)["frame"])
        let taken = try authority.dispatch(method: "bot.guest.control", params: [
            "client_request_id": "take-frame", "bot_id": bot.id, "host_id": hostID, "action": "take",
        ])
        let readback = try XCTUnwrap(taken["readback"] as? [String: Any])
        XCTAssertNil(readback["frame"])
        XCTAssertEqual(readback["status"] as? String, "running")
        XCTAssertNotNil(try state(bot.id)["frame"], "the guest state keeps its frame")
    }

    func test_guestControlRejectsUnknownActionsAndAnotherHostsBinding() throws {
        let bot = try createBot()
        _ = try state(bot.id)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.guest.control", params: [
            "client_request_id": "bad", "bot_id": bot.id, "host_id": hostID, "action": "steal",
        ])) { error in
            XCTAssertEqual((error as? BotRemoteControlAuthority.Error)?.code, -32602)
        }
        XCTAssertThrowsError(try authority.dispatch(method: "bot.guest.control", params: [
            "client_request_id": "cross", "bot_id": bot.id, "host_id": "other-host", "action": "take",
        ])) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .guestConflict)
        }
        XCTAssertFalse(control.isControlledByUser(bot.botID), "a refused call changes nothing")
    }
}
