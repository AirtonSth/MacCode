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
    private static let guestSecurity: [String: Any] = [
        "bot_bound": true,
        "host_bound": true,
        "opaque_grant": true,
        "loopback_url_exported": false,
        "bearer_exported": false,
    ]

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
        public static let guestConflict = Error(code: -32092, message: "Bot Guest authority is stale or does not match this host, Bot, task, runtime, grant, or frame.")
    }

    private let lock = NSLock()
    private let store: BotStore
    private let settings: SettingsStore
    private let db: SQLiteDB
    private let appSupport: URL
    private let browserStore: BotBrowserStore
    private let attentionBindings: BotAttentionPushBindingStore
    private let attentionNotificationMetadata: BotAttentionNotificationMetadataStore

    public var onHasLiveRun: ((BotID) -> Bool)?
    public var onStopRun: ((BotID, Bool, String) -> Void)?
    public var onStartGuest: ((BotID, String, String, [String: Any]) -> Void)?
    public var onStopGuest: ((BotID, String, [String: Any]) -> Void)?
    public var onRebuildGuest: ((BotID, String, [String: Any]) -> Void)?
    public var onGuestInput: ((BotID, [String: Any], String, [String: Any]) throws -> Void)?
    public var onDockerClear: ((BotID) throws -> Void)?
    public var onSend: ((BotID, String, BotConversationID?, [String: Any]) throws -> [String: Any])?
    public var onOpenFile: ((BotID, String, Bool, String) throws -> Void)?
    public var notifyBrowserPendingOpen: ((Notification.Name) throws -> Void)?

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
    private var routineRuntime: [String: [String: Any]] = [:]
    private var filesLocation: [String: String] = [:]
    private var fileGenerations: [String: Int] = [:]
    private var fileCAS: [String: String] = [:]
    private var fileHosts: [String: String] = [:]
    private var routingPref: [String: [String: Any]] = [:]
    private var consumedRoutingReceipts: Set<String> = []
    private var selectedConversation: [String: String] = [:]
    private var generation: Int = 1
#if DEBUG
    /// Exact per-write formatter path retained only for same-process A/B receipts.
    var useLegacySidecarDateFormatterForBenchmark = false
#endif

    public init(db: SQLiteDB, store: BotStore, settings: SettingsStore, appSupportDirectory: URL) {
        self.db = db
        self.store = store
        self.settings = settings
        self.appSupport = appSupportDirectory
        self.browserStore = BotBrowserStore(appSupportDirectory: appSupportDirectory)
        self.attentionBindings = BotAttentionPushBindingStore(db: db)
        self.attentionNotificationMetadata = BotAttentionNotificationMetadataStore(db: db)
        loadSidecar()
        invalidateRestoredGuestGrants()
        migrateSidecarQueueIfNeeded()
    }

    /// Upgrade an `accepted` receipt after `dispatch` returns. In-hook settle is
    /// overwritten by `mutate`, and `NSLock` is not recursive.
    public func settle(requestID: String, status: Status, readback: [String: Any]? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard var existing = receipts[requestID],
              (existing["status"] as? String) == Status.accepted.rawValue else { return }
        existing["status"] = status.rawValue
        if let readback {
            if let botID = existing["bot_id"] as? String,
               var current = guest[botID],
               readback["viewer_path"] != nil || readback["viewer"] != nil {
                for (key, value) in readback { current[key] = value }
                current["viewer"] = "/vnc.html"
                current["viewer_path"] = "/vnc.html"
                current["security"] = Self.guestSecurity
                guest[botID] = current
                existing["readback"] = current
            } else {
                existing["readback"] = readback
            }
        }
        receipts[requestID] = existing
        persistSidecar()
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
            return try guestState(params: params)
        case "receipt.status":
            return receiptStatus(params: params)
        case "peer.receipt.status":
            return peerReceiptStatus(params: params)
        case "attention.list":
            return ["items": attention.values.map { canonicalAttentionItem($0) }]
        case "reserved.probe":
            throw Error.reserved
        default:
            return try mutate(name: name, params: params, now: now)
        }
    }

    /// Settles only the exact live run previously admitted by `bot.send`.
    /// Generic Agent terminal events cannot move a different Bot or newer run.
    @discardableResult
    public func settleRuntime(
        botID: String,
        runID: String,
        failed: Bool,
        now: Date = Date()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let run = liveRuns[botID],
              run["run_id"] as? String == runID,
              var item = attention[botID],
              item["run_id"] as? String == runID else { return false }
        liveRuns.removeValue(forKey: botID)
        item["state"] = "finished"
        item["finished_at"] = now.timeIntervalSince1970
        item["detail"] = failed ? "Run failed" : "Run completed"
        item["outcome"] = failed ? "failed" : "completed"
        attention[botID] = canonicalAttentionItem(item)
        persistSidecar()
        return true
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
            var row: [String: Any] = [
                "id": conversation.id.value.uuidString.lowercased(),
                "title": conversation.title,
                "bot_id": bot.id.value.uuidString.lowercased(),
                "updated_at": conversation.updatedAt.timeIntervalSince1970,
            ]
            if let threadID = conversation.linkedAgentThreadID {
                row["linked_agent_thread_id"] = threadID.value.uuidString.lowercased()
            }
            return row
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
        let hostID = try requireFileHost(params: params, botID: botID)
        let root = filesLocation[botID] ?? "bot_home"
        let currentGeneration = fileGeneration(botID: botID, root: root)
        let paths = try listDiskPaths(bot: bot, root: root)
        let rootEntry = mintFileGrant(hostID: hostID, botID: botID, root: root, path: "", kind: "root")
        let entries = paths.map { mintFileGrant(hostID: hostID, botID: botID, root: root, path: $0, kind: "file") }
        persistSidecar()
        return [
            "bot_id": botID,
            "host_id": hostID,
            "root": root,
            "generation": currentGeneration,
            "root_cas": fileCASValue(botID: botID, root: root),
            "root_handle": rootEntry["handle"] as Any,
            "entries": entries,
            "security": fileSecurity(),
        ]
    }

    private func browserState(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        return try authoritativeBrowserState(bot: bot, hostID: string(params, "host_id"))
    }

    private func guestState(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let hostID = try requireGuestHost(params)
        if let existing = guest[botID] {
            guard existing["host_id"] as? String == hostID else { throw Error.guestConflict }
            return existing
        }
        let state = makeStoppedGuestState(botID: botID, hostID: hostID)
        guest[botID] = state
        persistSidecar()
        return state
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
            return try stop(params: params, requestID: requestID, force: name == "force_stop", now: now)
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
        case "guest.input", "guest.start", "guest.stop", "guest.rebuild", "guest.revoke":
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
        case "scheduler.tick":
            return try schedulerTick(params: params, now: now, requestID: requestID)
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
        let copiedRouting: [String: Any]?
        if var routing = routingPref[id(bot)] {
            routing.removeValue(forKey: "effective")
            routing["routing_receipt_id"] = UUID().uuidString.lowercased()
            routing["bot_id"] = id(copy)
            routing["effective"] = routing
            routingPref[id(copy)] = routing
            copiedRouting = routing
        } else {
            copiedRouting = nil
        }
        var duplicateReadback = encodeBot(copy, extra: [
            "source_bot_id": id(bot),
            "schedule_spec_jsons": specs,
        ])
        if let copiedRouting { duplicateReadback["routing"] = copiedRouting }
        return receipt(
            requestID: requestID,
            status: .completed,
            botID: id(copy),
            readback: duplicateReadback
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
        let hostID = string(params, "host_id") ?? ""
        let requestedConversationID = string(params, "conversation_id")
        let conversation: BotConversationID?
        if let requestedConversationID, !requestedConversationID.isEmpty {
            guard let uuid = UUID(uuidString: requestedConversationID),
                  let stored = try store.conversation(id: BotConversationID(uuid)),
                  stored.botID == bot.id else {
                throw Error.crossTarget
            }
            conversation = stored.id
        } else {
            conversation = nil
        }
        let routing = try effectiveRouting(
            botID: botID,
            params: params
        )
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
        // Production delegates live-run queueing to BotsViewModel so the
        // receipt can bind the authoritative conversation/thread/run. The
        // standalone path remains for persistence-level callers without a UI
        // runtime hook.
        if live, onSend == nil {
            var payload: [String: Any] = ["attachments": bound]
            if let conversationID = requestedConversationID ?? selectedConversation[botID] {
                payload["conversation_id"] = conversationID
            }
            payload["routing"] = routing
            let payloadJSON = jsonString(payload) ?? "{}"
            let stored = try store.enqueueQueuedFollowUp(
                BotQueuedFollowUpRecord(
                    botID: bot.id,
                    conversationID: requestedConversationID ?? selectedConversation[botID],
                    text: text,
                    payloadJSON: payloadJSON,
                    createdAt: now
                )
            )
            if let routingReceiptID = routing["routing_receipt_id"] as? String {
                consumedRoutingReceipts.insert(routingReceiptID)
            }
            let conversationID = requestedConversationID ?? selectedConversation[botID]
            let runID = liveRuns[botID]?["run_id"] as? String ?? ""
            return runtimeReceipt(
                requestID: requestID,
                hostID: hostID,
                botID: botID,
                conversationID: conversationID,
                runID: runID,
                readback: [
                    "enqueued": true,
                    "queue": encodeQueue(try store.listQueuedFollowUps(botID: bot.id)),
                    "id": stored.id,
                    "routing_receipt_id": routing["routing_receipt_id"] ?? NSNull(),
                    "effective_routing": routing,
                ]
            )
        }
        let authoritativeSend: [String: Any]
        if let onSend {
            authoritativeSend = try onSend(bot.id, text, conversation, routing)
            guard authoritativeSend["bot_id"] as? String == botID,
                  let admittedConversationID = authoritativeSend["conversation_id"] as? String,
                  let admittedConversationUUID = UUID(uuidString: admittedConversationID),
                  let admittedConversation = try store.conversation(
                    id: BotConversationID(admittedConversationUUID)
                  ),
                  admittedConversation.botID == bot.id,
                  let admittedRunID = authoritativeSend["run_id"] as? String,
                  !admittedRunID.isEmpty,
                  let admittedThreadID = authoritativeSend["thread_id"] as? String,
                  !admittedThreadID.isEmpty,
                  authoritativeSend["queued_follow_up"] as? Bool != nil else {
                throw Error.crossTarget
            }
        } else {
            authoritativeSend = [
                "bot_id": botID,
                "conversation_id": (requestedConversationID ?? selectedConversation[botID])
                    .map { $0 as Any } ?? NSNull(),
                "run_id": UUID().uuidString.lowercased(),
                "enqueued": false,
            ]
        }
        let runID = authoritativeSend["run_id"] as? String
            ?? UUID().uuidString.lowercased()
        let conversationID = authoritativeSend["conversation_id"] as? String
            ?? requestedConversationID
            ?? selectedConversation[botID]
        if let conversationID {
            selectedConversation[botID] = conversationID
        }
        if authoritativeSend["queued_follow_up"] as? Bool == true {
            return runtimeReceipt(
                requestID: requestID,
                hostID: hostID,
                botID: botID,
                conversationID: conversationID,
                runID: runID,
                readback: [
                    "enqueued": true,
                    "id": authoritativeSend["id"] ?? NSNull(),
                    "queue": encodeQueue(try store.listQueuedFollowUps(botID: bot.id)),
                    "routing_receipt_id": routing["routing_receipt_id"] ?? NSNull(),
                    "effective_routing": routing,
                ]
            )
        }
        var liveRun: [String: Any] = [
            "bot_id": botID,
            "host_id": hostID,
            "request_id": requestID,
            "client_request_id": requestID,
            "status": "working",
            "text": text,
            "started_at": now.timeIntervalSince1970,
            "run_id": runID,
            "conversation_id": conversationID ?? NSNull(),
            "routing": routing,
        ]
        if let threadID = authoritativeSend["thread_id"] as? String, !threadID.isEmpty {
            liveRun["thread_id"] = threadID
        }
        liveRuns[botID] = liveRun
        attention[botID] = canonicalAttentionItem([
            "id": UUID().uuidString.lowercased(),
            "bot_id": botID,
            "conversation_id": conversationID ?? NSNull(),
            "run_id": runID,
            "state": "working",
            "finished_at": NSNull(),
            "ownership": "primary",
            "primary": true,
            "delegated": false,
            "title": bot.name,
            "detail": text,
            "source": "bot",
        ], hostID: string(params, "host_id"))
        if let routingReceiptID = routing["routing_receipt_id"] as? String {
            consumedRoutingReceipts.insert(routingReceiptID)
        }
        return runtimeReceipt(
            requestID: requestID,
            hostID: hostID,
            botID: botID,
            conversationID: conversationID,
            runID: runID,
            readback: [
                "enqueued": false,
                "run": liveRuns[botID] as Any,
                "workspace": NSNull(),
                "routing_receipt_id": routing["routing_receipt_id"] ?? NSNull(),
                "effective_routing": routing,
            ]
        )
    }

    private func queueRemove(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let itemID = string(params, "id") ?? ""
        try store.removeQueuedFollowUp(botID: bot.id, id: itemID)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "queue": encodeQueue(try store.listQueuedFollowUps(botID: bot.id)),
        ])
    }

    private func stop(
        params: [String: Any],
        requestID: String,
        force: Bool,
        now: Date
    ) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let hadLive = onHasLiveRun?(bot.id) ?? (liveRuns[botID] != nil)
        let run = liveRuns[botID]
        let liveStop = onStopRun != nil
        onStopRun?(bot.id, force, requestID)
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
        let item = canonicalAttentionItem([
            "id": attention[botID]?["id"] ?? UUID().uuidString.lowercased(),
            "bot_id": botID,
            "conversation_id": run?["conversation_id"] ?? NSNull(),
            "run_id": run?["run_id"] ?? NSNull(),
            "state": drained == nil ? "finished" : "working",
            "finished_at": drained == nil
                ? now.timeIntervalSince1970 as Any
                : NSNull(),
            "ownership": "primary",
            "primary": true,
            "delegated": false,
            "title": bot.name,
            "detail": drained == nil ? "Finished" : "Running queued follow-up",
            "source": "bot",
        ], hostID: string(params, "host_id"))
        attention[botID] = item
        let terminal = hadLive || run != nil
        let notification = drained == nil && !liveStop && terminal
            ? try persistAttentionNotification(item, now: now)
            : nil
        var readback: [String: Any] = [
            "accepted": true,
            "force": force,
            "terminal": terminal,
            "run": run as Any,
            "drained": drained as Any,
            "queue": encodeQueue(try store.listQueuedFollowUps(botID: bot.id)),
        ]
        if let notification { readback["notification"] = notification }
        return receipt(
            requestID: requestID,
            status: liveStop ? .accepted : .completed,
            botID: botID,
            readback: readback
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
        let routineKey = definition.id.value.uuidString.lowercased()
        var runtime = routineRuntime[routineKey] ?? [:]
        runtime["next_run_at"] = dateValue(nextRunDate(
            definition: definition,
            enabled: (try store.listRoutines(botID: bot.id).first {
                $0.definition.id == definition.id
            })?.activation.isEnabled == true,
            after: now
        ))
        routineRuntime[routineKey] = runtime
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "routine_id": definition.id.value.uuidString.lowercased(),
            "schedule_spec_json": specJSON,
            "next_run_at": runtime["next_run_at"] ?? NSNull(),
        ])
    }

    private func routineEnable(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let raw = string(params, "routine_id"), let uuid = UUID(uuidString: raw) else { throw Error.invalidParams }
        let enabled = bool(params, "enabled") ?? false
        try store.setRoutineEnabled(id: BotRoutineID(uuid), enabled: enabled)
        let stored = try store.listRoutines(botID: bot.id).first {
            $0.definition.id == BotRoutineID(uuid)
        }
        let nextRunAt = stored.flatMap {
            nextRunDate(definition: $0.definition, enabled: enabled, after: now)
        }
        var runtime = routineRuntime[raw.lowercased()] ?? [:]
        runtime["next_run_at"] = dateValue(nextRunAt)
        routineRuntime[raw.lowercased()] = runtime
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "routine_id": raw.lowercased(),
            "enabled": enabled,
            "next_run_at": dateValue(nextRunAt),
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
        var runtime = routineRuntime[routineID.lowercased()] ?? [:]
        runtime["last_run_id"] = run["run_id"]
        runtime["last_execution_at"] = now.timeIntervalSince1970
        runtime["last_result"] = run["result"]
        if let routine = try store.listRoutines(botID: bot.id).first(where: {
            $0.definition.id.value.uuidString.caseInsensitiveCompare(routineID) == .orderedSame
        }) {
            runtime["next_run_at"] = dateValue(nextRunDate(
                definition: routine.definition,
                enabled: routine.activation.isEnabled,
                after: now
            ))
        }
        routineRuntime[routineID.lowercased()] = runtime
        attention[id(bot)] = canonicalAttentionItem([
            "id": UUID().uuidString.lowercased(),
            "bot_id": id(bot),
            "conversation_id": selectedConversation[id(bot)] ?? NSNull(),
            "run_id": run["run_id"] ?? NSNull(),
            "state": "working",
            "finished_at": NSNull(),
            "ownership": "primary",
            "primary": true,
            "delegated": false,
            "title": "Routine: \(routineID)",
            "detail": "Manual routine run accepted",
            "source": "routine",
        ], hostID: string(params, "host_id"))
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: run)
    }

    private func routineDelete(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let raw = string(params, "routine_id"), let uuid = UUID(uuidString: raw) else { throw Error.invalidParams }
        try store.deleteRoutine(id: BotRoutineID(uuid))
        routineRuntime.removeValue(forKey: raw.lowercased())
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["deleted": true])
    }

    private func schedulerTick(params: [String: Any], now: Date, requestID: String) throws -> [String: Any] {
        var fired: [[String: Any]] = []
        var notifications: [[String: Any]] = []
        for bot in try store.list() {
            for routine in try store.listRoutines(botID: bot.id) where routine.activation.isEnabled {
                let routineKey = routine.definition.id.value.uuidString.lowercased()
                let persistedDue = routineRuntime[routineKey]?["next_run_at"] as? Double
                guard let due = persistedDue else {
                    var runtime = routineRuntime[routineKey] ?? [:]
                    runtime["next_run_at"] = dateValue(nextRunDate(
                        definition: routine.definition,
                        enabled: true,
                        after: now
                    ))
                    routineRuntime[routineKey] = runtime
                    continue
                }
                guard due <= now.timeIntervalSince1970 else { continue }
                let run: [String: Any] = [
                    "run_id": UUID().uuidString.lowercased(),
                    "routine_id": routineKey,
                    "bot_id": id(bot),
                    "executed_at": now.timeIntervalSince1970,
                    "scheduled_at": due,
                    "automatic": true,
                    "result": "completed",
                    "schedule_spec_json": routine.definition.scheduleSpecJSON,
                ]
                schedulerRuns.append(run)
                var runtime = routineRuntime[routineKey] ?? [:]
                runtime["last_run_id"] = run["run_id"]
                runtime["last_execution_at"] = now.timeIntervalSince1970
                runtime["last_result"] = "completed"
                runtime["next_run_at"] = dateValue(nextRunDate(
                    definition: routine.definition,
                    enabled: true,
                    after: Date(timeIntervalSince1970: due).addingTimeInterval(
                        ScheduledTaskOccurrenceCalculator.spentOccurrenceAdvance
                    )
                ))
                routineRuntime[routineKey] = runtime
                let item = canonicalAttentionItem([
                    "id": UUID().uuidString.lowercased(),
                    "bot_id": id(bot),
                    "conversation_id": selectedConversation[id(bot)] ?? NSNull(),
                    "run_id": run["run_id"] ?? NSNull(),
                    "state": "finished",
                    "finished_at": now.timeIntervalSince1970,
                    "ownership": "primary",
                    "primary": true,
                    "delegated": false,
                    "title": routine.definition.name,
                    "detail": "Scheduled routine completed",
                    "source": "routine",
                ], hostID: string(params, "host_id"))
                attention[id(bot)] = item
                if let notification = try persistAttentionNotification(item, now: now) {
                    notifications.append(notification)
                }
                fired.append(run)
            }
        }
        return receipt(requestID: requestID, status: .completed, botID: nil, readback: [
            "runs": fired,
            "notifications": notifications,
        ])
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
        let hostID = try requireFileHost(params: params, botID: botID)
        let rootHandle = string(params, "root_handle") ?? ""
        guard !rootHandle.isEmpty else { throw Error.invalidParams }
        let rootEntry = try resolveFileEntry(bot: bot, handle: rootHandle)
        let handle = string(params, "handle")
        let entry = try handle.map { try resolveFileEntry(bot: bot, handle: $0) } ?? rootEntry
        guard entry["host_id"] as? String == hostID else { throw Error.crossTarget }
        let root = entry["root"] as? String ?? ""
        let selectedRoot = filesLocation[botID] ?? "bot_home"
        let currentGeneration = fileGeneration(botID: botID, root: root)
        let currentCAS = fileCASValue(botID: botID, root: root)
        let grantedGeneration = entry["generation"] as? Int ?? 0
        let grantedCAS = entry["cas"] as? String ?? ""
        guard let expectedGeneration = int(params, "expected_generation") ?? int(params, "generation"),
              let expectedCAS = string(params, "expected_cas") ?? string(params, "cas"),
              !expectedCAS.isEmpty else { throw Error.invalidParams }
        guard root == selectedRoot,
              rootEntry["host_id"] as? String == hostID,
              rootEntry["root"] as? String == selectedRoot,
              rootEntry["kind"] as? String == "root",
              rootEntry["generation"] as? Int == currentGeneration,
              rootEntry["cas"] as? String == currentCAS,
              grantedGeneration == currentGeneration,
              grantedCAS == currentCAS,
              expectedGeneration == currentGeneration,
              expectedCAS == currentCAS else {
            return fileConflictReceipt(
                requestID: requestID,
                hostID: hostID,
                botID: botID,
                root: selectedRoot,
                expectedGeneration: expectedGeneration,
                expectedCAS: expectedCAS
            )
        }
        let kind = entry["kind"] as? String ?? "file"
        guard (handle == nil && kind == "root") || (handle != nil && kind == "file") else {
            throw Error.invalidParams
        }
        let path = kind == "root"
            ? (string(params, "relative_path") ?? "")
            : (entry["path"] as? String ?? "")
        guard !path.isEmpty else { throw Error.invalidParams }
        let op = string(params, "op") ?? "write"
        guard op == "write" || op == "delete" else { throw Error.invalidParams }
        let contents = string(params, "contents") ?? string(params, "body") ?? ""
        try applyDiskMutation(bot: bot, root: root, path: path, op: op, contents: contents)
        let nextGeneration = currentGeneration + 1
        fileGenerations[fileGenerationKey(botID: botID, root: root)] = nextGeneration
        let nextCAS = rotateFileCAS(botID: botID, root: root)
        let nextEntry = op == "delete"
            ? nil
            : mintFileGrant(hostID: hostID, botID: botID, root: root, path: path, kind: "file")
        var readback: [String: Any] = [
            "bot_id": botID,
            "host_id": hostID,
            "root": root,
            "path": path,
            "previous_generation": currentGeneration,
            "previous_cas": currentCAS,
            "generation": nextGeneration,
            "root_cas": nextCAS,
            "root_handle": mintFileGrant(hostID: hostID, botID: botID, root: root, path: "", kind: "root")["handle"] as Any,
            "op": op,
            "security": fileSecurity(),
        ]
        if let nextEntry {
            readback["handle"] = nextEntry["handle"]
            readback["entry_generation"] = nextEntry["generation"]
            readback["entry_cas"] = nextEntry["cas"]
        }
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: readback)
    }

    private func filesOpen(params: [String: Any], requestID: String, split: Bool) throws -> [String: Any] {
        let bot = try requireBot(params)
        let hostID = try requireFileHost(params: params, botID: id(bot))
        let rootHandle = string(params, "root_handle") ?? ""
        let handle = string(params, "handle") ?? ""
        guard !rootHandle.isEmpty, !handle.isEmpty else { throw Error.invalidParams }
        let rootEntry = try resolveFileEntry(bot: bot, handle: rootHandle)
        let entry = try resolveFileEntry(bot: bot, handle: handle)
        guard entry["host_id"] as? String == hostID else { throw Error.crossTarget }
        let root = (entry["root"] as? String) ?? (filesLocation[id(bot)] ?? "bot_home")
        let currentGeneration = fileGeneration(botID: id(bot), root: root)
        let currentCAS = fileCASValue(botID: id(bot), root: root)
        guard let expectedGeneration = int(params, "expected_generation") ?? int(params, "generation"),
              let expectedCAS = string(params, "expected_cas") ?? string(params, "cas"),
              !expectedCAS.isEmpty else { throw Error.invalidParams }
        guard root == (filesLocation[id(bot)] ?? "bot_home"),
              rootEntry["host_id"] as? String == hostID,
              rootEntry["root"] as? String == root,
              rootEntry["kind"] as? String == "root",
              rootEntry["generation"] as? Int == currentGeneration,
              rootEntry["cas"] as? String == currentCAS,
              entry["kind"] as? String == "file",
              entry["generation"] as? Int == currentGeneration,
              entry["cas"] as? String == currentCAS,
              expectedGeneration == currentGeneration,
              expectedCAS == currentCAS else {
            return fileConflictReceipt(
                requestID: requestID,
                hostID: hostID,
                botID: id(bot),
                root: filesLocation[id(bot)] ?? "bot_home",
                expectedGeneration: expectedGeneration,
                expectedCAS: expectedCAS
            )
        }
        let path = entry["path"] as? String ?? ""
        guard try diskFileExists(bot: bot, root: root, path: path) else {
            throw Error(code: -32090, message: "Bot file was not found.")
        }
        if let onOpenFile {
            try onOpenFile(bot.id, path, split, root)
        }
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "bot_id": id(bot),
            "mounted": true,
            "host_id": hostID,
            "split": split,
            "handle": handle,
            "path": path,
            "root": root,
            "generation": currentGeneration,
            "root_cas": currentCAS,
            "root_handle": rootHandle,
            "entry_generation": entry["generation"] as Any,
            "entry_cas": entry["cas"] as Any,
            "security": fileSecurity(),
        ])
    }

    private func filesLocationSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let hostID = try requireFileHost(params: params, botID: botID)
        let root = string(params, "root") ?? "bot_home"
        guard root == "bot_home" || root == "docker_home" else { throw Error.invalidParams }
        let previousRoot = filesLocation[botID] ?? "bot_home"
        let currentGeneration = fileGeneration(botID: botID, root: previousRoot)
        let currentCAS = fileCASValue(botID: botID, root: previousRoot)
        let expectedHandle = string(params, "previous_root_handle") ?? string(params, "expected_handle") ?? ""
        guard let expectedGeneration = int(params, "expected_generation"),
              let expectedCAS = string(params, "expected_cas"),
              !expectedHandle.isEmpty, !expectedCAS.isEmpty else { throw Error.invalidParams }
        let previousGrant = try resolveFileEntry(bot: bot, handle: expectedHandle)
        if previousGrant["kind"] as? String != "root"
            || previousGrant["root"] as? String != previousRoot
            || previousGrant["generation"] as? Int != currentGeneration
            || previousGrant["cas"] as? String != currentCAS
            || expectedGeneration != currentGeneration
            || expectedCAS != currentCAS {
            return fileConflictReceipt(
                requestID: requestID,
                hostID: hostID,
                botID: botID,
                root: previousRoot,
                expectedGeneration: expectedGeneration,
                expectedCAS: expectedCAS
            )
        }
        if root == "docker_home" { _ = try BotGuestHome.ensure(appSupport: appSupport, botID: bot.id) }
        if root != previousRoot {
            fileGenerations[fileGenerationKey(botID: botID, root: previousRoot)] = currentGeneration + 1
            _ = rotateFileCAS(botID: botID, root: previousRoot)
            files = files.filter { $0.value["bot_id"] as? String != botID }
        }
        filesLocation[botID] = root
        let rootEntry = mintFileGrant(hostID: hostID, botID: botID, root: root, path: "", kind: "root")
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: [
            "bot_id": botID,
            "host_id": hostID,
            "root": root,
            "previous_root": previousRoot,
            "previous_generation": currentGeneration,
            "previous_cas": currentCAS,
            "generation": fileGeneration(botID: botID, root: root),
            "root_cas": fileCASValue(botID: botID, root: root),
            "root_handle": rootEntry["handle"] as Any,
            "security": fileSecurity(),
        ])
    }

    private func browserAction(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let before = try authoritativeBrowserState(bot: bot, hostID: string(params, "host_id"))
        let currentGeneration = before["generation"] as? Int ?? 0
        if let expected = int(params, "expected_generation"), expected != currentGeneration {
            return browserConflictReceipt(requestID: requestID, botID: botID, current: before, expected: expected)
        }
        if let surfaceID = string(params, "surface_id"), surfaceID != before["surface_id"] as? String {
            throw Error.crossTarget
        }
        if let snapshot = int(params, "snapshot_generation"), snapshot != currentGeneration {
            return browserConflictReceipt(requestID: requestID, botID: botID, current: before, expected: snapshot)
        }
        let action = (string(params, "action") ?? "navigate").lowercased()
        let url = string(params, "url") ?? (before["url"] as? String) ?? ""
        let title = string(params, "title") ?? (before["title"] as? String) ?? url
        let beforeSession = before["session"] as? [String: Any] ?? [:]
        if action == "login.complete" {
            let page = try browserStore.loadPageState(botID: bot.id) ?? BotBrowserPageState(url: url, title: title)
            guard BotBrowserLoginPredicate.standard.isLoggedIn(page, openedURL: url) else {
                return receipt(requestID: requestID, status: .failed, botID: botID, readback: [
                    "bot_id": botID,
                    "error": "Login is not complete in the host-owned Bot browser session.",
                    "login_state": "pending",
                    "recovery": ["method": "bot.browser.state", "bot_id": botID],
                ])
            }
        } else if action != "login.cancel" && action != "navigate" && action != "open" {
            return receipt(requestID: requestID, status: .failed, botID: botID, readback: [
                "bot_id": botID,
                "error": "Browser action is not admitted by the paired host.",
                "action": action,
                "recovery": ["method": "bot.browser.state", "bot_id": botID],
            ])
        }
        if action == "navigate" || action == "open" {
            guard !url.isEmpty else { throw Error.invalidParams }
        do {
            _ = try BotBrowserHost.requestOpen(
                store: browserStore,
                botID: bot.id,
                url: url,
                title: title.isEmpty ? nil : title,
                notify: { name in
                    if let notifyBrowserPendingOpen {
                        try notifyBrowserPendingOpen(name)
                    } else {
                        DistributedNotificationCenter.default().post(name: name, object: nil)
                    }
                }
            )
        } catch {
            throw Error(code: -32087, message: "Bot browser persist failed.")
        }
        if action == "login.cancel" {
            let remaining = try browserStore.loadPendingOpens().filter { $0.botID != botID }
            try browserStore.replacePendingOpens(remaining)
        }
        }
        let nextGeneration = currentGeneration + 1
        var persisted: [String: Any] = [
            "generation": nextGeneration,
            "session_id": beforeSession["id"] as? String ?? UUID().uuidString.lowercased(),
            "session_digest": UUID().uuidString.lowercased(),
            "login_state": action == "login.complete" ? "authenticated" : (action == "login.cancel" ? "cancelled" : "pending"),
            "host_id": string(params, "host_id") ?? before["host_id"] as? String ?? "",
        ]
        browser[botID] = persisted
        var state = try authoritativeBrowserState(bot: bot, hostID: string(params, "host_id"))
        state["action"] = action
        state["action_id"] = requestID
        state["session_before_digest"] = beforeSession["digest"] as Any
        state["session_after_digest"] = persisted["session_digest"]
        persisted["url"] = state["url"]
        persisted["title"] = state["title"]
        browser[botID] = persisted
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: state)
    }

    private func linkOpen(params: [String: Any], requestID: String) throws -> [String: Any] {
        let url = string(params, "url") ?? ""
        guard !url.isEmpty else { throw Error.invalidParams }
        return try browserAction(
            params: params.merging(["action": "open", "url": url]) { _, new in new },
            requestID: requestID
        )
    }

    private func guestCommand(name: String, params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let hostID = try requireGuestHost(params)
        _ = try BotGuestHome.ensure(appSupport: appSupport, botID: bot.id)
        var state = guest[botID] ?? makeStoppedGuestState(botID: botID, hostID: hostID)
        guard state["host_id"] as? String == hostID,
              let taskID = string(params, "task_id"),
              let task = guestTask(id: taskID, state: state),
              task["operation"] as? String == "bot.\(name)" else {
            throw Error.guestConflict
        }
        let status: String
        let receiptStatus: Status
        switch name {
        case "guest.start":
            guard let recipeID = string(params, "recipe_id"),
                  recipeID == task["recipe_id"] as? String else { throw Error.guestConflict }
            let runtime = makeGuestRuntime(
                botID: botID,
                hostID: hostID,
                recipeID: recipeID,
                previousState: state
            )
            state["runtime"] = runtime
            state["frame"] = nil
            state["error_message"] = nil
            state["recovery"] = nil
            state["grant_invalidated"] = false
            state["recipe"] = task["recipe"]
            onStartGuest?(bot.id, recipeID, requestID, state)
            status = "starting"
            receiptStatus = .accepted
        case "guest.rebuild":
            try requireGuestRuntime(params: params, state: state)
            let recipeID = ((state["runtime"] as? [String: Any])?["recipe_id"] as? String)
                ?? (task["recipe_id"] as? String)
                ?? ""
            state["runtime"] = makeGuestRuntime(
                botID: botID,
                hostID: hostID,
                recipeID: recipeID,
                previousState: state
            )
            state["frame"] = nil
            state["error_message"] = nil
            state["recovery"] = nil
            state["grant_invalidated"] = false
            onRebuildGuest?(bot.id, requestID, state)
            status = "starting"
            receiptStatus = .accepted
        case "guest.stop":
            try requireGuestRuntime(params: params, state: state)
            invalidateGuestGrant(state: &state, status: "stopping")
            onStopGuest?(bot.id, requestID, state)
            status = "stopping"
            receiptStatus = .accepted
        case "guest.revoke":
            try requireGuestRuntime(params: params, state: state)
            invalidateGuestGrant(state: &state, status: "revoked")
            status = "revoked"
            receiptStatus = .completed
        case "guest.input":
            guard let onGuestInput else {
                throw Error(code: -32091, message: "Bot guest input is unavailable.")
            }
            try validateGuestInput(params: params, task: task, state: state)
            state["input"] = [
                "task_id": taskID,
                "axis": task["axis"] as Any,
                "before_frame_id": string(params, "before_frame_id") as Any,
                "atomic": (task["axis"] as? String) == "drag",
            ]
            try onGuestInput(bot.id, params, requestID, state)
            status = "running"
            receiptStatus = .accepted
        default:
            throw Error.invalidParams
        }
        state["status"] = status
        state["viewer"] = "/vnc.html"
        state["viewer_path"] = "/vnc.html"
        state["last_request_id"] = requestID
        state["security"] = Self.guestSecurity
        state["embed_html_is_not_runtime"] = true
        guest[botID] = state
        return receipt(requestID: requestID, status: receiptStatus, botID: botID, readback: state)
    }

    private func requireGuestHost(_ params: [String: Any]) throws -> String {
        let hostID = string(params, "host_id")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !hostID.isEmpty, hostID.count <= 256 else { throw Error.guestConflict }
        return hostID
    }

    private func makeStoppedGuestState(botID: String, hostID: String) -> [String: Any] {
        [
            "host_id": hostID,
            "bot_id": botID,
            "status": "stopped",
            "viewer": "/vnc.html",
            "viewer_path": "/vnc.html",
            "grant_generation": 0,
            "grant_invalidated": true,
            "task_catalog": makeGuestTaskCatalog(botID: botID),
            "security": Self.guestSecurity,
            "embed_html_is_not_runtime": true,
        ]
    }

    private func makeGuestTaskCatalog(botID: String) -> [String: Any] {
        let recipeID = UUID().uuidString.lowercased()
        let recipe: [String: Any] = [
            "id": recipeID,
            "immutable": true,
            "image_reference": BotComputerGuestSpec.imageTag,
            "container_id": BotComputerGuestSpec.containerName(botID: BotID(UUID(uuidString: botID)!)),
            "viewer_path": "/vnc.html",
        ]
        func task(
            _ title: String,
            axis: String,
            operation: String,
            mode: String,
            includesRecipe: Bool = false
        ) -> [String: Any] {
            var result: [String: Any] = [
                "id": UUID().uuidString.lowercased(),
                "title": title,
                "axis": axis,
                "operation": operation,
                "interaction_mode": mode,
            ]
            if includesRecipe {
                result["recipe_id"] = recipeID
                result["recipe"] = recipe
            }
            return result
        }
        return [
            "id": UUID().uuidString.lowercased(),
            "generation": 1,
            "tasks": [
                task("Pointer", axis: "pointer", operation: "bot.guest.input", mode: "HOSTED_GUEST"),
                task("Key", axis: "key", operation: "bot.guest.input", mode: "HOSTED_GUEST"),
                task("Text", axis: "text", operation: "bot.guest.input", mode: "HOSTED_GUEST"),
                task("Drag", axis: "drag", operation: "bot.guest.input", mode: "HOSTED_GUEST"),
                task("Start", axis: "start", operation: "bot.guest.start", mode: "HOST_RUNTIME_RPC", includesRecipe: true),
                task("Try again", axis: "tryAgain", operation: "bot.guest.start", mode: "HOST_RUNTIME_RPC", includesRecipe: true),
                task("Rebuild", axis: "rebuild", operation: "bot.guest.rebuild", mode: "HOST_RUNTIME_RPC"),
                task("Stop", axis: "stop", operation: "bot.guest.stop", mode: "HOST_RUNTIME_RPC"),
                task("Fullscreen", axis: "fullscreen", operation: "bot.guest.state", mode: "HOST_RUNTIME_RPC"),
                task("Error", axis: "error", operation: "bot.guest.state", mode: "HOST_RUNTIME_RPC"),
                task("Refresh frame", axis: "frameObserve", operation: "bot.guest.state", mode: "HOST_RUNTIME_RPC"),
                task("Revoke access", axis: "grantRevoke", operation: "bot.guest.revoke", mode: "HOST_RUNTIME_RPC"),
                task("Reconnect", axis: "reconnect", operation: "bot.guest.state", mode: "HOST_RUNTIME_RPC"),
                task("Recover", axis: "recovery", operation: "bot.guest.start", mode: "HOST_RUNTIME_RPC", includesRecipe: true),
            ],
        ]
    }

    private func guestTask(id taskID: String, state: [String: Any]) -> [String: Any]? {
        guard let catalog = state["task_catalog"] as? [String: Any],
              let tasks = catalog["tasks"] as? [[String: Any]] else { return nil }
        return tasks.first { $0["id"] as? String == taskID }
    }

    private func makeGuestRuntime(
        botID: String,
        hostID: String,
        recipeID: String,
        previousState: [String: Any]
    ) -> [String: Any] {
        let previousRuntime = previousState["runtime"] as? [String: Any]
        let currentGeneration = previousRuntime?["grant_generation"] as? Int
            ?? previousState["grant_generation"] as? Int
            ?? 0
        return [
            "host_id": hostID,
            "bot_id": botID,
            "container_id": BotComputerGuestSpec.containerName(botID: BotID(UUID(uuidString: botID)!)),
            "app_run_id": UUID().uuidString.lowercased(),
            "viewer_id": UUID().uuidString.lowercased(),
            "viewer_path": "/vnc.html",
            "session_id": UUID().uuidString.lowercased(),
            "grant_id": UUID().uuidString.lowercased(),
            "grant_generation": currentGeneration + 1,
            "recipe_id": recipeID,
            "image_reference": BotComputerGuestSpec.imageTag,
        ]
    }

    private func requireGuestRuntime(params: [String: Any], state: [String: Any]) throws {
        guard state["status"] as? String == "running",
              state["grant_invalidated"] as? Bool == false,
              let expected = state["runtime"] as? [String: Any],
              let supplied = params["runtime"] as? [String: Any] else {
            throw Error.guestConflict
        }
        for key in [
            "host_id", "bot_id", "container_id", "app_run_id", "viewer_id",
            "viewer_path", "session_id", "grant_id", "grant_generation",
            "recipe_id", "image_reference",
        ] where !Self.guestValuesEqual(expected[key], supplied[key]) {
            throw Error.guestConflict
        }
    }

    private func validateGuestInput(
        params: [String: Any],
        task: [String: Any],
        state: [String: Any]
    ) throws {
        try requireGuestRuntime(params: params, state: state)
        guard let frame = state["frame"] as? [String: Any],
              let frameID = frame["frame_id"] as? String,
              frameID == string(params, "before_frame_id"),
              let width = frame["pixel_width"] as? Int,
              let height = frame["pixel_height"] as? Int,
              let input = params["input"] as? [String: Any],
              let kind = input["kind"] as? String,
              kind == task["axis"] as? String else { throw Error.guestConflict }
        func point(_ xKey: String, _ yKey: String) -> Bool {
            guard let x = input[xKey] as? Int, let y = input[yKey] as? Int else { return false }
            return (0..<width).contains(x) && (0..<height).contains(y)
        }
        switch kind {
        case "pointer":
            guard point("x", "y") else { throw Error.invalidParams }
        case "drag":
            guard point("from_x", "from_y"), point("to_x", "to_y"),
                  input["from_x"] as? Int != input["to_x"] as? Int
                    || input["from_y"] as? Int != input["to_y"] as? Int else {
                throw Error.invalidParams
            }
        case "text":
            let text = (input["text"] as? String) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 2_000 else { throw Error.invalidParams }
        case "key":
            let allowed = Set(["Return", "Escape", "Tab", "Shift+Tab", "BackSpace", "Up", "Down", "Left", "Right"])
            guard let key = input["key"] as? String, allowed.contains(key) else { throw Error.invalidParams }
        default:
            throw Error.invalidParams
        }
    }

    private func invalidateGuestGrant(state: inout [String: Any], status: String) {
        let previousGeneration = (state["runtime"] as? [String: Any])?["grant_generation"] as? Int
            ?? state["grant_generation"] as? Int
            ?? 0
        state["status"] = status
        state["grant_generation"] = previousGeneration + 1
        state["grant_invalidated"] = true
        state["runtime"] = nil
        state["frame"] = nil
        state["input"] = nil
    }

    private func invalidateRestoredGuestGrants() {
        guard !guest.isEmpty else { return }
        for botID in Array(guest.keys) {
            guard var state = guest[botID] else { continue }
            let hadRuntime = state["runtime"] != nil
            if hadRuntime {
                invalidateGuestGrant(state: &state, status: "reconnect_required")
                state["recovery"] = [
                    "method": "bot.guest.state",
                    "requires_new_start_grant": true,
                ]
            }
            state["security"] = Self.guestSecurity
            guest[botID] = state
        }
        persistSidecar()
    }

    private static func guestValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case let (left as String, right as String): return left == right
        case let (left as Int, right as Int): return left == right
        case let (left as NSNumber, right as NSNumber): return left == right
        default: return false
        }
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
        let dockerGeneration = fileGeneration(botID: botID, root: "docker_home") + 1
        fileGenerations[fileGenerationKey(botID: botID, root: "docker_home")] = dockerGeneration
        let dockerCAS = rotateFileCAS(botID: botID, root: "docker_home")
        if var guestState = guest[botID] {
            invalidateGuestGrant(state: &guestState, status: "stopped")
            guestState["security"] = Self.guestSecurity
            guest[botID] = guestState
        }
        return receipt(
            requestID: requestID,
            status: partial ? .partial : .completed,
            botID: botID,
            readback: [
                "bot_id": botID,
                "cleared": true,
                "removed_count": max(removed.count, removedPaths.count),
                "partial": partial,
                "generation": dockerGeneration,
                "root_cas": dockerCAS,
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
        let provider = string(params, "provider") ?? "grok"
        let providerInstanceID = string(params, "provider_instance_id") ?? provider
        let routingReceiptID = UUID().uuidString.lowercased()
        let runAsUser = params["run_as_user"] ?? Self.runAsUserObject(AgentRunAsUser.current())
        var pref: [String: Any] = [
            "provider": string(params, "provider") ?? "grok",
            "provider_instance_id": providerInstanceID,
            "model": string(params, "model") ?? "",
            "routing_mode": string(params, "routing_mode") ?? "auto",
            "permission_mode": string(params, "permission_mode") ?? "supervised",
            "reasoning_effort": string(params, "reasoning_effort") ?? "medium",
            "service_tier": string(params, "service_tier") ?? "auto",
            "run_as_user": runAsUser,
            "routing_receipt_id": routingReceiptID,
            "host_id": string(params, "host_id") ?? "",
            "bot_id": id(bot),
        ]
        pref["effective"] = pref
        routingPref[id(bot)] = pref
        return receipt(
            requestID: requestID,
            status: .completed,
            botID: id(bot),
            readback: pref,
            receiptID: routingReceiptID
        )
    }

    private func attentionAck(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let profileID = string(params, "profile_id") ?? ""
        let hostID = string(params, "host_id") ?? ""
        let itemID = string(params, "attention_item_id")
            ?? string(params, "notification_id")
            ?? string(params, "item_id")
            ?? ""
        guard !profileID.isEmpty, !hostID.isEmpty, !itemID.isEmpty,
              attentionBindings.contains(profileID: profileID, hostID: hostID),
              let stored = attention[botID] else { throw Error.crossTarget }
        let item = canonicalAttentionItem(stored)
        guard item["id"] as? String == itemID,
              item["bot_id"] as? String == botID,
              item["profile_id"] as? String == profileID,
              item["host_id"] as? String == hostID,
              item["state"] as? String != "none" else { throw Error.crossTarget }
        var cleared = item
        cleared["state"] = "none"
        attention[botID] = cleared
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: [
            "state": "none",
            "profile_id": profileID,
            "host_id": hostID,
            "attention_item_id": itemID,
            "notification_id": itemID,
            "bot_id": botID,
            "source": item["source"] as? String ?? "bot",
        ])
    }

    private func canonicalAttentionItem(_ raw: [String: Any], hostID: String? = nil) -> [String: Any] {
        var item = raw
        guard let itemID = item["id"] as? String, !itemID.isEmpty else { return item }
        item["attention_item_id"] = itemID
        item["notification_id"] = itemID
        if item["profile_id"] as? String != nil,
           item["host_id"] as? String != nil {
            return item
        }
        let requestedHost = hostID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedHost = item["host_id"] as? String
        let selectedHost = storedHost?.isEmpty == false ? storedHost : requestedHost
        if let selectedHost, !selectedHost.isEmpty {
            item["host_id"] = selectedHost
            if let binding = attentionBindings.unique(hostID: selectedHost) {
                item["profile_id"] = binding.profileID
            }
        }
        return item
    }

    private func persistAttentionNotification(
        _ item: [String: Any],
        now: Date
    ) throws -> [String: Any]? {
        let state = item["state"] as? String ?? ""
        guard state == "finished" || state == "needs" || state == "needs_attention",
              let notificationID = item["notification_id"] as? String,
              let attentionItemID = item["attention_item_id"] as? String,
              let profileID = item["profile_id"] as? String,
              let hostID = item["host_id"] as? String,
              let botID = item["bot_id"] as? String,
              let source = item["source"] as? String,
              !notificationID.isEmpty, !attentionItemID.isEmpty,
              !profileID.isEmpty, !hostID.isEmpty, !botID.isEmpty else {
            return nil
        }
        let title = item["title"] as? String ?? "Bot needs attention"
        let body = item["detail"] as? String
        let category = "RemoteCodeThreadUpdate"
        let metadata = BotAttentionNotificationMetadata(
            notificationID: notificationID,
            profileID: profileID,
            hostID: hostID,
            attentionItemID: attentionItemID,
            botID: botID,
            source: source
        )
        let inserted = try db.transaction {
            let inserted = try NotificationRepository(db: db).insertIfAbsent(AppNotification(
                id: notificationID,
                title: title,
                body: body,
                category: category,
                createdAt: now
            ))
            if inserted { try attentionNotificationMetadata.record(metadata) }
            return inserted
        }
        guard inserted else { return nil }
        return [
            "id": notificationID,
            "title": title,
            "body": body as Any,
            "category": category,
            "profile_id": profileID,
            "host_id": hostID,
            "attention_item_id": attentionItemID,
            "notification_id": notificationID,
            "bot_id": botID,
            "source": source,
        ]
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
        if let routing = routingPref[id(bot)] {
            body["routing"] = routing
        }
        for (key, value) in extra { body[key] = value }
        return body
    }

    private func encodeRoutine(_ routine: BotRoutine) -> [String: Any] {
        var result: [String: Any] = [
            "id": routine.definition.id.value.uuidString.lowercased(),
            "bot_id": routine.definition.botID.value.uuidString.lowercased(),
            "name": routine.definition.name,
            "prompt": routine.definition.prompt,
            "schedule_note": routine.definition.scheduleNote,
            "schedule_spec_json": routine.definition.scheduleSpecJSON,
            "enabled": routine.activation.isEnabled,
        ]
        if let runtime = routineRuntime[routine.definition.id.value.uuidString.lowercased()] {
            result.merge(runtime) { _, runtimeValue in runtimeValue }
        }
        return result
    }

    private func nextRunDate(
        definition: BotRoutineDefinition,
        enabled: Bool,
        after date: Date
    ) -> Date? {
        guard enabled,
              let spec = definition.scheduleSpec,
              let recurrence = try? spec.makeRecurrence(),
              let timeZone = TimeZone(identifier: spec.timeZoneIdentifier) else {
            return nil
        }
        return ScheduledTaskOccurrenceCalculator.nextOccurrence(
            after: date,
            recurrence: recurrence,
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        )
    }

    private func dateValue(_ date: Date?) -> Any {
        if let date { return date.timeIntervalSince1970 }
        return NSNull()
    }

    private func receipt(
        requestID: String,
        status: Status,
        botID: String?,
        readback: [String: Any],
        receiptID: String = UUID().uuidString.lowercased()
    ) -> [String: Any] {
        [
            "request_id": requestID,
            "receipt_id": receiptID,
            "status": status.rawValue,
            "bot_id": botID as Any,
            "readback": readback,
        ]
    }

    private func runtimeReceipt(
        requestID: String,
        hostID: String,
        botID: String,
        conversationID: String?,
        runID: String,
        readback: [String: Any]
    ) -> [String: Any] {
        var exactReadback = readback
        exactReadback["host_id"] = hostID
        exactReadback["bot_id"] = botID
        exactReadback["request_id"] = requestID
        exactReadback["client_request_id"] = requestID
        exactReadback["conversation_id"] = conversationID ?? NSNull()
        exactReadback["run_id"] = runID
        var exactReceipt = receipt(
            requestID: requestID,
            status: .completed,
            botID: botID,
            readback: exactReadback
        )
        exactReceipt["host_id"] = hostID
        exactReceipt["client_request_id"] = requestID
        return exactReceipt
    }

    private func effectiveRouting(
        botID: String,
        params: [String: Any]
    ) throws -> [String: Any] {
        let requestedReceipt = string(params, "routing_receipt_id")
        var routing = routingPref[botID] ?? [
            "provider": "grok",
            "provider_instance_id": "grok",
            "model": "",
            "routing_mode": "auto",
            "permission_mode": "supervised",
            "reasoning_effort": "medium",
            "service_tier": "auto",
            "run_as_user": Self.runAsUserObject(AgentRunAsUser.current()),
            "host_id": string(params, "host_id") ?? "",
            "bot_id": botID,
        ]
        guard let requestedReceipt else { return routing }
        guard !requestedReceipt.isEmpty,
              !consumedRoutingReceipts.contains(requestedReceipt),
              routing["routing_receipt_id"] as? String == requestedReceipt,
              routing["host_id"] as? String == string(params, "host_id"),
              params["run_as_user"] != nil else {
            throw Error.crossTarget
        }
        for key in [
            "provider", "provider_instance_id", "model", "routing_mode",
            "permission_mode", "reasoning_effort", "service_tier",
        ] {
            guard let requested = params[key] as? String,
                  requested == routing[key] as? String else {
                throw Error.crossTarget
            }
        }
        if let requestedRunAs = params["run_as_user"],
           !Self.jsonObjectsEqual(requestedRunAs, routing["run_as_user"]) {
            throw Error.crossTarget
        }
        routing["routing_receipt_id"] = requestedReceipt
        return routing
    }

    private static func jsonObjectsEqual(_ lhs: Any, _ rhs: Any?) -> Bool {
        guard let rhs,
              JSONSerialization.isValidJSONObject(["value": lhs]),
              JSONSerialization.isValidJSONObject(["value": rhs]),
              let left = try? JSONSerialization.data(
                withJSONObject: ["value": lhs],
                options: [.sortedKeys]
              ),
              let right = try? JSONSerialization.data(
                withJSONObject: ["value": rhs],
                options: [.sortedKeys]
              ) else {
            return false
        }
        return left == right
    }

    private static func runAsUserObject(_ user: AgentRunAsUser) -> Any {
        guard let data = try? JSONEncoder().encode(user),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return [String: Any]()
        }
        return object
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

    private func int(_ params: [String: Any], _ key: String) -> Int? {
        if let value = params[key] as? Int { return value }
        if let number = params[key] as? NSNumber { return number.intValue }
        if let text = params[key] as? String { return Int(text) }
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
        guard let entry = files[handle] else { throw Error.invalidParams }
        guard entry["bot_id"] as? String == id(bot) else { throw Error.crossTarget }
        return entry
    }

    private func diskFileExists(bot: BotDefinition, root: String, path: String) throws -> Bool {
        if root == "docker_home" {
            let url = try secureContainedURL(root: BotGuestHome.url(appSupport: appSupport, botID: bot.id), path: path)
            return FileManager.default.fileExists(atPath: url.path)
        }
        return FileManager.default.fileExists(atPath: try secureContainedURL(root: botHome(bot).root, path: path).path)
    }

    private func fileGenerationKey(botID: String, root: String) -> String {
        "\(botID)|\(root)"
    }

    private func fileGeneration(botID: String, root: String) -> Int {
        fileGenerations[fileGenerationKey(botID: botID, root: root)] ?? 1
    }

    private func fileCASValue(botID: String, root: String) -> String {
        let key = fileGenerationKey(botID: botID, root: root)
        if let value = fileCAS[key], !value.isEmpty { return value }
        let value = UUID().uuidString.lowercased()
        fileCAS[key] = value
        return value
    }

    @discardableResult
    private func rotateFileCAS(botID: String, root: String) -> String {
        let value = UUID().uuidString.lowercased()
        fileCAS[fileGenerationKey(botID: botID, root: root)] = value
        return value
    }

    private func fileSecurity() -> [String: Any] {
        [
            "opaque_handle": true,
            "bot_bound": true,
            "root_bound": true,
            "generation_bound": true,
            "cas_bound": true,
            "symlink_safe": true,
        ]
    }

    private func requireFileHost(params: [String: Any], botID: String) throws -> String {
        let requested = string(params, "host_id")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let admitted = fileHosts[botID] ?? ""
        guard admitted.isEmpty || requested.isEmpty || admitted == requested else { throw Error.crossTarget }
        if admitted.isEmpty, !requested.isEmpty { fileHosts[botID] = requested }
        return admitted.isEmpty ? requested : admitted
    }

    private func mintFileGrant(hostID: String, botID: String, root: String, path: String, kind: String) -> [String: Any] {
        let currentGeneration = fileGeneration(botID: botID, root: root)
        let currentCAS = fileCASValue(botID: botID, root: root)
        if let existing = files.values.first(where: {
            $0["bot_id"] as? String == botID
                && $0["host_id"] as? String == hostID
                && $0["root"] as? String == root
                && $0["path"] as? String == path
                && $0["kind"] as? String == kind
                && $0["generation"] as? Int == currentGeneration
                && $0["cas"] as? String == currentCAS
        }) {
            return existing
        }
        let handle = UUID().uuidString.lowercased()
        let entry: [String: Any] = [
            "handle": handle,
            "host_id": hostID,
            "bot_id": botID,
            "root": root,
            "path": path,
            "kind": kind,
            "generation": currentGeneration,
            "cas": currentCAS,
            "security": fileSecurity(),
        ]
        files[handle] = entry
        return entry
    }

    private func fileConflictReceipt(
        requestID: String,
        hostID: String,
        botID: String,
        root: String,
        expectedGeneration: Int,
        expectedCAS: String
    ) -> [String: Any] {
        let current = fileGeneration(botID: botID, root: root)
        let currentCAS = fileCASValue(botID: botID, root: root)
        return receipt(requestID: requestID, status: .failed, botID: botID, readback: [
            "bot_id": botID,
            "host_id": hostID,
            "conflict": true,
            "root": root,
            "root_handle": mintFileGrant(
                hostID: hostID,
                botID: botID,
                root: root,
                path: "",
                kind: "root"
            )["handle"] as Any,
            "generation": current,
            "root_cas": currentCAS,
            "expected_generation": expectedGeneration,
            "expected_cas": expectedCAS,
            "current_generation": current,
            "current_cas": currentCAS,
            "recovery": [
                "method": "bot.files.list",
                "bot_id": botID,
                "root": root,
                "current_generation": current,
                "current_cas": currentCAS,
            ],
        ])
    }

    private func applyDiskMutation(
        bot: BotDefinition,
        root: String,
        path: String,
        op: String,
        contents: String
    ) throws {
        let rootURL: URL
        if root == "docker_home" {
            rootURL = try BotGuestHome.ensure(appSupport: appSupport, botID: bot.id)
        } else {
            let home = botHome(bot)
            try home.ensure(
                name: bot.name,
                handle: bot.handle,
                title: bot.title,
                description: bot.description,
                soul: ""
            )
            rootURL = home.root
        }
        let url = try secureContainedURL(root: rootURL, path: path)
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
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var paths: [String] = []
        let rootPath = resolvedRoot.path
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator?.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return paths.sorted()
    }

    private func secureContainedURL(root: URL, path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("..") else {
            throw Error(code: -32086, message: "Path escapes Bot home containment.")
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let url = resolvedRoot.appendingPathComponent(trimmed).standardizedFileURL
        let resolvedCandidate = FileManager.default.fileExists(atPath: url.path)
            ? url.resolvingSymlinksInPath()
            : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        let rootPath = resolvedRoot.path
        guard resolvedCandidate.path == rootPath || resolvedCandidate.path.hasPrefix(rootPath + "/") else {
            throw Error(code: -32086, message: "Path escapes Bot home containment.")
        }
        return resolvedCandidate
    }

    private func browserSurfaceID(_ bot: BotDefinition) -> String {
        BotBrowserIdentity.dataStoreIdentifier(for: bot.id).uuidString.lowercased()
    }

    private func authoritativeBrowserState(bot: BotDefinition, hostID: String?) throws -> [String: Any] {
        let botID = id(bot)
        let stored = browser[botID] ?? [:]
        let storedSession = stored["session"] as? [String: Any] ?? [:]
        let admittedHostID = stored["host_id"] as? String ?? ""
        let requestedHostID = hostID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard admittedHostID.isEmpty || requestedHostID.isEmpty || admittedHostID == requestedHostID else {
            throw Error.crossTarget
        }
        let target = try browserStore.loadTarget(botID: bot.id)
        let page = try browserStore.loadPageState(botID: bot.id)
        let url = page?.url.isEmpty == false ? page?.url ?? "" : target?.url ?? stored["url"] as? String ?? ""
        let title = page?.title.isEmpty == false ? page?.title ?? "" : target?.title ?? stored["title"] as? String ?? ""
        let openedURL = target?.url ?? url
        let authenticated = page.map {
            BotBrowserLoginPredicate.standard.isLoggedIn($0, openedURL: openedURL)
        } ?? false
        let sessionID = stored["session_id"] as? String
            ?? storedSession["id"] as? String
            ?? UUID().uuidString.lowercased()
        let digest = stored["session_digest"] as? String
            ?? storedSession["digest"] as? String
            ?? UUID().uuidString.lowercased()
        let loginState = authenticated
            ? "authenticated"
            : (stored["login_state"] as? String ?? (url.isEmpty ? "empty" : "anonymous"))
        let currentGeneration = stored["generation"] as? Int ?? (url.isEmpty ? 0 : 1)
        var result: [String: Any] = [
            "host_id": admittedHostID.isEmpty ? requestedHostID : admittedHostID,
            "bot_id": botID,
            "surface_id": browserSurfaceID(bot),
            "url": url,
            "title": title,
            "generation": currentGeneration,
            "snapshot_generation": currentGeneration,
            "host_first": true,
            "security": [
                "bot_bound": true,
                "host_owned_website_data": true,
                "cookie_exported": false,
            ],
            "session": [
                "id": sessionID,
                "digest": digest,
                "state": loginState,
                "authenticated": authenticated,
                "cookie_exported": false,
            ],
        ]
        if let loading = page?.loading ?? stored["loading"] as? Bool {
            result["loading"] = loading
        }
        return result
    }

    private func browserConflictReceipt(
        requestID: String,
        botID: String,
        current: [String: Any],
        expected: Int
    ) -> [String: Any] {
        receipt(requestID: requestID, status: .failed, botID: botID, readback: [
            "bot_id": botID,
            "conflict": true,
            "expected_generation": expected,
            "current_generation": current["generation"] as? Int ?? 0,
            "surface_id": current["surface_id"] as Any,
            "recovery": ["method": "bot.browser.state", "bot_id": botID],
        ])
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
        if let data = loadData("bot.remote.file_grants"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            files = decoded
        }
        if let data = loadData("bot.remote.file_generations"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            fileGenerations = decoded
        }
        if let data = loadData("bot.remote.file_cas"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            fileCAS = decoded
        }
        if let data = loadData("bot.remote.file_hosts"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            fileHosts = decoded
        }
        if let data = loadData("bot.remote.browser_state"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            browser = decoded
        }
        if let data = loadData("bot.remote.guest_state"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            guest = decoded
        }
        if let data = loadData("bot.remote.routing"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            routingPref = decoded
        }
        if let data = loadData("bot.remote.routing_consumed"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] {
            consumedRoutingReceipts = Set(decoded)
        }
        if let data = loadData("bot.remote.selected_conversations"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            selectedConversation = decoded
        }
        if let data = loadData("bot.remote.attention"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            attention = decoded
        }
        if let data = loadData("bot.remote.scheduler_runs"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            schedulerRuns = decoded
        }
        if let data = loadData("bot.remote.routine_runtime"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            routineRuntime = decoded
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
        saveJSON("bot.remote.receipts", persistentReceiptSnapshot())
        saveJSON("bot.remote.files_location", filesLocation)
        saveJSON("bot.remote.file_grants", files)
        saveJSON("bot.remote.file_generations", fileGenerations)
        saveJSON("bot.remote.file_cas", fileCAS)
        saveJSON("bot.remote.file_hosts", fileHosts)
        saveJSON("bot.remote.browser_state", browser)
        saveJSON("bot.remote.guest_state", guest.mapValues { state in
            var projected = state
            projected["frame"] = nil
            projected["input"] = nil
            return projected
        })
        saveJSON("bot.remote.routing", routingPref)
        saveJSON("bot.remote.routing_consumed", Array(consumedRoutingReceipts).sorted())
        saveJSON("bot.remote.selected_conversations", selectedConversation)
        saveJSON("bot.remote.attention", attention)
        saveJSON("bot.remote.scheduler_runs", schedulerRuns)
        saveJSON("bot.remote.routine_runtime", routineRuntime)
    }

    /// Frame bytes stay available to the live receipt/state read path, but are
    /// never accumulated in SQLite. A receipt replay after process loss keeps
    /// its at-most-once identity while requiring a fresh host-issued grant.
    private func persistentReceiptSnapshot() -> [String: [String: Any]] {
        receipts.mapValues { receipt in
            guard var readback = receipt["readback"] as? [String: Any],
                  readback["task_catalog"] != nil,
                  readback["viewer_path"] as? String == "/vnc.html" else { return receipt }
            var projectedReceipt = receipt
            readback["frame"] = nil
            readback["input"] = nil
            if let runtime = readback["runtime"] as? [String: Any] {
                let generation = runtime["grant_generation"] as? Int
                    ?? readback["grant_generation"] as? Int
                    ?? 0
                readback["runtime"] = nil
                readback["status"] = "reconnect_required"
                readback["grant_generation"] = generation + 1
                readback["grant_invalidated"] = true
                readback["recovery"] = [
                    "method": "bot.guest.state",
                    "requires_new_start_grant": true,
                ]
                if receipt["status"] as? String == Status.accepted.rawValue {
                    projectedReceipt["status"] = Status.unknown.rawValue
                }
            }
            readback["security"] = Self.guestSecurity
            projectedReceipt["readback"] = readback
            return projectedReceipt
        }
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
#if DEBUG
        let timestamp = useLegacySidecarDateFormatterForBenchmark
            ? ISO8601DateFormatter().string(from: Date())
            : iso.string(from: Date())
#else
        let timestamp = iso.string(from: Date())
#endif
        try? db.performSync { database in
            let statement = try database.prepare(
                "INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
            )
            defer { statement.reset() }
            try statement.bind(1, key)
            try statement.bind(2, text)
            try statement.bind(3, timestamp)
            _ = try statement.step()
        }
    }
}
