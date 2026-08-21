import XCTest
import CoreModel
@testable import Persistence

final class BotRemoteControlAuthorityTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: BotStore!
    private var settings: SettingsStore!
    private var authority: BotRemoteControlAuthority!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
        settings = SettingsStore(db: db)
        authority = BotRemoteControlAuthority(db: db, store: store, settings: settings)
    }

    override func tearDown() {
        authority = nil
        settings = nil
        store = nil
        db = nil
    }

    func test_settingsSet_failsWithoutRequestId_becauseSilentLocalSuccessIsForbidden() {
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.settings.set", params: [
                "key": "control_plane",
                "value": false,
            ])
        ) { error in
            let remote = error as? BotRemoteControlAuthority.Error
            XCTAssertEqual(remote, .missingRequest)
        }
    }

    func test_settingsSet_returnsReceiptAndEffectiveReadback_becauseOptimisticWriteCannotMaskFailure() throws {
        let result = try authority.dispatch(method: "bot.settings.set", params: [
            "client_request_id": "set-1",
            "key": "effects",
            "value": true,
        ])
        XCTAssertEqual(result["status"] as? String, "completed")
        XCTAssertNotNil(result["receipt_id"] as? String)
        let readback = result["readback"] as? [String: Any]
        let raw = readback?["raw"] as? [String: Bool]
        let effective = readback?["effective"] as? [String: Bool]
        XCTAssertEqual(raw?["effects"], true)
        XCTAssertEqual(effective?["effects"], false, "Effects stay unavailable even when raw persisted true")
        XCTAssertEqual(effective?["channels"], false)
    }

    func test_effectsAndChannels_remainIneffectiveWhenRawTrue() throws {
        _ = try authority.dispatch(method: "bot.settings.set", params: [
            "client_request_id": "ch-1",
            "key": "channels",
            "value": true,
        ])
        let read = try authority.dispatch(method: "bot.settings.get", params: [:])
        let effective = read["effective"] as? [String: Bool]
        XCTAssertEqual(effective?["channels"], false)
        XCTAssertEqual(effective?["effects"], false)
    }

    func test_sendWithoutRequestId_doesNotEnqueue() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "c1",
            "name": "Piper",
        ])
        let botID = created["bot_id"] as? String
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.send", params: [
                "bot_id": botID as Any,
                "text": "hello",
            ])
        )
        let queue = try authority.dispatch(method: "bot.queue.list", params: ["bot_id": botID as Any])
        XCTAssertEqual((queue["items"] as? [[String: Any]])?.count, 0)
    }

    func test_liveSend_enqueuesUnderHostAuthorityAndSurvivesRelaunch() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "c2",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "s1",
            "bot_id": botID,
            "text": "first turn",
        ])
        let queued = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "s2",
            "bot_id": botID,
            "text": "follow up",
        ])
        XCTAssertEqual((queued["readback"] as? [String: Any])?["enqueued"] as? Bool, true)
        let relaunched = BotRemoteControlAuthority(db: db, store: store, settings: settings)
        let list = try relaunched.dispatch(method: "bot.queue.list", params: ["bot_id": botID])
        let items = try XCTUnwrap(list["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["text"] as? String, "follow up")
        XCTAssertNotNil(items.first?["id"] as? String)
    }

    func test_attachmentGrant_rejectsCrossBotReuse() throws {
        let a = try authority.dispatch(method: "bot.create", params: ["client_request_id": "ca", "name": "A"])
        let b = try authority.dispatch(method: "bot.create", params: ["client_request_id": "cb", "name": "B"])
        let aID = try XCTUnwrap(a["bot_id"] as? String)
        let bID = try XCTUnwrap(b["bot_id"] as? String)
        let staged = try authority.dispatch(method: "bot.attachment.stage", params: [
            "client_request_id": "att1",
            "bot_id": aID,
            "digest": "deadbeef",
            "size": 4,
        ])
        let grantID = try XCTUnwrap((staged["readback"] as? [String: Any])?["id"] as? String)
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.send", params: [
                "client_request_id": "steal",
                "bot_id": bID,
                "text": "use stolen grant",
                "attachment_ids": [grantID],
            ])
        ) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget)
        }
    }

    func test_duplicate_copiesScheduleSpecJSON() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "dup-src",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let spec = "{\"frequency\":\"weekly\",\"weekdays\":[\"monday\"]}"
        _ = try authority.dispatch(method: "bot.routine.create", params: [
            "client_request_id": "r1",
            "bot_id": botID,
            "name": "Morning",
            "prompt": "scan",
            "schedule_spec_json": spec,
        ])
        let copy = try authority.dispatch(method: "bot.duplicate", params: [
            "client_request_id": "dup",
            "bot_id": botID,
        ])
        let specs = (copy["readback"] as? [String: Any])?["schedule_spec_jsons"] as? [String]
        XCTAssertEqual(specs, [spec])
    }

    func test_createAtCap_doesNotCreateBot() throws {
        for i in 0..<BotRemoteControlAuthority.liveAccountCap {
            _ = try authority.dispatch(method: "bot.create", params: [
                "client_request_id": "cap-\(i)",
                "name": "Bot \(i)",
            ])
        }
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.create", params: [
                "client_request_id": "cap-overflow",
                "name": "Overflow",
            ])
        ) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .cap)
        }
        let listed = try authority.dispatch(method: "bot.list", params: [:])
        XCTAssertEqual((listed["bots"] as? [[String: Any]])?.count, BotRemoteControlAuthority.liveAccountCap)
    }

    func test_reservedCapability_neverGetsPositiveParity() {
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.reserved.probe", params: ["capability_id": "U034"])
        ) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .reserved)
        }
        for id in ["U038", "U039", "U045"] {
            XCTAssertThrowsError(
                try authority.dispatch(method: "bot.create", params: [
                    "client_request_id": "res-\(id)",
                    "capability_id": id,
                    "name": "nope",
                ])
            )
        }
    }

    func test_avatar_requiresEachNamedShapeAndHue() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "av",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        XCTAssertEqual(BotRemoteControlAuthority.blobatarShapes.count, 7)
        XCTAssertEqual(BotRemoteControlAuthority.blobatarHues.count, 9)
        for shape in BotRemoteControlAuthority.blobatarShapes {
            for hue in BotRemoteControlAuthority.blobatarHues {
                let result = try authority.dispatch(method: "bot.avatar.set", params: [
                    "client_request_id": "av-\(shape)-\(hue)",
                    "bot_id": botID,
                    "shape": shape,
                    "hue": hue,
                ])
                let readback = result["readback"] as? [String: Any]
                XCTAssertEqual(readback?["shape"] as? String, shape)
                XCTAssertEqual(readback?["hue"] as? String, hue)
            }
        }
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.avatar.set", params: [
                "client_request_id": "av-bad",
                "bot_id": botID,
                "shape": "invented",
                "hue": "auto",
            ])
        )
    }

    func test_browserAction_isHostFirstWithGeneration() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "br",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let result = try authority.dispatch(method: "bot.link.open", params: [
            "client_request_id": "link-1",
            "bot_id": botID,
            "url": "http://127.0.0.1:3000",
        ])
        let readback = result["readback"] as? [String: Any]
        XCTAssertEqual(readback?["host_first"] as? Bool, true)
        XCTAssertEqual(readback?["url"] as? String, "http://127.0.0.1:3000")
        XCTAssertGreaterThan(readback?["generation"] as? Int ?? 0, 0)
        XCTAssertNotNil(result["receipt_id"] as? String)
    }

    func test_filesMutate_rejectsPathEscapeAndReturnsOpaqueHandle() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "fl",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.files.mutate", params: [
                "client_request_id": "esc",
                "bot_id": botID,
                "path": "../etc/passwd",
                "op": "write",
            ])
        )
        let wrote = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "ok",
            "bot_id": botID,
            "path": "MEMORY.md",
            "op": "write",
        ])
        let handle = (wrote["readback"] as? [String: Any])?["handle"] as? String
        XCTAssertTrue(handle?.contains(botID) == true)
        XCTAssertFalse(handle?.contains("/Users") == true)
    }

    func test_forceStop_returnsTerminalReadbackDistinctFromMissingRun() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "st",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "run",
            "bot_id": botID,
            "text": "go",
        ])
        let stopped = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "stop-1",
            "bot_id": botID,
        ])
        let readback = stopped["readback"] as? [String: Any]
        XCTAssertEqual(readback?["force"] as? Bool, true)
        XCTAssertEqual(readback?["terminal"] as? Bool, true)
        XCTAssertEqual(readback?["accepted"] as? Bool, true)
    }

    func test_peerAsk_storesDurableReceiptForLostResponseReplay() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "peer-bot",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.peer.ask", params: [
            "client_request_id": "peer-1",
            "bot_id": botID,
            "handle": "scout",
            "prompt": "status",
        ])
        let again = try authority.dispatch(method: "bot.peer.ask", params: [
            "client_request_id": "peer-1",
            "bot_id": botID,
            "handle": "scout",
            "prompt": "status",
        ])
        XCTAssertEqual(again["request_id"] as? String, "peer-1")
        let status = try authority.dispatch(method: "bot.peer.receipt.status", params: [
            "client_request_id": "peer-1",
        ])
        XCTAssertEqual(status["status"] as? String, "completed")
    }

    func test_guestUsesVncHtml_notEmbedHtml() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "guest",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let started = try authority.dispatch(method: "bot.guest.start", params: [
            "client_request_id": "g1",
            "bot_id": botID,
            "recipe": "pointer",
        ])
        let readback = started["readback"] as? [String: Any]
        XCTAssertEqual(readback?["viewer"] as? String, "/vnc.html")
        XCTAssertEqual(readback?["embed_html_is_not_runtime"] as? Bool, true)
    }

    func test_pinHideDelete_areIndependentDirections() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "phd",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.set_pinned", params: [
            "client_request_id": "pin", "bot_id": botID, "pinned": true,
        ])
        _ = try authority.dispatch(method: "bot.set_hidden", params: [
            "client_request_id": "hide", "bot_id": botID, "hidden": true,
        ])
        let hiddenList = try authority.dispatch(method: "bot.list", params: ["include_hidden": false])
        XCTAssertEqual((hiddenList["bots"] as? [[String: Any]])?.count, 0)
        let shown = try authority.dispatch(method: "bot.list", params: ["include_hidden": true])
        XCTAssertEqual((shown["bots"] as? [[String: Any]])?.first?["pinned"] as? Bool, true)
        let pending = try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "del-ask", "bot_id": botID,
        ])
        XCTAssertEqual((pending["readback"] as? [String: Any])?["confirm_required"] as? Bool, true)
        XCTAssertEqual(try store.list(includeHidden: true).count, 1)
        _ = try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "del-yes", "bot_id": botID, "confirm": "delete",
        ])
        XCTAssertEqual(try store.list(includeHidden: true).count, 0)
    }

    func test_newSaveAndExistingSave_areDistinctPres() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "new",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let first = try authority.dispatch(method: "bot.save", params: [
            "client_request_id": "save-new",
            "bot_id": botID,
            "name": "Piper",
        ])
        XCTAssertEqual((first["readback"] as? [String: Any])?["pre"] as? String, "UNPUBLISHED_NEW")
        let second = try authority.dispatch(method: "bot.save", params: [
            "client_request_id": "save-old",
            "bot_id": botID,
            "name": "Piper",
        ])
        XCTAssertEqual((second["readback"] as? [String: Any])?["pre"] as? String, "EXISTING")
    }
}
