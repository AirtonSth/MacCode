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

    /// WHY: a routing choice is an admitted host capability, not an iOS hint.
    /// The exact outer receipt and run-as tuple must bind one conversation/run
    /// and must not be reusable after response loss or relaunch.
    func test_routingReceiptBindsExactSendTupleAndIsOneShotAcrossRelaunch() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "route-create",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "route-conversation",
            "bot_id": botID,
            "title": "Exact route",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let runAs: [String: Any] = [
            "generatedUID": "generated-user",
            "shortName": "runner",
            "uid": 501,
            "gid": 20,
            "homePath": "/Users/runner",
            "fullName": "Runner User",
        ]
        let admitted = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "route-admit",
            "bot_id": botID,
            "host_id": "host-exact",
            "provider": "grok",
            "provider_instance_id": "grok-work",
            "model": "grok-4",
            "routing_mode": "explicit",
            "permission_mode": "fullAccess",
            "reasoning_effort": "high",
            "service_tier": "priority",
            "run_as_user": runAs,
        ])
        let routingReceiptID = try XCTUnwrap(admitted["receipt_id"] as? String)
        let admittedReadback = try XCTUnwrap(admitted["readback"] as? [String: Any])
        XCTAssertEqual(admittedReadback["routing_receipt_id"] as? String, routingReceiptID,
                       "the outer durable receipt is the routing authority")
        XCTAssertEqual(admittedReadback["provider_instance_id"] as? String, "grok-work")
        XCTAssertEqual(admittedReadback["run_as_user"] as? NSDictionary, runAs as NSDictionary)

        let expectedRunID = UUID().uuidString.lowercased()
        authority.onHasLiveRun = { _ in true }
        authority.onSend = { callbackBotID, callbackText, callbackConversationID, callbackRouting in
            XCTAssertEqual(callbackBotID.value.uuidString.lowercased(), botID)
            XCTAssertEqual(callbackText, "Use this exact route")
            XCTAssertEqual(callbackConversationID?.value.uuidString.lowercased(), conversationID)
            XCTAssertEqual(callbackRouting["routing_receipt_id"] as? String, routingReceiptID)
            XCTAssertEqual(callbackRouting["run_as_user"] as? NSDictionary, runAs as NSDictionary)
            return [
                "bot_id": botID,
                "conversation_id": conversationID,
                "run_id": expectedRunID,
                "enqueued": true,
            ]
        }
        let sendParams: [String: Any] = [
            "client_request_id": "route-send",
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "Use this exact route",
            "host_id": "host-exact",
            "routing_receipt_id": routingReceiptID,
            "provider": "grok",
            "provider_instance_id": "grok-work",
            "model": "grok-4",
            "routing_mode": "explicit",
            "permission_mode": "fullAccess",
            "reasoning_effort": "high",
            "service_tier": "priority",
            "run_as_user": runAs,
        ]
        let sent = try authority.dispatch(method: "bot.send", params: sendParams)
        let sendReadback = try XCTUnwrap(sent["readback"] as? [String: Any])
        let run = try XCTUnwrap(sendReadback["run"] as? [String: Any])
        let runRouting = try XCTUnwrap(run["routing"] as? [String: Any])
        XCTAssertEqual(sendReadback["conversation_id"] as? String, conversationID)
        XCTAssertEqual(sendReadback["run_id"] as? String, expectedRunID)
        XCTAssertEqual(sendReadback["routing_receipt_id"] as? String, routingReceiptID)
        XCTAssertEqual(runRouting["routing_receipt_id"] as? String, routingReceiptID)
        XCTAssertEqual(runRouting["provider_instance_id"] as? String, "grok-work")
        XCTAssertEqual(runRouting["run_as_user"] as? NSDictionary, runAs as NSDictionary)

        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        var stale = sendParams
        stale["client_request_id"] = "route-stale"
        XCTAssertThrowsError(try relaunched.dispatch(method: "bot.send", params: stale)) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget,
                           "routing receipts are one-shot across host relaunch")
        }
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
        let sourceRouting = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "dup-route",
            "bot_id": botID,
            "host_id": "host-duplicate",
            "provider": "grok",
            "provider_instance_id": "grok-team",
            "model": "grok-4",
            "routing_mode": "explicit",
            "permission_mode": "fullAccess",
            "reasoning_effort": "high",
            "service_tier": "priority",
            "run_as_user": ["generatedUID": "duplicate-user", "shortName": "runner", "uid": 501, "gid": 20, "homePath": "/Users/runner"],
        ])
        let copy = try authority.dispatch(method: "bot.duplicate", params: [
            "client_request_id": "dup",
            "bot_id": botID,
        ])
        let specs = (copy["readback"] as? [String: Any])?["schedule_spec_jsons"] as? [String]
        XCTAssertEqual(specs, [spec])
        let copyID = try XCTUnwrap(copy["bot_id"] as? String)
        let copyRouting = try XCTUnwrap(
            ((copy["readback"] as? [String: Any])?["routing"] as? [String: Any])
        )
        XCTAssertEqual(copyRouting["bot_id"] as? String, copyID)
        XCTAssertEqual(copyRouting["provider_instance_id"] as? String, "grok-team")
        XCTAssertNotEqual(copyRouting["routing_receipt_id"] as? String,
                          sourceRouting["receipt_id"] as? String,
                          "the duplicate gets independent routing authority")

        _ = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "dup-source-change",
            "bot_id": botID,
            "provider_instance_id": "grok-source-changed",
        ])
        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        let readCopy = try relaunched.dispatch(method: "bot.get", params: ["bot_id": copyID])
        let persistedRouting = try XCTUnwrap(
            (readCopy["routing"] as? [String: Any])
        )
        XCTAssertEqual(persistedRouting["provider_instance_id"] as? String, "grok-team",
                       "source changes must not drift the duplicate")
    }

    /// WHY: duplicate admission must be atomic at the account cap. A rejected
    /// copy may not mint hidden routing state or alter the source.
    func test_duplicateAtCapLeavesSourceRoutingAndBotCountUnchanged() throws {
        let source = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "dup-cap-source", "name": "Source",
        ])
        let sourceID = try XCTUnwrap(source["bot_id"] as? String)
        let route = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "dup-cap-route",
            "bot_id": sourceID,
            "provider_instance_id": "grok-cap",
        ])
        for index in 1..<BotRemoteControlAuthority.liveAccountCap {
            _ = try authority.dispatch(method: "bot.create", params: [
                "client_request_id": "dup-cap-\(index)", "name": "Bot \(index)",
            ])
        }

        XCTAssertThrowsError(try authority.dispatch(method: "bot.duplicate", params: [
            "client_request_id": "dup-cap-reject", "bot_id": sourceID,
        ])) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .cap)
        }
        let listed = try authority.dispatch(method: "bot.list", params: [:])
        XCTAssertEqual((listed["bots"] as? [[String: Any]])?.count,
                       BotRemoteControlAuthority.liveAccountCap)
        let sourceRead = try authority.dispatch(method: "bot.get", params: ["bot_id": sourceID])
        XCTAssertEqual(((sourceRead["routing"] as? [String: Any])?["routing_receipt_id"] as? String),
                       route["receipt_id"] as? String)
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

    /// WHY: iOS active/finished routing and schedule screens must be projections
    /// of durable host truth. A due routine must fire once, then retain its exact
    /// execution/result and attention identity after the Mac authority relaunches.
    func test_dueRoutinePersistsExecutionResultNextRunAndAttentionIdentity() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "schedule-bot", "name": "Scheduler",
        ], now: base)
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "schedule-conversation",
            "bot_id": botID,
            "title": "Scheduled work",
        ], now: base)
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        var spec = BotScheduleSpec(
            frequency: .once,
            scheduledDate: base.addingTimeInterval(60),
            timeZoneIdentifier: "UTC"
        )
        spec.model = "grok-scheduled"
        let routine = try authority.dispatch(method: "bot.routine.create", params: [
            "client_request_id": "schedule-create",
            "bot_id": botID,
            "name": "Once",
            "prompt": "Run exactly once",
            "schedule_note": spec.displayNote(),
            "schedule_spec_json": spec.encodedJSON(),
        ], now: base)
        let routineID = try XCTUnwrap(
            (routine["readback"] as? [String: Any])?["routine_id"] as? String
        )
        let enabled = try authority.dispatch(method: "bot.routine.enable", params: [
            "client_request_id": "schedule-enable",
            "bot_id": botID,
            "routine_id": routineID,
            "enabled": true,
        ], now: base)
        let due = try XCTUnwrap(
            (enabled["readback"] as? [String: Any])?["next_run_at"] as? Double
        )
        XCTAssertEqual(due, base.addingTimeInterval(60).timeIntervalSince1970, accuracy: 1)

        let early = try authority.dispatch(method: "bot.scheduler.tick", params: [
            "client_request_id": "schedule-early",
        ], now: base.addingTimeInterval(30))
        XCTAssertTrue((((early["readback"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []).isEmpty,
                      "scheduler must not fabricate an early execution")
        let fired = try authority.dispatch(method: "bot.scheduler.tick", params: [
            "client_request_id": "schedule-due",
        ], now: Date(timeIntervalSince1970: due))
        let run = try XCTUnwrap(
            ((fired["readback"] as? [String: Any])?["runs"] as? [[String: Any]])?.first
        )
        let runID = try XCTUnwrap(run["run_id"] as? String)
        XCTAssertEqual(run["routine_id"] as? String, routineID)
        XCTAssertEqual(run["result"] as? String, "completed")
        XCTAssertEqual(run["schedule_spec_json"] as? String, spec.encodedJSON())

        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        let routines = try relaunched.dispatch(method: "bot.routine.list", params: ["bot_id": botID])
        let persisted = try XCTUnwrap((routines["routines"] as? [[String: Any]])?.first)
        XCTAssertEqual(persisted["last_run_id"] as? String, runID)
        XCTAssertEqual(persisted["last_result"] as? String, "completed")
        XCTAssertTrue(persisted["next_run_at"] is NSNull,
                      "one-shot schedules must persist that no next run exists")
        let attention = try relaunched.dispatch(method: "bot.attention.list", params: [:])
        let item = try XCTUnwrap((attention["items"] as? [[String: Any]])?.first)
        XCTAssertNotNil(item["id"] as? String)
        XCTAssertEqual(item["bot_id"] as? String, botID)
        XCTAssertEqual(item["conversation_id"] as? String, conversationID)
        XCTAssertEqual(item["run_id"] as? String, runID)
        XCTAssertEqual(item["state"] as? String, "finished")
        XCTAssertNotNil(item["finished_at"] as? Double)
        XCTAssertEqual(item["ownership"] as? String, "primary")
        XCTAssertEqual(item["primary"] as? Bool, true)
        XCTAssertEqual(item["delegated"] as? Bool, false)
        XCTAssertNotNil(item["title"] as? String)
        XCTAssertNotNil(item["detail"] as? String)
        XCTAssertEqual(item["source"] as? String, "routine")
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
        authority.onStopRun = { _, force, _ in
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

    func test_guestInput_requiresLiveHookAndCompletesWhenHookReturns() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "gin",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.guest.input", params: [
                "client_request_id": "gin-miss",
                "bot_id": botID,
                "text": "hello",
            ])
        )
        var received = ""
        var hookedRequest = ""
        authority.onGuestInput = { _, params, requestID in
            received = params["text"] as? String ?? ""
            hookedRequest = requestID
        }
        let sent = try authority.dispatch(method: "bot.guest.input", params: [
            "client_request_id": "gin-ok",
            "bot_id": botID,
            "text": "hello",
        ])
        XCTAssertEqual(received, "hello")
        XCTAssertEqual(hookedRequest, "gin-ok")
        XCTAssertEqual(sent["status"] as? String, "accepted")
        XCTAssertEqual((sent["readback"] as? [String: Any])?["status"] as? String, "running")
        authority.settle(
            requestID: "gin-ok",
            status: .completed,
            readback: [
                "bot_id": botID,
                "status": "running",
                "viewer": "/vnc.html",
                "embed_html_is_not_runtime": true,
            ]
        )
        let status = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": "gin-ok",
        ])
        XCTAssertEqual(status["status"] as? String, "completed")
    }

    func test_guestStart_acceptedThenSettleBecomesCompleted() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "g-set",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        var requestID = ""
        authority.onStartGuest = { _, _, id in requestID = id }
        let started = try authority.dispatch(method: "bot.guest.start", params: [
            "client_request_id": "g-set-1",
            "bot_id": botID,
            "recipe": "pointer",
        ])
        XCTAssertEqual(started["status"] as? String, "accepted")
        XCTAssertEqual(requestID, "g-set-1")
        authority.settle(
            requestID: requestID,
            status: .completed,
            readback: [
                "bot_id": botID,
                "status": "running",
                "viewer": "/vnc.html",
                "embed_html_is_not_runtime": true,
            ]
        )
        let status = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": "g-set-1",
        ])
        XCTAssertEqual(status["status"] as? String, "completed")
        let guest = try authority.dispatch(method: "bot.guest.state", params: ["bot_id": botID])
        XCTAssertEqual(guest["status"] as? String, "running")
    }

    func test_browserOpen_keepsPendingWhenNotifyFails() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "br-fail",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        authority.notifyBrowserPendingOpen = { _ in
            throw BotRemoteControlAuthority.Error(code: -32087, message: "Bot browser persist failed.")
        }
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.link.open", params: [
                "client_request_id": "br-fail-1",
                "bot_id": botID,
                "url": "http://127.0.0.1:5000",
            ])
        )
        XCTAssertEqual(
            try BotBrowserStore(appSupportDirectory: supportDir).loadPendingOpens().map(\.url),
            ["http://127.0.0.1:5000"]
        )
        let failed = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": "br-fail-1",
        ])
        XCTAssertEqual(failed["status"] as? String, "failed")
    }

    func test_forceStop_acceptedSettlesToCompleted() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "stop-set",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "stop-set-run",
            "bot_id": botID,
            "text": "go",
        ])
        var requestID = ""
        authority.onStopRun = { _, _, id in requestID = id }
        let stopped = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "stop-set-1",
            "bot_id": botID,
        ])
        XCTAssertEqual(stopped["status"] as? String, "accepted")
        authority.settle(requestID: requestID, status: .completed, readback: [
            "accepted": true,
            "force": true,
            "terminal": true,
        ])
        let status = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": "stop-set-1",
        ])
        XCTAssertEqual(status["status"] as? String, "completed")
    }

    func test_conversationList_exposesLinkedAgentThreadID_soRemoteClientsCanReadTranscripts() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "conv-list-1",
            "name": "Piper",
        ])
        let botIDRaw = try XCTUnwrap(created["bot_id"] as? String)
        let botID = BotID(try XCTUnwrap(UUID(uuidString: botIDRaw)))
        let threadID = AgentThreadID()
        let linked = BotConversation(botID: botID, title: "Linked", linkedAgentThreadID: threadID)
        let unlinked = BotConversation(botID: botID, title: "Unlinked")
        try store.upsertConversation(linked)
        try store.upsertConversation(unlinked)

        let result = try authority.dispatch(method: "bot.conversation.list", params: ["bot_id": botIDRaw])
        let rows = try XCTUnwrap(result["conversations"] as? [[String: Any]])
        let linkedRow = try XCTUnwrap(rows.first { $0["id"] as? String == linked.id.value.uuidString.lowercased() })
        let unlinkedRow = try XCTUnwrap(rows.first { $0["id"] as? String == unlinked.id.value.uuidString.lowercased() })

        XCTAssertEqual(
            linkedRow["linked_agent_thread_id"] as? String,
            threadID.value.uuidString.lowercased(),
            "Remote clients need the linked agent thread id to read the transcript via agent.message.list"
        )
        XCTAssertNil(
            unlinkedRow["linked_agent_thread_id"],
            "Conversations without a first run have no thread yet; the key must be absent, not fabricated"
        )
        XCTAssertNotNil(linkedRow["updated_at"] as? Double)
    }
}
