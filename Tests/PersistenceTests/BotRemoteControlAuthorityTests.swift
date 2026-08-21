import XCTest
import CoreModel
@testable import Persistence

final class BotRemoteControlAuthorityTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: BotStore!
    private var settings: SettingsStore!
    private var authority: BotRemoteControlAuthority!
    private var supportDir: URL!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
        settings = SettingsStore(db: db)
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-bot-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        authority = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
    }

    override func tearDown() {
        authority = nil
        settings = nil
        store = nil
        db = nil
        if let supportDir {
            try? FileManager.default.removeItem(at: supportDir)
        }
        supportDir = nil
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
        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
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

    func test_queuedFollowUp_isVisibleInBotStoreAfterEnqueue() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "store-q",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "store-q-1",
            "bot_id": botID,
            "text": "first turn",
        ])
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "store-q-2",
            "bot_id": botID,
            "text": "follow up",
        ])
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        let stored = try store.listQueuedFollowUps(botID: BotID(uuid))
        XCTAssertEqual(stored.map(\.text), ["follow up"])
        XCTAssertFalse(stored.isEmpty, "queue must land in BotStore, not a sidecar map")
    }

    func test_filesMutate_writesBotHomeDiskAndSurvivesRelaunchList() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "disk",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "disk-w",
            "bot_id": botID,
            "path": "notes.txt",
            "op": "write",
            "contents": "from remote",
        ])
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        let bot = try XCTUnwrap(store.get(id: BotID(uuid)))
        let home = BotHome(appSupportDirectory: supportDir, bot: bot)
        let url = try home.resolvedURL("notes.txt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "from remote")

        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        let listed = try relaunched.dispatch(method: "bot.files.list", params: ["bot_id": botID])
        let entries = try XCTUnwrap(listed["entries"] as? [[String: Any]])
        XCTAssertTrue(
            entries.contains { ($0["path"] as? String) == "notes.txt" },
            "files.list must read the Bot Home disk after relaunch, got \(entries.map { $0["path"] as? String })"
        )
    }

    func test_browserAction_persistsBotBrowserStoreTarget() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "br-store",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.link.open", params: [
            "client_request_id": "br-open",
            "bot_id": botID,
            "url": "http://127.0.0.1:3000",
            "title": "Dev",
        ])
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        let persisted = try XCTUnwrap(
            BotBrowserStore(appSupportDirectory: supportDir).loadTarget(botID: BotID(uuid))
        )
        XCTAssertEqual(persisted.url, "http://127.0.0.1:3000")
        XCTAssertEqual(persisted.title, "Dev")
        let pending = try BotBrowserStore(appSupportDirectory: supportDir).loadPendingOpens()
        XCTAssertEqual(pending.last?.url, "http://127.0.0.1:3000")
    }

    func test_browserAction_postsPendingOpenNotification() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "br-note",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        var posted: [Notification.Name] = []
        authority.notifyBrowserPendingOpen = { posted.append($0) }
        _ = try authority.dispatch(method: "bot.link.open", params: [
            "client_request_id": "br-note-open",
            "bot_id": botID,
            "url": "http://127.0.0.1:4000",
        ])
        XCTAssertEqual(posted, [BotBrowserHost.pendingOpenNotification])
        let state = try authority.dispatch(method: "bot.browser.state", params: ["bot_id": botID])
        XCTAssertEqual(state["url"] as? String, "http://127.0.0.1:4000")
        XCTAssertEqual(state["host_first"] as? Bool, true)
    }

    func test_dockerClear_wipesGuestHomeOnDisk() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "dock",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.files.location.set", params: [
            "client_request_id": "dock-loc",
            "bot_id": botID,
            "root": "docker_home",
        ])
        _ = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "dock-w",
            "bot_id": botID,
            "path": "scratch.txt",
            "op": "write",
            "contents": "guest bytes",
        ])
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        let guest = BotGuestHome.url(appSupport: supportDir, botID: BotID(uuid))
        XCTAssertTrue(FileManager.default.fileExists(atPath: guest.appendingPathComponent("scratch.txt").path))
        _ = try authority.dispatch(method: "bot.docker.clear", params: [
            "client_request_id": "dock-c",
            "bot_id": botID,
            "confirm": "clear",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: guest.path))
    }

    func test_guestStart_createsGuestHomeAndKeepsVncViewer() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "g-home",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let started = try authority.dispatch(method: "bot.guest.start", params: [
            "client_request_id": "g-start",
            "bot_id": botID,
            "recipe": "pointer",
        ])
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: BotGuestHome.url(appSupport: supportDir, botID: BotID(uuid)).path
            )
        )
        XCTAssertEqual((started["readback"] as? [String: Any])?["viewer"] as? String, "/vnc.html")
        XCTAssertEqual(started["status"] as? String, "accepted")
        XCTAssertEqual((started["readback"] as? [String: Any])?["status"] as? String, "starting")
    }

    func test_filesOpenTabAndSplit_requireDiskAndCallLiveSurfaceHook() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "open-src",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let wrote = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "open-w",
            "bot_id": botID,
            "path": "notes.txt",
            "op": "write",
            "contents": "surface",
        ])
        let handle = try XCTUnwrap((wrote["readback"] as? [String: Any])?["handle"] as? String)
        var opened: [(String, Bool, String)] = []
        authority.onOpenFile = { _, path, split, root in
            opened.append((path, split, root))
        }
        let tab = try authority.dispatch(method: "bot.files.open_tab", params: [
            "client_request_id": "open-tab",
            "bot_id": botID,
            "handle": handle,
        ])
        XCTAssertEqual((tab["readback"] as? [String: Any])?["mounted"] as? Bool, true)
        XCTAssertEqual((tab["readback"] as? [String: Any])?["split"] as? Bool, false)
        let split = try authority.dispatch(method: "bot.files.split", params: [
            "client_request_id": "open-split",
            "bot_id": botID,
            "handle": handle,
        ])
        XCTAssertEqual((split["readback"] as? [String: Any])?["split"] as? Bool, true)
        XCTAssertEqual(opened.map(\.0), ["notes.txt", "notes.txt"])
        XCTAssertEqual(opened.map(\.1), [false, true])
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.files.open_tab", params: [
                "client_request_id": "open-missing",
                "bot_id": botID,
                "handle": "\(botID):bot_home:1:missing.txt",
            ])
        )
    }

    func test_dockerClear_isPartialWhenRuntimeTeardownFails() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "dock-p",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        authority.onDockerClear = { _ in
            throw BotRemoteControlAuthority.Error(code: -32088, message: "Docker home clear failed.")
        }
        let cleared = try authority.dispatch(method: "bot.docker.clear", params: [
            "client_request_id": "dock-p-c",
            "bot_id": botID,
            "confirm": "clear",
        ])
        XCTAssertEqual(cleared["status"] as? String, "partial")
        XCTAssertEqual((cleared["readback"] as? [String: Any])?["partial"] as? Bool, true)
        XCTAssertEqual((cleared["readback"] as? [String: Any])?["cleared"] as? Bool, true)
    }

    func test_forceStop_keepsQueueWhenLiveStopHookOwnsDrain() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "live-stop",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "live-stop-1",
            "bot_id": botID,
            "text": "go",
        ])
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "live-stop-2",
            "bot_id": botID,
            "text": "queued",
        ])
        var stopped = false
        authority.onStopRun = { _, force in
            stopped = force
        }
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        let result = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "live-stop-go",
            "bot_id": botID,
        ])
        XCTAssertTrue(stopped)
        XCTAssertEqual(result["status"] as? String, "accepted")
        XCTAssertNil((result["readback"] as? [String: Any])?["drained"] as? [String: Any])
        XCTAssertEqual(try store.listQueuedFollowUps(botID: BotID(uuid)).map(\.text), ["queued"])
    }

    func test_forceStop_drainsStoreQueue() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "drain",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "drain-1",
            "bot_id": botID,
            "text": "go",
        ])
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "drain-2",
            "bot_id": botID,
            "text": "queued",
        ])
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        XCTAssertEqual(try store.listQueuedFollowUps(botID: BotID(uuid)).count, 1)
        let stopped = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "drain-stop",
            "bot_id": botID,
        ])
        let readback = stopped["readback"] as? [String: Any]
        XCTAssertEqual(readback?["terminal"] as? Bool, true)
        XCTAssertEqual((readback?["drained"] as? [String: Any])?["text"] as? String, "queued")
        XCTAssertEqual(try store.listQueuedFollowUps(botID: BotID(uuid)).count, 0)
    }
}
