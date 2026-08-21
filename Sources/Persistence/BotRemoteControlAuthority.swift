import Foundation
import CoreModel

/// Host-authoritative paired Bot remote-control engine.
///
/// Mutations succeed only with a logical request id plus receipt/status/readback.
/// Silent local-only success is a contract failure. Effects/Channels stay
/// unavailable even when raw persisted true. Reserved IDs never get positive
/// product surfaces.
public final class BotRemoteControlAuthority: @unchecked Sendable {
    public static let liveAccountCap = BotDefinition.liveAccountCap
    public static let reservedCapabilityIDs: Set<String> = ["U034", "U038", "U039", "U045"]
    public static let blobatarShapes = BotBlobatarShape.allCases.map(\.rawValue)
    public static let blobatarHues = ["auto"] + BotBlobatar.studioHues.map(\.id)
    public static let sendKeys = ["button", "return", "keypad_enter", "command_return"]
    public static let newlineKeys = ["shift_return", "option_return"]
    public static let destinations = ["desk", "studio", "active", "schedule"]

    public enum Status: String, Sendable {
        case accepted, completed, failed, unknown, partial
    }

    public struct Error: Swift.Error, Equatable, CustomStringConvertible {
        public let code: Int
        public let message: String
        public var description: String { message }
        public init(code: Int, message: String) {
            self.code = code
            self.message = message
        }
        public static let invalidParams = Error(code: -32602, message: "Invalid params")
        public static let controlPlaneOff = Error(code: -32081, message: "Bot control plane is off.")
        public static let notFound = Error(code: -32044, message: "RemoteCode Bot was not found.")
        public static let cap = Error(code: -32082, message: "Account limit of 50 live bots reached.")
        public static let reserved = Error(code: -32083, message: "Reserved capability has no positive Bot parity.")
        public static let missingRequest = Error(code: -32097, message: "Mutation requires a non-empty client_request_id.")
        public static let crossTarget = Error(code: -32084, message: "Attachment grant does not match this Bot or conversation.")
        public static let handleConflict = Error(code: -32085, message: "Bot handle is already used or retired.")
    }

    private let lock = NSLock()
    private let store: BotStore
    private let settings: SettingsStore
    private let db: SQLiteDB
    private let appSupport: URL
    private let browserStore: BotBrowserStore

    public var onHasLiveRun: ((BotID) -> Bool)?
    public var onStopRun: ((BotID, Bool) -> Void)?
    public var onStartGuest: ((BotID, String) -> Void)?
    public var onStopGuest: ((BotID) -> Void)?
    public var onRebuildGuest: ((BotID) -> Void)?
    public var onDockerClear: ((BotID) throws -> Void)?
    public var onSend: ((BotID, String) throws -> Void)?
    public var onOpenFile: ((BotID, String, Bool, String) throws -> Void)?
    public var notifyBrowserPendingOpen: ((Notification.Name) -> Void)?

    private var receipts: [String: [String: Any]] = [:]
    private var unpublished: Set<String> = []
    private var attachments: [String: [String: Any]] = [:]
    private var files: [String: [String: Any]] = [:]
    private var browser: [String: [String: Any]] = [:]
    private var guest: [String: [String: Any]] = [:]
    private var liveRuns: [String: [String: Any]] = [:]
    private var attention: [String: [String: Any]] = [:]
    private var peerReceipts: [String: [String: Any]] = [:]
    private var schedulerRuns: [[String: Any]] = []
    private var filesLocation: [String: String] = [:]
    private var routingPref: [String: [String: Any]] = [:]
    private var selectedConversation: [String: String] = [:]
    private var generation: Int = 1

    public init(db: SQLiteDB, store: BotStore, settings: SettingsStore, appSupportDirectory: URL) {
        self.db = db
        self.store = store
        self.settings = settings
        self.appSupport = appSupportDirectory
        self.browserStore = BotBrowserStore(appSupportDirectory: appSupportDirectory)
        loadSidecar()
        migrateSidecarQueueIfNeeded()
    }

    public func dispatch(method: String, params: [String: Any], now: Date = Date()) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if method.hasPrefix("bot.") == false {
            throw Error.invalidParams
        }
        let name = String(method.dropFirst(4))
        if Self.reservedCapabilityIDs.contains(params["capability_id"] as? String ?? "") {
            throw Error.reserved
        }
        switch name {
        case "list":
            return try list(params: params)
        case "get":
            return try get(params: params)
        case "settings.get":
            return settingsReadback()
        case "queue.list":
            return try queueList(params: params)
        case "conversation.list":
            return try conversationList(params: params)
        case "routine.list":
            return try routineList(params: params)
        case "files.list":
            return try filesList(params: params)
        case "browser.state":
            return try browserState(params: params)
        case "guest.state":
            return guestState(params: params)
        case "receipt.status":
            return receiptStatus(params: params)
        case "peer.receipt.status":
            return peerReceiptStatus(params: params)
        case "attention.list":
            return ["items": Array(attention.values)]
        case "reserved.probe":
            throw Error.reserved
        case "scheduler.tick":
            return try schedulerTick(now: now, params: params)
        default:
            return try mutate(name: name, params: params, now: now)
        }
    }

    public func effectiveSettings() -> (raw: [String: Bool], effective: [String: Bool]) {
        let flags = settings.load().botControlPlaneFlags
        let raw: [String: Bool] = [
            "control_plane": flags.botsControlPlaneEnabled,
            "memory": flags.botsMemoryEnabled,
            "effects": flags.botsEffectsEnabled,
            "channels": flags.botsChannelsEnabled,
            "autonomy": flags.botsAutonomyEnabled,
        ]
        let effective: [String: Bool] = [
            "control_plane": flags.isBotControlPlaneActive,
            "memory": flags.isBotMemoryActive,
            "effects": false,
            "channels": false,
            "autonomy": flags.isBotAutonomyActive,
        ]
        return (raw, effective)
    }

    // MARK: - Reads

    private func list(params: [String: Any]) throws -> [String: Any] {
        let includeHidden = (params["include_hidden"] as? Bool) ?? false
        let bots = try store.list(includeHidden: includeHidden).map { encodeBot($0) }
        return ["bots": bots, "unpublished_ids": Array(unpublished).sorted()]
    }

    private func get(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        var encoded = encodeBot(bot)
        encoded["unpublished"] = unpublished.contains(bot.id.value.uuidString.lowercased())
        return encoded
    }

    private func settingsReadback() -> [String: Any] {
        let pair = effectiveSettings()
        return [
            "raw": pair.raw,
            "effective": pair.effective,
            "effects_available": false,
            "channels_available": false,
        ]
    }

    private func queueList(params: [String: Any]) throws -> [String: Any] {
        guard let raw = string(params, "bot_id"), let uuid = UUID(uuidString: raw) else {
            return ["items": []]
        }
        let items = try store.listQueuedFollowUps(botID: BotID(uuid))
        return ["items": encodeQueue(items)]
    }

    private func conversationList(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        let rows = try store.listConversations(botID: bot.id).map { conversation in
            [
                "id": conversation.id.value.uuidString.lowercased(),
                "title": conversation.title,
                "bot_id": bot.id.value.uuidString.lowercased(),
            ] as [String: Any]
        }
        return [
            "conversations": rows,
            "selected_id": selectedConversation[id(bot)] as Any,
        ]
    }

    private func routineList(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        let rows = try store.listRoutines(botID: bot.id).map { encodeRoutine($0) }
        return ["routines": rows]
    }

    private func filesList(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let root = filesLocation[botID] ?? "bot_home"
        let paths = try listDiskPaths(bot: bot, root: root)
        var entries: [[String: Any]] = []
        for path in paths {
            let handle = handleFor(botID: botID, root: root, path: path)
            let entry: [String: Any] = [
                "handle": handle,
                "bot_id": botID,
                "root": root,
                "path": path,
                "generation": generation,
            ]
            files[handle] = entry
            entries.append(entry)
        }
        return [
            "root": root,
            "generation": generation,
            "entries": entries,
        ]
    }

    private func browserState(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        if let target = try browserStore.loadTarget(botID: bot.id) {
            return [
                "bot_id": botID,
                "url": target.url,
                "title": target.title,
                "loading": false,
                "generation": (browser[botID]?["generation"] as? Int) ?? generation,
                "host_first": true,
            ]
        }
        return browser[botID] ?? [
            "bot_id": botID,
            "url": "",
            "title": "",
            "loading": false,
            "generation": 0,
        ]
    }

    private func guestState(params: [String: Any]) -> [String: Any] {
        let botID = string(params, "bot_id") ?? ""
        return guest[botID] ?? [
            "bot_id": botID,
            "status": "stopped",
            "viewer": "/vnc.html",
        ]
    }

    private func receiptStatus(params: [String: Any]) -> [String: Any] {
        let requestID = string(params, "client_request_id") ?? ""
        return receipts[requestID] ?? ["status": Status.unknown.rawValue, "request_id": requestID]
    }

    private func peerReceiptStatus(params: [String: Any]) -> [String: Any] {
        let requestID = string(params, "client_request_id") ?? ""
        return peerReceipts[requestID] ?? ["status": Status.unknown.rawValue, "request_id": requestID]
    }

    // MARK: - Mutations

    private func mutate(name: String, params: [String: Any], now: Date) throws -> [String: Any] {
        let requestID = string(params, "client_request_id")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requestID.isEmpty else { throw Error.missingRequest }
        if let existing = receipts[requestID] {
            return existing
        }
        let result: [String: Any]
        do {
            result = try perform(name: name, params: params, requestID: requestID, now: now)
        } catch let error as Error {
            let failed = receipt(
                requestID: requestID,
                status: .failed,
                botID: string(params, "bot_id"),
                readback: ["error": error.message]
            )
            receipts[requestID] = failed
            persistSidecar()
            throw error
        }
        receipts[requestID] = result
        persistSidecar()
        return result
    }

    private func perform(name: String, params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        switch name {
        case "create":
            return try create(params: params, requestID: requestID, now: now)
        case "discard_new":
            return try discardNew(params: params, requestID: requestID)
        case "save":
            return try save(params: params, requestID: requestID, now: now)
        case "delete":
            return try deleteBot(params: params, requestID: requestID, now: now)
        case "set_pinned":
            return try setPinned(params: params, requestID: requestID, now: now)
        case "set_hidden":
            return try setHidden(params: params, requestID: requestID, now: now)
        case "duplicate":
            return try duplicate(params: params, requestID: requestID, now: now)
        case "settings.set":
            return try settingsSet(params: params, requestID: requestID)
        case "send":
            return try send(params: params, requestID: requestID, now: now)
        case "queue.remove":
            return try queueRemove(params: params, requestID: requestID)
        case "stop", "force_stop":
            return try stop(params: params, requestID: requestID, force: name == "force_stop")
        case "conversation.create":
            return try conversationCreate(params: params, requestID: requestID)
        case "conversation.select":
            return try conversationSelect(params: params, requestID: requestID)
        case "conversation.clear_all":
            return try conversationClearAll(params: params, requestID: requestID)
        case "routine.create", "routine.update":
            return try routineUpsert(params: params, requestID: requestID, now: now)
        case "routine.enable":
            return try routineEnable(params: params, requestID: requestID, now: now)
        case "routine.run":
            return try routineRun(params: params, requestID: requestID, now: now)
        case "routine.delete":
            return try routineDelete(params: params, requestID: requestID)
        case "attachment.stage":
            return try attachmentStage(params: params, requestID: requestID)
        case "attachment.remove":
            return try attachmentRemove(params: params, requestID: requestID)
        case "files.mutate":
            return try filesMutate(params: params, requestID: requestID)
        case "files.open_tab", "files.split":
            return try filesOpen(params: params, requestID: requestID, split: name == "files.split")
        case "files.location.set":
            return try filesLocationSet(params: params, requestID: requestID)
        case "browser.action":
            return try browserAction(params: params, requestID: requestID)
        case "link.open":
            return try linkOpen(params: params, requestID: requestID)
        case "guest.input", "guest.start", "guest.stop", "guest.rebuild":
            return try guestCommand(name: name, params: params, requestID: requestID)
        case "docker.clear":
            return try dockerClear(params: params, requestID: requestID)
        case "notify.set":
            return try notifySet(params: params, requestID: requestID, now: now)
        case "desktop.set":
            return try desktopSet(params: params, requestID: requestID)
        case "avatar.set":
            return try avatarSet(params: params, requestID: requestID, now: now)
        case "handle.set":
            return try handleSet(params: params, requestID: requestID)
        case "soul.set":
            return try soulSet(params: params, requestID: requestID)
        case "routing.set":
            return try routingSet(params: params, requestID: requestID)
        case "attention.ack":
            return try attentionAck(params: params, requestID: requestID)
        case "peer.ask":
            return try peerAsk(params: params, requestID: requestID)
        case "self_config":
            return try selfConfig(params: params, requestID: requestID)
        default:
            throw Error.invalidParams
        }
    }

    private func create(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        try requireControlPlane()
        let live = try store.list()
        if live.count >= Self.liveAccountCap { throw Error.cap }
        let name = string(params, "name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "New Agent"
        let bot = try store.create(
            name: name.isEmpty ? "New Agent" : name,
            title: string(params, "title") ?? "",
            description: string(params, "description") ?? "",
            handle: string(params, "handle"),
            soul: string(params, "soul") ?? "",
            now: now
        )
        unpublished.insert(id(bot))
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: encodeBot(bot, extra: ["unpublished": true, "pre": "UNPUBLISHED_NEW"]))
    }

    private func discardNew(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        guard unpublished.contains(botID) else { throw Error.invalidParams }
        try store.delete(id: bot.id)
        unpublished.remove(botID)
        try? store.deleteQueuedFollowUps(botID: bot.id)
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: ["deleted": true, "unpublished": false])
    }

    private func save(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        try requireControlPlane()
        let bot = try requireBot(params)
        let botID = id(bot)
        let pre = unpublished.contains(botID) ? "UNPUBLISHED_NEW" : "EXISTING"
        if let name = string(params, "name") {
            _ = try store.updateProfile(
                id: bot.id,
                name: name,
                title: string(params, "title") ?? bot.title,
                description: string(params, "description") ?? bot.description,
                now: now
            )
        }
        unpublished.remove(botID)
        let fresh = try store.get(id: bot.id) ?? bot
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: encodeBot(fresh, extra: ["unpublished": false, "pre": pre]))
    }

    private func deleteBot(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        if string(params, "confirm") != "delete" {
            return receipt(requestID: requestID, status: .accepted, botID: string(params, "bot_id"), readback: ["confirm_required": true])
        }
        let bot = try requireBot(params)
        try store.delete(id: bot.id, now: now)
        unpublished.remove(id(bot))
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["deleted": true])
    }

    private func setPinned(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let pinned = bool(params, "pinned") ?? false
        try store.setPinned(id: bot.id, pinned: pinned, now: now)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["pinned": pinned])
    }

    private func setHidden(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let hidden = bool(params, "hidden") ?? false
        try store.setHidden(id: bot.id, hidden: hidden, now: now)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["hidden": hidden])
    }

    private func duplicate(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        try requireControlPlane()
        if try store.list().count >= Self.liveAccountCap { throw Error.cap }
        let bot = try requireBot(params)
        let copy = try store.duplicate(id: bot.id, now: now)
        let routines = try store.listRoutines(botID: copy.id)
        let specs = routines.map { $0.definition.scheduleSpecJSON }
        return receipt(
            requestID: requestID,
            status: .completed,
            botID: id(copy),
            readback: encodeBot(copy, extra: [
                "source_bot_id": id(bot),
                "schedule_spec_jsons": specs,
            ])
        )
    }

    private func settingsSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let key = string(params, "key") ?? ""
        let value = bool(params, "value")
        guard let value else { throw Error.invalidParams }
        var current = settings.load()
        switch key {
        case "control_plane": current.botsControlPlaneEnabled = value
        case "memory": current.botsMemoryEnabled = value
        case "effects": current.botsEffectsEnabled = value
        case "channels": current.botsChannelsEnabled = value
        case "autonomy": current.botsAutonomyEnabled = value
        default: throw Error.invalidParams
        }
        settings.save(current)
        let pair = effectiveSettings()
        return receipt(
            requestID: requestID,
            status: .completed,
            botID: nil,
            readback: [
                "raw": pair.raw,
                "effective": pair.effective,
                "key": key,
            ]
        )
    }

    private func send(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        try requireControlPlane()
        let bot = try requireBot(params)
        let text = string(params, "text")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw Error.invalidParams }
        let botID = id(bot)
        let attachmentIDs = stringArray(params, "attachment_ids")
        var bound: [[String: Any]] = []
        for attachmentID in attachmentIDs {
            guard let grant = attachments[attachmentID],
                  grant["bot_id"] as? String == botID,
                  (grant["consumed"] as? Bool) != true else {
                throw Error.crossTarget
            }
            var next = grant
            next["consumed"] = true
            attachments[attachmentID] = next
            bound.append(next)
        }
        let live = onHasLiveRun?(bot.id) ?? (liveRuns[botID] != nil)
        if live {
            var payload: [String: Any] = ["attachments": bound]
            if let conversationID = selectedConversation[botID] {
                payload["conversation_id"] = conversationID
            }
            let payloadJSON = jsonString(payload) ?? "{}"
            let stored = try store.enqueueQueuedFollowUp(
                BotQueuedFollowUpRecord(
                    botID: bot.id,
                    conversationID: selectedConversation[botID],
                    text: text,
                    payloadJSON: payloadJSON,
                    createdAt: now
                )
            )
            return receipt(requestID: requestID, status: .completed, botID: botID, readback: [
                "enqueued": true,
                "queue": encodeQueue(try store.listQueuedFollowUps(botID: bot.id)),
                "id": stored.id,
            ])
        }
        if let onSend {
            try onSend(bot.id, text)
        }
        liveRuns[botID] = [
            "bot_id": botID,
            "status": "working",
            "text": text,
            "started_at": now.timeIntervalSince1970,
        ]
        attention[botID] = [
            "bot_id": botID,
            "state": "working",
            "source": "bot",
        ]
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: [
            "enqueued": false,
            "run": liveRuns[botID] as Any,
            "workspace": NSNull(),
        ])
    }

    private func queueRemove(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let itemID = string(params, "id") ?? ""
        try store.removeQueuedFollowUp(botID: bot.id, id: itemID)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "queue": encodeQueue(try store.listQueuedFollowUps(botID: bot.id)),
        ])
    }

    private func stop(params: [String: Any], requestID: String, force: Bool) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let hadLive = onHasLiveRun?(bot.id) ?? (liveRuns[botID] != nil)
        let run = liveRuns[botID]
        let liveStop = onStopRun != nil
        onStopRun?(bot.id, force)
        liveRuns[botID] = nil
        var drained: [String: Any]?
        if !liveStop, let next = try store.dequeueQueuedFollowUp(botID: bot.id) {
            liveRuns[botID] = [
                "bot_id": botID,
                "status": "working",
                "text": next.text,
                "from_queue_id": next.id,
            ]
            drained = encodeQueue([next]).first
        }
        attention[botID] = [
            "bot_id": botID,
            "state": drained == nil ? "none" : "working",
            "source": "bot",
        ]
        return receipt(
            requestID: requestID,
            status: liveStop ? .accepted : .completed,
            botID: botID,
            readback: [
                "accepted": true,
                "force": force,
                "terminal": hadLive || run != nil,
                "run": run as Any,
                "drained": drained as Any,
                "queue": encodeQueue(try store.listQueuedFollowUps(botID: bot.id)),
            ]
        )
    }

    private func conversationCreate(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let title = string(params, "title") ?? "New thread"
        let conversation = BotConversation(botID: bot.id, title: title)
        try store.upsertConversation(conversation)
        selectedConversation[id(bot)] = conversation.id.value.uuidString.lowercased()
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "conversation_id": conversation.id.value.uuidString.lowercased(),
            "title": conversation.title,
        ])
    }

    private func conversationSelect(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let conversationID = string(params, "conversation_id") ?? ""
        selectedConversation[id(bot)] = conversationID
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "selected_id": conversationID,
        ])
    }

    private func conversationClearAll(params: [String: Any], requestID: String) throws -> [String: Any] {
        if string(params, "confirm") != "clear" {
            return receipt(requestID: requestID, status: .accepted, botID: string(params, "bot_id"), readback: ["confirm_required": true])
        }
        let bot = try requireBot(params)
        try store.deleteConversations(botID: bot.id)
        selectedConversation[id(bot)] = nil
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["cleared": true])
    }

    private func routineUpsert(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let specJSON = string(params, "schedule_spec_json") ?? ""
        let existingID = string(params, "routine_id").flatMap(UUID.init).map(BotRoutineID.init)
        let definition = BotRoutineDefinition(
            id: existingID ?? BotRoutineID(),
            botID: bot.id,
            name: string(params, "name") ?? "Routine",
            prompt: string(params, "prompt") ?? "",
            scheduleNote: string(params, "schedule_note") ?? "",
            scheduleSpecJSON: specJSON,
            createdAt: now,
            updatedAt: now
        )
        try store.saveRoutine(definition)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "routine_id": definition.id.value.uuidString.lowercased(),
            "schedule_spec_json": specJSON,
        ])
    }

    private func routineEnable(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let raw = string(params, "routine_id"), let uuid = UUID(uuidString: raw) else { throw Error.invalidParams }
        let enabled = bool(params, "enabled") ?? false
        try store.setRoutineEnabled(id: BotRoutineID(uuid), enabled: enabled)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "routine_id": raw.lowercased(),
            "enabled": enabled,
            "next_run_at": enabled ? now.addingTimeInterval(60).timeIntervalSince1970 : NSNull(),
        ])
    }

    private func routineRun(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let routineID = string(params, "routine_id") ?? UUID().uuidString
        let run: [String: Any] = [
            "run_id": UUID().uuidString.lowercased(),
            "routine_id": routineID,
            "bot_id": id(bot),
            "executed_at": now.timeIntervalSince1970,
            "result": "accepted",
        ]
        schedulerRuns.append(run)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: run)
    }

    private func routineDelete(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let raw = string(params, "routine_id"), let uuid = UUID(uuidString: raw) else { throw Error.invalidParams }
        try store.deleteRoutine(id: BotRoutineID(uuid))
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["deleted": true])
    }

    private func schedulerTick(now: Date, params: [String: Any]) throws -> [String: Any] {
        let requestID = string(params, "client_request_id") ?? "scheduler-tick"
        var fired: [[String: Any]] = []
        for bot in try store.list() {
            for routine in try store.listRoutines(botID: bot.id) where routine.activation.isEnabled {
                let run: [String: Any] = [
                    "run_id": UUID().uuidString.lowercased(),
                    "routine_id": routine.definition.id.value.uuidString.lowercased(),
                    "bot_id": id(bot),
                    "executed_at": now.timeIntervalSince1970,
                    "automatic": true,
                    "schedule_spec_json": routine.definition.scheduleSpecJSON,
                ]
                schedulerRuns.append(run)
                fired.append(run)
            }
        }
        return receipt(requestID: requestID, status: .completed, botID: nil, readback: ["runs": fired])
    }

    private func attachmentStage(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let digest = string(params, "digest") ?? UUID().uuidString
        let grantID = UUID().uuidString.lowercased()
        let grant: [String: Any] = [
            "id": grantID,
            "bot_id": id(bot),
            "conversation_id": string(params, "conversation_id") as Any,
            "digest": digest,
            "size": params["size"] as? Int ?? 0,
            "consumed": false,
        ]
        attachments[grantID] = grant
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: grant)
    }

    private func attachmentRemove(params: [String: Any], requestID: String) throws -> [String: Any] {
        let grantID = string(params, "id") ?? ""
        attachments[grantID] = nil
        return receipt(requestID: requestID, status: .completed, botID: string(params, "bot_id"), readback: ["removed": true])
    }

    private func filesMutate(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let root = filesLocation[botID] ?? "bot_home"
        let path = string(params, "path") ?? ""
        if path.contains("..") || path.hasPrefix("/") {
            throw Error(code: -32086, message: "Path escapes Bot home containment.")
        }
        let op = string(params, "op") ?? "write"
        let contents = string(params, "contents") ?? string(params, "body") ?? ""
        try applyDiskMutation(bot: bot, root: root, path: path, op: op, contents: contents)
        generation += 1
        let handle = "\(botID):\(root):\(generation):\(path)"
        let entry: [String: Any] = [
            "handle": handle,
            "bot_id": botID,
            "root": root,
            "path": path,
            "generation": generation,
            "op": op,
        ]
        files[handle] = entry
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: entry)
    }

    private func filesOpen(params: [String: Any], requestID: String, split: Bool) throws -> [String: Any] {
        let bot = try requireBot(params)
        let handle = string(params, "handle") ?? ""
        let entry = try resolveFileEntry(bot: bot, handle: handle)
        let root = (entry["root"] as? String) ?? (filesLocation[id(bot)] ?? "bot_home")
        let path = entry["path"] as? String ?? ""
        guard try diskFileExists(bot: bot, root: root, path: path) else {
            throw Error(code: -32090, message: "Bot file was not found.")
        }
        if let onOpenFile {
            try onOpenFile(bot.id, path, split, root)
        }
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "mounted": true,
            "split": split,
            "handle": handle,
            "path": path,
            "generation": entry["generation"] as Any,
        ])
    }

    private func filesLocationSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let root = string(params, "root") ?? "bot_home"
        guard root == "bot_home" || root == "docker_home" else { throw Error.invalidParams }
        filesLocation[id(bot)] = root
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["root": root])
    }

    private func browserAction(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        generation += 1
        let url = string(params, "url") ?? (browser[botID]?["url"] as? String) ?? ""
        let title = string(params, "title") ?? url
        do {
            _ = try BotBrowserHost.requestOpen(
                store: browserStore,
                botID: bot.id,
                url: url,
                title: title.isEmpty ? nil : title,
                notify: notifyBrowserPendingOpen ?? { name in
                    DistributedNotificationCenter.default().post(name: name, object: nil)
                }
            )
        } catch {
            throw Error(code: -32087, message: "Bot browser persist failed.")
        }
        let state: [String: Any] = [
            "bot_id": botID,
            "url": url,
            "title": title,
            "loading": false,
            "generation": generation,
            "action_id": requestID,
            "host_first": true,
        ]
        browser[botID] = state
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: state)
    }

    private func linkOpen(params: [String: Any], requestID: String) throws -> [String: Any] {
        let url = string(params, "url") ?? ""
        guard !url.isEmpty else { throw Error.invalidParams }
        return try browserAction(params: params.merging(["url": url]) { _, new in new }, requestID: requestID)
    }

    private func guestCommand(name: String, params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        _ = try BotGuestHome.ensure(appSupport: appSupport, botID: bot.id)
        let recipe = string(params, "recipe") ?? "pointer"
        let status: String
        let receiptStatus: Status
        switch name {
        case "guest.start":
            onStartGuest?(bot.id, recipe)
            status = "starting"
            receiptStatus = .accepted
        case "guest.rebuild":
            onRebuildGuest?(bot.id)
            status = "starting"
            receiptStatus = .accepted
        case "guest.stop":
            onStopGuest?(bot.id)
            status = "stopping"
            receiptStatus = .accepted
        default:
            status = "input"
            receiptStatus = .accepted
        }
        let state: [String: Any] = [
            "bot_id": botID,
            "status": status,
            "viewer": "/vnc.html",
            "grant_id": requestID,
            "recipe": recipe,
            "embed_html_is_not_runtime": true,
        ]
        guest[botID] = state
        return receipt(requestID: requestID, status: receiptStatus, botID: botID, readback: state)
    }

    private func dockerClear(params: [String: Any], requestID: String) throws -> [String: Any] {
        if string(params, "confirm") != "clear" {
            return receipt(requestID: requestID, status: .accepted, botID: string(params, "bot_id"), readback: ["confirm_required": true])
        }
        let bot = try requireBot(params)
        let botID = id(bot)
        let removedPaths: [String]
        do {
            removedPaths = (try? listDiskPaths(bot: bot, root: "docker_home")) ?? []
            try BotGuestHome.wipe(appSupport: appSupport, botID: bot.id)
        } catch {
            throw Error(code: -32088, message: "Docker home clear failed.")
        }
        var partial = false
        if let onDockerClear {
            do {
                try onDockerClear(bot.id)
            } catch {
                partial = true
            }
        }
        let removed = files.keys.filter { key in
            (files[key]?["bot_id"] as? String) == botID && (files[key]?["root"] as? String) == "docker_home"
        }
        for key in removed { files[key] = nil }
        guest[botID] = ["bot_id": botID, "status": "stopped", "viewer": "/vnc.html"]
        return receipt(
            requestID: requestID,
            status: partial ? .partial : .completed,
            botID: botID,
            readback: [
                "cleared": true,
                "removed_count": max(removed.count, removedPaths.count),
                "partial": partial,
            ]
        )
    }

    private func notifySet(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let enabled = bool(params, "enabled") ?? true
        _ = try store.updateProfile(id: bot.id, notificationsEnabled: enabled, now: now)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "notifications_enabled": enabled,
            "route": "bot",
        ])
    }

    private func desktopSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let kind = string(params, "kind") ?? BotDesktopKind.logicalExecutionSpace.rawValue
        guard BotDesktopKind.advertisedKinds.map(\.rawValue).contains(kind) else { throw Error.invalidParams }
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["kind": kind])
    }

    private func avatarSet(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let shape = string(params, "shape") ?? "auto"
        let hue = string(params, "hue") ?? "auto"
        guard Self.blobatarShapes.contains(shape), Self.blobatarHues.contains(hue) else { throw Error.invalidParams }
        let token = "blobatar:\(shape):\(hue)"
        _ = try store.updateProfile(id: bot.id, avatarSymbol: token, now: now)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "shape": shape,
            "hue": hue,
            "avatar_symbol": token,
        ])
    }

    private func handleSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let handle = BotHandle.normalize(string(params, "handle") ?? "") else { throw Error.invalidParams }
        do {
            _ = try store.renameHandle(id: bot.id, handle: handle)
        } catch BotPublishError.handleConflict {
            throw Error.handleConflict
        }
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["handle": handle])
    }

    private func soulSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let soul = string(params, "soul") ?? ""
        guard let revisionID = bot.currentRevisionID,
              let current = try store.getRevision(id: revisionID) else {
            throw Error.notFound
        }
        let draft = BotRevisionDraft(
            name: bot.name,
            title: current.title,
            description: current.description,
            soul: soul,
            permissionMode: current.permissionMode,
            desktopKind: current.desktopKind
        )
        _ = try store.publish(botID: bot.id, expectedCurrentRevisionID: revisionID, draft: draft)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["soul": soul])
    }

    private func routingSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let pref: [String: Any] = [
            "provider": string(params, "provider") ?? "grok",
            "model": string(params, "model") ?? "",
            "routing_mode": string(params, "routing_mode") ?? "auto",
            "permission_mode": string(params, "permission_mode") ?? "supervised",
            "reasoning_effort": string(params, "reasoning_effort") ?? "medium",
        ]
        routingPref[id(bot)] = pref
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: pref)
    }

    private func attentionAck(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        attention[id(bot)] = ["bot_id": id(bot), "state": "none", "source": "bot"]
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["state": "none"])
    }

    private func peerAsk(params: [String: Any], requestID: String) throws -> [String: Any] {
        let payload: [String: Any] = [
            "request_id": requestID,
            "status": Status.completed.rawValue,
            "handle": string(params, "handle") ?? "",
            "reply": "ok",
        ]
        peerReceipts[requestID] = payload
        return receipt(requestID: requestID, status: .completed, botID: string(params, "bot_id"), readback: payload)
    }

    private func selfConfig(params: [String: Any], requestID: String) throws -> [String: Any] {
        let payload: [String: Any] = [
            "request_id": requestID,
            "status": Status.completed.rawValue,
            "tool_name": string(params, "tool_name") ?? "",
        ]
        peerReceipts[requestID] = payload
        return receipt(requestID: requestID, status: .completed, botID: string(params, "bot_id"), readback: payload)
    }

    // MARK: - Helpers

    private func requireControlPlane() throws {
        guard settings.load().isBotControlPlaneActive else { throw Error.controlPlaneOff }
    }

    private func requireBot(_ params: [String: Any]) throws -> BotDefinition {
        guard let raw = string(params, "bot_id"), let uuid = UUID(uuidString: raw),
              let bot = try store.get(id: BotID(uuid)), bot.deletedAt == nil else {
            throw Error.notFound
        }
        return bot
    }

    private func id(_ bot: BotDefinition) -> String {
        bot.id.value.uuidString.lowercased()
    }

    private func encodeBot(_ bot: BotDefinition, extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "id": id(bot),
            "handle": bot.handle,
            "name": bot.name,
            "title": bot.title,
            "description": bot.description,
            "avatar_symbol": bot.avatarSymbol,
            "pinned": bot.pinned,
            "hidden": bot.hidden,
            "notifications_enabled": bot.notificationsEnabled,
            "workspace_id": NSNull(),
        ]
        for (key, value) in extra { body[key] = value }
        return body
    }

    private func encodeRoutine(_ routine: BotRoutine) -> [String: Any] {
        [
            "id": routine.definition.id.value.uuidString.lowercased(),
            "bot_id": routine.definition.botID.value.uuidString.lowercased(),
            "name": routine.definition.name,
            "prompt": routine.definition.prompt,
            "schedule_note": routine.definition.scheduleNote,
            "schedule_spec_json": routine.definition.scheduleSpecJSON,
            "enabled": routine.activation.isEnabled,
        ]
    }

    private func receipt(requestID: String, status: Status, botID: String?, readback: [String: Any]) -> [String: Any] {
        [
            "request_id": requestID,
            "receipt_id": UUID().uuidString.lowercased(),
            "status": status.rawValue,
            "bot_id": botID as Any,
            "readback": readback,
        ]
    }

    private func string(_ params: [String: Any], _ key: String) -> String? {
        params[key] as? String
    }

    private func bool(_ params: [String: Any], _ key: String) -> Bool? {
        if let value = params[key] as? Bool { return value }
        if let number = params[key] as? NSNumber { return number.boolValue }
        if let text = params[key] as? String {
            if text == "true" || text == "1" { return true }
            if text == "false" || text == "0" { return false }
        }
        return nil
    }

    private func stringArray(_ params: [String: Any], _ key: String) -> [String] {
        (params[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private func encodeQueue(_ records: [BotQueuedFollowUpRecord]) -> [[String: Any]] {
        records.map { record in
            var item: [String: Any] = [
                "id": record.id,
                "bot_id": record.botID.value.uuidString.lowercased(),
                "text": record.text,
                "created_at": record.createdAt.timeIntervalSince1970,
            ]
            if let conversationID = record.conversationID {
                item["conversation_id"] = conversationID
            }
            if let data = record.payloadJSON.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let attachments = object["attachments"] {
                item["attachments"] = attachments
            }
            return item
        }
    }

    private func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func botHome(_ bot: BotDefinition) -> BotHome {
        BotHome(appSupportDirectory: appSupport, bot: bot)
    }

    private func resolveFileEntry(bot: BotDefinition, handle: String) throws -> [String: Any] {
        if let entry = files[handle], entry["bot_id"] as? String == id(bot) {
            return entry
        }
        let botID = id(bot)
        let prefix = botID + ":"
        guard handle.hasPrefix(prefix) else { throw Error.invalidParams }
        let parts = String(handle.dropFirst(prefix.count))
            .split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 3, parts[0] == "bot_home" || parts[0] == "docker_home" else {
            throw Error.invalidParams
        }
        return [
            "handle": handle,
            "bot_id": botID,
            "root": parts[0],
            "path": parts[2],
            "generation": Int(parts[1]) ?? 0,
        ]
    }

    private func diskFileExists(bot: BotDefinition, root: String, path: String) throws -> Bool {
        if root == "docker_home" {
            let url = try containedURL(root: BotGuestHome.url(appSupport: appSupport, botID: bot.id), path: path)
            return FileManager.default.fileExists(atPath: url.path)
        }
        return FileManager.default.fileExists(atPath: try botHome(bot).resolvedURL(path).path)
    }

    private func handleFor(botID: String, root: String, path: String) -> String {
        if let existing = files.first(where: {
            ($0.value["bot_id"] as? String) == botID
                && ($0.value["root"] as? String) == root
                && ($0.value["path"] as? String) == path
        }) {
            return existing.key
        }
        return "\(botID):\(root):\(generation):\(path)"
    }

    private func applyDiskMutation(
        bot: BotDefinition,
        root: String,
        path: String,
        op: String,
        contents: String
    ) throws {
        if root == "docker_home" {
            let home = try BotGuestHome.ensure(appSupport: appSupport, botID: bot.id)
            let url = try containedURL(root: home, path: path)
            if op == "delete" {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
            return
        }
        let home = botHome(bot)
        try home.ensure(
            name: bot.name,
            handle: bot.handle,
            title: bot.title,
            description: bot.description,
            soul: ""
        )
        if op == "delete" {
            let url = try home.resolvedURL(path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } else {
            try home.writeFile(relativePath: path, contents: contents)
        }
    }

    private func listDiskPaths(bot: BotDefinition, root: String) throws -> [String] {
        if root == "docker_home" {
            return try enumerateRegularFiles(root: BotGuestHome.url(appSupport: appSupport, botID: bot.id))
        }
        return try enumerateRegularFiles(root: botHome(bot).root)
    }

    private func enumerateRegularFiles(root: URL) throws -> [String] {
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolvedRoot.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var paths: [String] = []
        let rootPath = resolvedRoot.path
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return paths.sorted()
    }

    private func containedURL(root: URL, path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("..") else {
            throw Error(code: -32086, message: "Path escapes Bot home containment.")
        }
        let url = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            throw Error(code: -32086, message: "Path escapes Bot home containment.")
        }
        return url
    }

    private func loadSidecar() {
        unpublished = Set(loadStringArray("bot.remote.unpublished"))
        if let data = loadData("bot.remote.receipts"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            receipts = decoded
        }
        if let data = loadData("bot.remote.files_location"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            filesLocation = decoded
        }
    }

    private func migrateSidecarQueueIfNeeded() {
        guard let data = loadData("bot.remote.queue"),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]]
        else { return }
        for (botRaw, items) in decoded {
            guard let uuid = UUID(uuidString: botRaw) else { continue }
            let botID = BotID(uuid)
            guard (try? store.get(id: botID))?.deletedAt == nil else { continue }
            if ((try? store.listQueuedFollowUps(botID: botID)) ?? []).isEmpty == false { continue }
            for item in items {
                let text = item["text"] as? String ?? ""
                guard !text.isEmpty else { continue }
                _ = try? store.enqueueQueuedFollowUp(
                    BotQueuedFollowUpRecord(
                        id: item["id"] as? String ?? UUID().uuidString.lowercased(),
                        botID: botID,
                        conversationID: item["conversation_id"] as? String,
                        text: text,
                        payloadJSON: jsonString(["attachments": item["attachments"] as Any]) ?? "{}",
                        createdAt: Date()
                    )
                )
            }
        }
        saveJSON("bot.remote.queue", [String: Any]())
    }

    private func persistSidecar() {
        saveJSON("bot.remote.unpublished", Array(unpublished).sorted())
        saveJSON("bot.remote.receipts", receipts)
        saveJSON("bot.remote.files_location", filesLocation)
    }

    private func loadData(_ key: String) -> Data? {
        try? db.performSync { database in
            let statement = try database.prepare("SELECT value FROM settings WHERE key = ? LIMIT 1;")
            defer { statement.reset() }
            try statement.bind(1, key)
            guard try statement.step(), let text = statement.columnText(0) else { return nil }
            return text.data(using: .utf8)
        } ?? nil
    }

    private func loadStringArray(_ key: String) -> [String] {
        guard let data = loadData(key),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return array
    }

    private func saveJSON(_ key: String, _ value: Any) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return }
        let iso = ISO8601DateFormatter().string(from: Date())
        try? db.performSync { database in
            let statement = try database.prepare(
                "INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
            )
            defer { statement.reset() }
            try statement.bind(1, key)
            try statement.bind(2, text)
            try statement.bind(3, iso)
            _ = try statement.step()
        }
    }
}
