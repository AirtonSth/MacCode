import CryptoKit
import Foundation
import Persistence
import CoreModel

public enum HostMutationContract {
    public static let transportParamKeys: Set<String> = [
        "client_request_id", "connection_id", "expected_host_id", "expected_boot_epoch",
        BotPeerDelegation.capabilityRPCParameterKey,
    ]

    public static let methods: Set<String> = Set("""
    workspace.create
    workspace.rename
    workspace.close
    workspace.select
    workspace.reorder
    workspace.set_color
    workspace.set_description
    workspace.set_pinned
    workspace.move_to_window
    window.create
    window.close
    window.focus
    pane.resize
    pane.swap
    surface.create
    surface.close
    surface.focus
    surface.move
    surface.rename
    surface.reorder
    surface.set_color
    surface.split
    surface.clear_history
    surface.send_key
    surface.send_text
    agent.open
    agent.thread.create
    agent.thread.delete
    agent.thread.delete_many
    agent.thread.rename
    agent.thread.set_pinned
    agent.thread.set_color
    agent.thread.reorder
    agent.thread.configure
    agent.thread.execution.configure
    agent.thread.mark_read
    agent.thread.prepare_pr
    agent.thread.rollback
    agent.thread.select
    agent.message.send
    agent.message.queue.cancel
    agent.message.queue.force_now
    agent.message.queue.reorder
    agent.message.queue.update
    agent.run.continue
    agent.run.stop
    agent.request.respond
    agent.user_input.respond
    agent.plan.implement
    agent.plan.save
    agent.plan.notes.save
    agent.checkpoint.revert
    agent.attachment.upload
    agent.attachment.import
    agent.provider.update
    fs.workspace.create_file
    fs.workspace.delete
    fs.workspace.rename
    files.edit.apply_patch
    files.edit.open
    files.edit.save
    files.edit.discard
    files.edit.close
    files.state.update
    files.tab.open
    files.tab.split
    git.checkout
    git.commit
    git.create_branch
    git.deliver
    git.push
    browser.navigate
    browser.back
    browser.forward
    browser.reload
    browser.click
    browser.fill
    browser.type
    browser.focus
    browser.hover
    browser.check
    browser.uncheck
    browser.select
    browser.eval
    browser.mirror_url.get
    browser.screenshot
    ssh.connect
    ssh.disconnect
    ssh.host.upsert
    ssh.host.delete
    ssh.transfer.upload
    ssh.transfer.download
    notification.create
    notification.dismiss
    notification.mark_read
    settings.set
    project.open_in_editor
    project.run_script
    private.push_token.update
    bot.create
    bot.discard_new
    bot.save
    bot.delete
    bot.set_pinned
    bot.set_hidden
    bot.duplicate
    bot.settings.set
    bot.send
    bot.queue.remove
    bot.stop
    bot.force_stop
    bot.conversation.create
    bot.conversation.select
    bot.conversation.clear_all
    bot.routine.create
    bot.routine.update
    bot.routine.enable
    bot.routine.run
    bot.routine.delete
    bot.attachment.stage
    bot.attachment.remove
    bot.files.mutate
    bot.files.open_tab
    bot.files.split
    bot.files.location.set
    bot.browser.action
    bot.link.open
    bot.guest.input
    bot.guest.start
    bot.guest.stop
    bot.guest.rebuild
    bot.guest.revoke
    bot.docker.clear
    bot.notify.set
    bot.desktop.set
    bot.avatar.set
    bot.handle.set
    bot.soul.set
    bot.routing.set
    bot.attention.ack
    bot.self_config
    bot.scheduler.tick
    """.split(separator: "\n").map(String.init))

    struct PreflightProbe {
        let label: String
        let params: [String: JSONValue]
    }

    private enum SyntaxRule {
        case uuid(String)
        case optionalUUID(String)
        case anyUUID([String])
        case string(String, nonempty: Bool = false)
        case anyString([String], nonempty: Bool = false)
        case int(String)
        case firstPresentInt([String])
        case bool(String)
        case object(String)
        case nestedInt(object: String, key: String)
        case stringEnum(String, Set<String>)
        case surfaceType(String)
        case uuidArrayWithAtLeastOne(String)
        case surfaceSplitTarget
        case requiredSSHProfile
        case optionalSSHProfile
        case pushTokenContract
    }

    /// Private managed-provider mutations reuse the same syntactic and durable
    /// receipt machinery, but they are not part of the public HTTP Phase 4
    /// catalog. Only the authenticated Unix entry point may route them here.
    static let managedProviderMutationMethods =
        RemoteCodeHostCatalog.rpcMutationMethods.union([
            "bot.peer.ask", "bot.peer.self_config",
        ])

    public static func preflight(method: String, params: [String: JSONValue]) throws {
        guard methods.contains(method) || managedProviderMutationMethods.contains(method) else {
            throw JSONRPCError.invalidParams
        }
        for rule in syntaxRules(for: method) {
            try validate(rule, params: params)
        }
    }

    static func invalidPreflightProbes(method: String) -> [PreflightProbe] {
        let rules = syntaxRules(for: method)
        var valid: [String: JSONValue] = [:]
        for rule in rules { applyValid(rule, to: &valid) }
        return rules.flatMap { invalidVariants(for: $0, valid: valid) }
    }

    static func validPreflightProbe(method: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        for rule in syntaxRules(for: method) { applyValid(rule, to: &params) }
        return params
    }

    private static func validate(_ rule: SyntaxRule, params: [String: JSONValue]) throws {
        switch rule {
        case .uuid(let key):
            guard params[key]?.stringValue.flatMap(UUID.init) != nil else { throw JSONRPCError.invalidParams }
        case .optionalUUID(let key):
            guard params[key] == nil || params[key]?.stringValue.flatMap(UUID.init) != nil else {
                throw JSONRPCError.invalidParams
            }
        case .anyUUID(let keys):
            guard keys.contains(where: { params[$0]?.stringValue.flatMap(UUID.init) != nil }) else {
                throw JSONRPCError.invalidParams
            }
        case .string(let key, let nonempty):
            guard let value = params[key]?.stringValue, !nonempty || !value.isEmpty else {
                throw JSONRPCError.invalidParams
            }
        case .anyString(let keys, let nonempty):
            guard let value = keys.lazy.compactMap({ params[$0]?.stringValue }).first,
                  !nonempty || !value.isEmpty else { throw JSONRPCError.invalidParams }
        case .int(let key):
            guard params[key]?.intValue != nil else { throw JSONRPCError.invalidParams }
        case .firstPresentInt(let keys):
            guard let key = keys.first(where: { params[$0] != nil }),
                  params[key]?.intValue != nil else { throw JSONRPCError.invalidParams }
        case .bool(let key):
            guard params[key]?.boolValue != nil else { throw JSONRPCError.invalidParams }
        case .object(let key):
            guard params[key]?.objectValue != nil else { throw JSONRPCError.invalidParams }
        case .nestedInt(let object, let key):
            guard params[object]?.objectValue?[key]?.intValue != nil else { throw JSONRPCError.invalidParams }
        case .stringEnum(let key, let values):
            guard params[key]?.stringValue.map(values.contains) == true else { throw JSONRPCError.invalidParams }
        case .surfaceType(let key):
            guard params[key]?.stringValue.map(isSurfaceType) == true else { throw JSONRPCError.invalidParams }
        case .uuidArrayWithAtLeastOne(let key):
            guard let values = params[key]?.arrayValue,
                  values.contains(where: { $0.stringValue.flatMap(UUID.init) != nil }) else {
                throw JSONRPCError.invalidParams
            }
        case .surfaceSplitTarget:
            let id = params["id"]?.stringValue.flatMap(UUID.init)
            let type = params["type"]?.stringValue.map(isSurfaceType) == true
            guard id != nil || type else { throw JSONRPCError.invalidParams }
        case .requiredSSHProfile:
            try validateSSHProfile(params)
        case .optionalSSHProfile:
            if params["destination"]?.stringValue != nil || params["host"]?.stringValue != nil || params["profile"]?.objectValue != nil {
                try validateSSHProfile(params)
            }
        case .pushTokenContract:
            try validatePushToken(params)
        }
    }

    private static func validateSSHProfile(_ params: [String: JSONValue]) throws {
        let source = params["profile"]?.objectValue ?? params
        guard source["destination"]?.stringValue != nil || source["host"]?.stringValue != nil else {
            throw JSONRPCError.invalidParams
        }
    }

    private static func validatePushToken(_ params: [String: JSONValue]) throws {
        guard let pushToken = params["push_token"]?.stringValue, !pushToken.isEmpty,
              ["apns", "fcm"].contains(params["push_token_type"]?.stringValue ?? "") else {
            throw JSONRPCError.invalidParams
        }
        let tokenPurpose = params["token_purpose"]?.stringValue
        let environment = params["environment"]?.stringValue
        let serverID = params["server_id"]?.stringValue
        let bootEpoch = params["boot_epoch"]?.intValue
        let activityGeneration = params["activity_generation"]?.intValue
        let activityID = params["activity_id"]?.stringValue
        let activitySessionID = params["activity_session_id"]?.stringValue
        let registrationRevision = params["registration_revision"]?.intValue
        let contractVersion = params["contract_version"]?.intValue
        let capabilityValues = params["capabilities"]?.arrayValue
        let capabilities = capabilityValues?.compactMap(\.stringValue)
        let typed = tokenPurpose != nil || environment != nil || serverID != nil ||
            params["boot_epoch"] != nil || params["activity_generation"] != nil ||
            params["activity_id"] != nil || params["activity_session_id"] != nil ||
            params["registration_revision"] != nil || contractVersion != nil || params["capabilities"] != nil
        guard typed else { return }
        guard params["activity_generation"] == nil || activityGeneration != nil,
              params["boot_epoch"] == nil || bootEpoch != nil,
              params["activity_session_id"] == nil || activitySessionID != nil,
              params["registration_revision"] == nil || registrationRevision != nil,
              params["activity_id"] == nil || activityID != nil,
              params["contract_version"] == nil || contractVersion != nil,
              params["capabilities"] == nil || (capabilityValues != nil && capabilityValues?.count == capabilities?.count),
              ["alert", "push_to_start", "activity_update"].contains(tokenPurpose ?? ""),
              ["sandbox", "production"].contains(environment ?? ""),
              let deviceID = params["device_id"]?.stringValue, !deviceID.isEmpty,
              let serverID, !serverID.isEmpty,
              bootEpoch.map({ $0 >= 0 }) ?? true,
              activityGeneration.map({ $0 >= 0 }) ?? true,
              registrationRevision.map({ $0 >= 0 }) ?? true,
              contractVersion.map({ $0 >= 1 }) ?? true else { throw JSONRPCError.invalidParams }
        if tokenPurpose != "alert" {
            guard let token = params["live_activity_token"]?.stringValue, !token.isEmpty else {
                throw JSONRPCError.invalidParams
            }
        }
        if capabilities?.contains("live_activity_v2") == true, (contractVersion ?? 1) < 2 {
            throw JSONRPCError.invalidParams
        }
    }

    private static func syntaxRules(for method: String) -> [SyntaxRule] {
        if method.hasPrefix("bot.") {
            switch method {
            case "bot.create", "bot.scheduler.tick", "bot.self_config":
                return []
            case "bot.settings.set":
                return [.string("key")]
            case "bot.peer.ask":
                return [
                    .uuid("thread_id"), .uuid("run_id"), .string("handle"), .string("prompt"),
                    .stringEnum("reply_mode", ["consult", "reply_only"]),
                    .optionalUUID(BotPeerDelegation.consultationIDParameterKey),
                ]
            case "bot.peer.self_config":
                return [
                    .uuid("thread_id"), .uuid("run_id"), .string("tool_name"), .object("arguments"),
                ]
            case "bot.attention.ack":
                return [
                    .uuid("bot_id"),
                    .string("profile_id", nonempty: true),
                    .string("host_id", nonempty: true),
                    .anyString(["attention_item_id", "notification_id", "item_id"], nonempty: true),
                ]
            case "bot.guest.start":
                return [
                    .uuid("bot_id"),
                    .string("task_id", nonempty: true), .string("recipe_id", nonempty: true),
                ]
            case "bot.guest.input":
                return [
                    .uuid("bot_id"),
                    .string("task_id", nonempty: true), .object("runtime"),
                    .string("before_frame_id", nonempty: true), .object("input"),
                ]
            case "bot.guest.stop", "bot.guest.rebuild", "bot.guest.revoke":
                return [
                    .uuid("bot_id"),
                    .string("task_id", nonempty: true), .object("runtime"),
                ]
            default:
                return [.uuid("bot_id")]
            }
        }
        switch method {
        case "workspace.create", "host.workspace.create", "window.create", "agent.thread.create", "host.agent.thread.create", "agent.provider.update", "notification.create": return []
        case "workspace.rename": return [.uuid("id"), .string("name")]
        case "workspace.close", "workspace.select", "workspace.reorder", "window.close", "window.focus": return [.uuid("id")]
        case "workspace.set_color": return [.uuid("id"), .string("color")]
        case "workspace.set_description": return [.uuid("id"), .anyString(["description", "text"])]
        case "workspace.set_pinned": return [.uuid("id"), .bool("pinned")]
        case "workspace.move_to_window": return [.uuid("workspace_id"), .uuid("window_id")]
        case "pane.resize": return [.uuid("workspace_id"), .uuid("split_id")]
        case "pane.swap": return [.uuid("workspace_id"), .uuid("a"), .uuid("b")]
        case "surface.create": return [.uuid("workspace_id"), .surfaceType("type")]
        case "surface.close", "surface.focus": return [.uuid("workspace_id"), .uuid("id")]
        case "surface.move", "surface.reorder": return [.uuid("workspace_id"), .uuid("id"), .uuid("target_pane_id")]
        case "surface.rename": return [.uuid("workspace_id"), .uuid("id"), .string("title")]
        case "surface.set_color": return [.uuid("workspace_id"), .uuid("id"), .string("color")]
        case "surface.split": return [.uuid("workspace_id"), .uuid("pane_id"), .stringEnum("direction", directions), .surfaceSplitTarget]
        case "surface.clear_history": return [.uuid("id")]
        case "surface.send_key": return [.uuid("id"), .string("key")]
        case "surface.send_text": return [.uuid("id"), .string("text")]
        case "agent.open": return [.uuid("workspace_id")]
        case "agent.thread.delete", "agent.thread.reorder", "agent.thread.configure", "agent.thread.mark_read", "agent.thread.select", "agent.run.continue", "agent.run.stop": return [.uuid("thread_id")]
        case "agent.thread.delete_many": return [.uuidArrayWithAtLeastOne("thread_ids")]
        case "agent.thread.rename": return [.uuid("thread_id"), .string("title")]
        case "agent.thread.set_pinned": return [.uuid("thread_id"), .bool("pinned")]
        case "agent.thread.set_color": return [.uuid("thread_id"), .string("color")]
        case "agent.thread.execution.configure": return [.uuid("thread_id"), .stringEnum("execution_mode", ["local", "worktree"])]
        case "agent.thread.prepare_pr": return [.uuid("workspace_id"), .string("url")]
        case "agent.thread.rollback": return [.uuid("thread_id"), .string("turn_id")]
        case "agent.message.send": return [.uuid("thread_id"), .string("text")]
        case "agent.message.queue.cancel", "agent.message.queue.force_now": return [.anyUUID(["queued_message_id", "id"])]
        case "agent.message.queue.update": return [.anyUUID(["queued_message_id", "id"]), .string("text")]
        case "agent.message.queue.reorder": return [.uuid("thread_id"), .anyUUID(["queued_message_id", "id"]), .int("position")]
        case "agent.request.respond": return [.uuid("thread_id"), .string("request_id"), .stringEnum("decision", ["approve", "approve_for_session", "approveForSession", "decline", "cancel"])]
        case "agent.user_input.respond": return [.uuid("thread_id"), .string("request_id"), .string("text")]
        case "agent.plan.implement", "agent.plan.save": return [.uuid("thread_id"), .string("plan_id")]
        case "agent.plan.notes.save": return [.uuid("thread_id"), .string("notes")]
        case "agent.checkpoint.revert": return [.uuid("thread_id"), .firstPresentInt(["turn_count", "checkpoint_turn_count"])]
        case "agent.attachment.upload": return [.uuid("workspace_id"), .string("filename"), .anyString(["data_base64", "dataBase64"])]
        case "agent.attachment.import": return [.uuid("workspace_id"), .string("relative_path", nonempty: true)]
        case "host.bot.create": return [.string("name", nonempty: true)]
        case "host.bot.open": return [.uuid("bot_id")]
        case "host.bot.send": return [.uuid("bot_id"), .string("text", nonempty: true)]
        case "host.bot.thread.create": return [.uuid("bot_id")]
        case "host.bot.skill.create": return [.uuid("bot_id"), .string("skill_id", nonempty: true)]
        case "fs.workspace.create_file": return [.uuid("workspace_id"), .string("path")]
        case "fs.workspace.delete": return [.uuid("workspace_id")]
        case "fs.workspace.rename": return [.uuid("workspace_id"), .string("path"), .string("new_name")]
        case "files.edit.apply_patch": return [.string("session_id"), .int("base_draft_revision"), .object("range_utf16"), .nestedInt(object: "range_utf16", key: "location"), .nestedInt(object: "range_utf16", key: "length"), .string("replacement")]
        case "files.edit.open": return [.uuid("surface_id"), .string("path")]
        case "files.edit.save", "files.edit.discard", "files.edit.close": return [.string("session_id")]
        case "files.state.update": return [.uuid("surface_id"), .object("patch")]
        case "files.tab.open": return [.uuid("workspace_id"), .string("path")]
        case "files.tab.split": return [.uuid("workspace_id"), .stringEnum("direction", directions), .string("path")]
        case "git.checkout": return [.uuid("workspace_id"), .string("branch")]
        case "git.commit": return [.uuid("workspace_id"), .string("message")]
        case "git.create_branch": return [.uuid("workspace_id"), .string("name")]
        case "git.deliver", "git.push", "project.open_in_editor": return [.uuid("workspace_id")]
        case "browser.navigate": return [.uuid("id"), .string("url")]
        case "browser.back", "browser.forward", "browser.reload", "browser.mirror_url.get", "browser.screenshot": return [.uuid("id")]
        case "browser.click", "browser.fill", "browser.type", "browser.focus", "browser.hover", "browser.check", "browser.uncheck", "browser.select": return [.uuid("id"), .string("ref")]
        case "browser.eval": return [.uuid("id"), .string("script")]
        case "ssh.connect": return [.uuid("workspace_id"), .optionalSSHProfile]
        case "ssh.disconnect": return [.anyUUID(["surface_id", "id"])]
        case "ssh.host.upsert": return [.anyUUID(["workspace_id", "workspaceId"]), .requiredSSHProfile]
        case "ssh.host.delete": return [.anyUUID(["workspace_id", "workspaceId"]), .uuid("id")]
        case "ssh.transfer.upload", "ssh.transfer.download": return [.anyUUID(["surface_id", "id"]), .string("local_path"), .string("remote_path")]
        case "notification.dismiss", "notification.mark_read": return [.string("id")]
        case "settings.set": return [.string("key"), .string("value")]
        case "project.run_script": return [.uuid("workspace_id"), .string("name")]
        case "private.push_token.update": return [.pushTokenContract]
        default: return []
        }
    }

    private static let directions: Set<String> = ["right", "down", "left", "up"]

    private static func isSurfaceType(_ value: String) -> Bool {
        let normalized: String
        switch value.lowercased() {
        case "agent", "agent_app", "agentapp": normalized = "agentApp"
        case "rightsidebartool", "right_sidebar_tool", "diff", "git": normalized = "rightSidebarTool"
        case "filepreview", "file_preview": normalized = "filePreview"
        case "files", "file_browser", "filebrowser": normalized = "files"
        case "terminal", "ssh", "browser", "markdown": normalized = value.lowercased()
        default: normalized = value
        }
        return ["terminal", "ssh", "browser", "agentApp", "files", "markdown", "filePreview", "rightSidebarTool"].contains(normalized)
    }

    private static let probeUUID = "00000000-0000-0000-0000-000000000001"

    private static func applyValid(_ rule: SyntaxRule, to params: inout [String: JSONValue]) {
        switch rule {
        case .uuid(let key): params[key] = .string(probeUUID)
        case .optionalUUID: break
        case .anyUUID(let keys): params[keys[0]] = .string(probeUUID)
        case .string(let key, _): params[key] = .string("value")
        case .anyString(let keys, _): params[keys[0]] = .string("value")
        case .int(let key): params[key] = .number(1)
        case .firstPresentInt(let keys): params[keys[0]] = .number(1)
        case .bool(let key): params[key] = .bool(true)
        case .object(let key):
            if params[key]?.objectValue == nil { params[key] = .object([:]) }
        case .nestedInt(let object, let key):
            var value = params[object]?.objectValue ?? [:]
            value[key] = .number(1)
            params[object] = .object(value)
        case .stringEnum(let key, let values): params[key] = .string(values.sorted()[0])
        case .surfaceType(let key): params[key] = .string("terminal")
        case .uuidArrayWithAtLeastOne(let key): params[key] = .array([.string(probeUUID)])
        case .surfaceSplitTarget: params["type"] = .string("terminal")
        case .requiredSSHProfile: params["destination"] = .string("host.example")
        case .optionalSSHProfile: break
        case .pushTokenContract:
            params["push_token"] = .string("token")
            params["push_token_type"] = .string("apns")
        }
    }

    private static func invalidVariants(
        for rule: SyntaxRule,
        valid: [String: JSONValue]
    ) -> [PreflightProbe] {
        var probes: [PreflightProbe] = []
        func add(_ label: String, _ mutate: (inout [String: JSONValue]) -> Void) {
            var params = valid
            mutate(&params)
            probes.append(PreflightProbe(label: label, params: params))
        }
        switch rule {
        case .uuid(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).uuid") { $0[key] = .string("not-a-uuid") }
        case .optionalUUID(let key):
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).uuid") { $0[key] = .string("not-a-uuid") }
        case .anyUUID(let keys):
            add("\(keys.joined(separator: "/")).missing") { params in keys.forEach { params.removeValue(forKey: $0) } }
            add("\(keys.joined(separator: "/")).type") { params in keys.forEach { params[$0] = .bool(true) } }
            add("\(keys.joined(separator: "/")).uuid") { params in keys.forEach { params[$0] = .string("not-a-uuid") } }
        case .string(let key, let nonempty):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            if nonempty { add("\(key).empty") { $0[key] = .string("") } }
        case .anyString(let keys, let nonempty):
            add("\(keys.joined(separator: "/")).missing") { params in keys.forEach { params.removeValue(forKey: $0) } }
            add("\(keys.joined(separator: "/")).type") { params in keys.forEach { params[$0] = .bool(true) } }
            if nonempty { add("\(keys.joined(separator: "/")).empty") { params in keys.forEach { params[$0] = .string("") } } }
        case .int(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
        case .firstPresentInt(let keys):
            add("\(keys.joined(separator: "/")).missing") { params in keys.forEach { params.removeValue(forKey: $0) } }
            add("\(keys.joined(separator: "/")).type") { params in
                params[keys[0]] = .bool(true)
                if keys.count > 1 { params[keys[1]] = .number(1) }
            }
        case .bool(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .string("true") }
        case .object(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
        case .nestedInt(let object, let key):
            add("\(object).\(key).missing") { params in
                var value = params[object]?.objectValue ?? [:]
                value.removeValue(forKey: key)
                params[object] = .object(value)
            }
            add("\(object).\(key).type") { params in
                var value = params[object]?.objectValue ?? [:]
                value[key] = .bool(true)
                params[object] = .object(value)
            }
        case .stringEnum(let key, _):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).enum") { $0[key] = .string("invalid-enum") }
        case .surfaceType(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).enum") { $0[key] = .string("invalid-surface") }
        case .uuidArrayWithAtLeastOne(let key):
            add("\(key).missing") { $0.removeValue(forKey: key) }
            add("\(key).type") { $0[key] = .bool(true) }
            add("\(key).empty") { $0[key] = .array([]) }
            add("\(key).uuid") { $0[key] = .array([.string("not-a-uuid")]) }
        case .surfaceSplitTarget:
            add("id/type.missing") { $0.removeValue(forKey: "id"); $0.removeValue(forKey: "type") }
            add("id/type.type") { $0["id"] = .bool(true); $0["type"] = .bool(true) }
            add("id/type.value") { $0["id"] = .string("not-a-uuid"); $0["type"] = .string("invalid-surface") }
        case .requiredSSHProfile:
            add("profile.destination.missing") { $0.removeValue(forKey: "destination"); $0.removeValue(forKey: "host"); $0.removeValue(forKey: "profile") }
            add("profile.destination.type") { $0.removeValue(forKey: "host"); $0.removeValue(forKey: "profile"); $0["destination"] = .bool(true) }
            add("profile.object.destination") { $0.removeValue(forKey: "destination"); $0["profile"] = .object([:]) }
        case .optionalSSHProfile:
            add("profile.object.destination") { $0["profile"] = .object([:]) }
        case .pushTokenContract:
            appendPushTokenProbes(valid: valid, to: &probes)
        }
        return probes
    }

    private static func appendPushTokenProbes(valid: [String: JSONValue], to probes: inout [PreflightProbe]) {
        func append(_ label: String, base: [String: JSONValue], _ mutate: (inout [String: JSONValue]) -> Void) {
            var params = base
            mutate(&params)
            probes.append(PreflightProbe(label: label, params: params))
        }
        append("push_token.missing", base: valid) { $0.removeValue(forKey: "push_token") }
        append("push_token.type", base: valid) { $0["push_token"] = .bool(true) }
        append("push_token.empty", base: valid) { $0["push_token"] = .string("") }
        append("push_token_type.missing", base: valid) { $0.removeValue(forKey: "push_token_type") }
        append("push_token_type.type", base: valid) { $0["push_token_type"] = .bool(true) }
        append("push_token_type.enum", base: valid) { $0["push_token_type"] = .string("invalid") }

        var typed = valid
        typed["token_purpose"] = .string("alert")
        typed["environment"] = .string("sandbox")
        typed["device_id"] = .string("device")
        typed["server_id"] = .string("server")
        for key in ["token_purpose", "environment", "device_id", "server_id"] {
            append("\(key).missing", base: typed) { $0.removeValue(forKey: key) }
            append("\(key).type", base: typed) { $0[key] = .bool(true) }
        }
        append("token_purpose.enum", base: typed) { $0["token_purpose"] = .string("invalid") }
        append("environment.enum", base: typed) { $0["environment"] = .string("invalid") }
        append("device_id.empty", base: typed) { $0["device_id"] = .string("") }
        append("server_id.empty", base: typed) { $0["server_id"] = .string("") }
        for key in ["boot_epoch", "activity_generation", "registration_revision"] {
            append("\(key).type", base: typed) { $0[key] = .bool(true) }
            append("\(key).range", base: typed) { $0[key] = .number(-1) }
        }
        append("contract_version.type", base: typed) { $0["contract_version"] = .bool(true) }
        append("contract_version.range", base: typed) { $0["contract_version"] = .number(0) }
        for key in ["activity_id", "activity_session_id"] {
            append("\(key).type", base: typed) { $0[key] = .bool(true) }
        }
        append("capabilities.type", base: typed) { $0["capabilities"] = .bool(true) }
        append("capabilities.items", base: typed) { $0["capabilities"] = .array([.bool(true)]) }
        var activity = typed
        activity["token_purpose"] = .string("activity_update")
        append("live_activity_token.missing", base: activity) { $0.removeValue(forKey: "live_activity_token") }
        append("live_activity_token.type", base: activity) { $0["live_activity_token"] = .bool(true) }
        append("live_activity_token.empty", base: activity) { $0["live_activity_token"] = .string("") }
        var v2 = typed
        v2["capabilities"] = .array([.string("live_activity_v2")])
        append("live_activity_v2.contract", base: v2) { $0["contract_version"] = .number(1) }
    }

    public static func businessParams(
        _ params: [String: JSONValue]
    ) -> [String: JSONValue] {
        params.filter { !transportParamKeys.contains($0.key) }
    }

    // PERF: every admitted host mutation hashes params. JSONEncoder is not
    // thread-safe — serialize concurrent hashes under a short lock and reuse
    // one encoder (sortedKeys + withoutEscapingSlashes match the prior
    // per-call setup so receipt idempotency digests stay identical).
    private static let paramsHashEncodeLock = NSLock()
    private static let paramsHashEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static func paramsHash(
        method: String,
        _ params: [String: JSONValue]
    ) throws -> String {
        let business = JSONValue.object(businessParams(params))
        let encoded: Data = try {
            paramsHashEncodeLock.lock()
            defer { paramsHashEncodeLock.unlock() }
            return try paramsHashEncoder.encode(business)
        }()
        var input = Data("rc-command-v1\u{0}\(method)\u{0}".utf8)
        input.append(encoded)
        return hexDigest(SHA256.hash(data: input))
    }

    /// PERF: nibble table instead of per-byte `String(format:)` so every host
    /// mutation `params_hash` avoids 32 formatter calls while keeping the same
    /// CryptoKit lowercase hex contract used for receipt idempotency.
    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}

/// Bearer-owned mutation context for remote HTTP/WS command admission.
///
/// HTTP independence: `hostId` / `bootEpoch` are retained for diagnostics and
/// legacy call sites only. They are never mutation preconditions. Connection
/// registry callbacks are not consulted — authorization is bearer ownership +
/// `client_request_id` + method/params validation.
public struct MutationRequestContext: @unchecked Sendable {
    public let ownerFingerprint: String
    public let hostId: String
    public let bootEpoch: UInt64

    public init(
        ownerFingerprint: String,
        hostId: String,
        bootEpoch: UInt64,
        activeConnection: (@Sendable (String, String) -> Bool)? = nil
    ) {
        self.ownerFingerprint = ownerFingerprint
        self.hostId = hostId
        self.bootEpoch = bootEpoch
        _ = activeConnection
    }
}

@MainActor
public protocol CommandReceiptStateRouting: AnyObject {
    func claimCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws -> CommandReceiptClaimResult
    func commitCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue
    ) throws
    func finalizeCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue,
        events: [EventBus.MutationEventIntent],
        minimumEventSequence: Int64
    ) throws -> [EventBus.Event]
    func markCommandReceiptUnknown(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws
    func commandReceiptStatus(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String
    ) throws -> CommandReceiptStatusResult
}
