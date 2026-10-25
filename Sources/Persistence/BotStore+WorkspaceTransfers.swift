import Foundation
import CoreModel

public struct BotWorkspaceTransferResult: Sendable {
    public let bot: BotDefinition
    /// The host must pass these through its canonical revocation handler.
    public let changedBindings: [BotContextBinding]
}

public extension BotStore {
    /// Changes catalog ownership without changing a bot's identity, home epoch,
    /// published profile, conversation pins, destinations or stored history.
    /// Source scope and profile revision are compared inside the write transaction.
    func transferBotWorkspace(botID: BotID, hostID: String, workspaceID: WorkspaceID?,
        expectedWorkspaceID: WorkspaceID?, expectedCurrentRevisionID: BotRevisionID?,
        revokeOtherContexts: Bool = false, registry: BotVMRunRegistry = .shared,
        computerControl: BotComputerControl = .shared, hasLiveRun: (BotID) -> Bool = { _ in false }
    ) throws -> BotWorkspaceTransferResult {
        let reservedResources = try workspaceTransferResourceIDs(botID: botID)
        let result = try computerControl.withWorkspaceMaintenance(resourceIDs: reservedResources, botIDs: [botID]) {
          try registry.withWorkspaceMaintenance(resourceIDs: reservedResources) {
            try db.transaction {
            guard let bot = try get(id: botID), bot.deletedAt == nil else { throw BotStoreError.notFound }
            guard bot.workspaceID == expectedWorkspaceID, bot.currentRevisionID == expectedCurrentRevisionID else {
                throw BotStoreError.revisionConflict
            }
            guard !hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BotStoreError.invalidInput("The current host is unavailable.")
            }
            let bindings = try workspaceTransferBindings(botID: botID)
            guard !bindings.contains(where: { $0.state == .active && $0.hostID != hostID }) else {
                throw BotStoreError.invalidInput("This bot has active access on another host. Revoke it on that host and finish its work before moving the bot.")
            }
            let target = workspaceID.map(BotContext.workspace) ?? .general
            let outside = bindings.filter { $0.state == .active && ($0.hostID != hostID || $0.context != target) }
            guard outside.isEmpty || revokeOtherContexts else {
                throw BotStoreError.invalidInput("\(bot.name) still has access outside this workspace. Choose whether to revoke that access before making it exclusive.")
            }
            let references = try workspaceTransferThreadReferences()
            let ownThreads = references.filter { $0.botID == botID }
            var moved = bot
            moved.workspaceID = workspaceID
            try validateWorkspaceTransferDestinations(bot: moved, threads: ownThreads)
            var resources: Set<BotID> = [botID]
            if let machine = try executionDestination(botID: botID).virtualMachineID { resources.insert(BotID(machine)) }
            for thread in ownThreads {
                if let machine = thread.destination?.virtualMachineID { resources.insert(BotID(machine)) }
            }
            for binding in bindings {
                resources.insert(try BotContextRuntimeIdentity(hostID: binding.hostID, botID: botID,
                    context: binding.context, policyRevision: binding.policyRevision).storageBotID)
            }
            guard resources == reservedResources else { throw BotStoreError.revisionConflict }
                try assertWorkspaceTransferIdle(botIDs: [botID], resources: resources,
                    threads: ownThreads, computerControl: computerControl, hasLiveRun: hasLiveRun)
                var changed: [BotContextBinding] = []
                for binding in outside {
                    changed.append(try revokeContextWithinTransaction(hostID: binding.hostID, botID: botID,
                        context: binding.context, expectedRevision: binding.policyRevision))
                }
                let current = bindings.first { $0.hostID == hostID && $0.context == target }
                // Preserve active grants exactly, including their immutable pins.
                // Ownership is not permission to elevate tools, exports or delegation.
                if let current, current.state == .active {
                    guard current.actions.isSuperset(of: [.read, .send]) else {
                        throw BotStoreError.invalidInput("This bot's destination access does not allow reading and sending. Update its access explicitly before moving it.")
                    }
                } else {
                    changed.append(try grantContextWithinTransaction(hostID: hostID, botID: botID, context: target,
                        actions: [.read, .send], expectedRevision: current?.policyRevision))
                }
                let update = try db.prepare("UPDATE bots SET workspace_id=?, updated_at=? WHERE id=? AND deleted_at IS NULL;")
                defer { update.reset() }
                try update.bind(1, workspaceID?.value.uuidString.lowercased())
                try update.bind(2, ISO8601DateFormatter().string(from: Date()))
                try update.bind(3, botID.value.uuidString.lowercased())
                _ = try update.step()
                guard let saved = try get(id: botID) else { throw BotStoreError.notFound }
                return BotWorkspaceTransferResult(bot: saved, changedBindings: changed)
            }
          }
        }
        bumpBotsListRevision()
        return result
    }

    /// A VM's UUID is its Docker/data namespace. Scope moves alter only catalog
    /// metadata, never recreate a container, migrate storage or rewrite consumers.
    func transferVirtualMachineWorkspace(id: UUID, workspaceID: WorkspaceID?, expectedWorkspaceID: WorkspaceID?, hostID: String? = nil,
        registry: BotVMRunRegistry = .shared, computerControl: BotComputerControl = .shared,
        hasLiveRun: (BotID) -> Bool = { _ in false }
    ) throws -> BotVirtualMachine {
        let reservedResources: Set<BotID> = [BotID(id)]
        return try computerControl.withWorkspaceMaintenance(resourceIDs: reservedResources, botIDs: []) {
          try registry.withWorkspaceMaintenance(resourceIDs: reservedResources) {
            try db.transaction {
            guard let machine = try virtualMachine(id: id) else { throw BotStoreError.notFound }
            guard machine.workspaceID == expectedWorkspaceID else { throw BotStoreError.revisionConflict }
            guard try !listVirtualMachines().contains(where: {
                $0.id != id && $0.workspaceID == workspaceID && $0.name.caseInsensitiveCompare(machine.name) == .orderedSame
            }) else { throw BotStoreError.invalidInput("A VM named \(machine.name) already exists in this workspace.") }
            let bots = try list(includeHidden: true)
            let references = try workspaceTransferThreadReferences()
            if workspaceID != nil, let orphan = references.first(where: { thread in
                thread.destination?.virtualMachineID == id && !bots.contains(where: { bot in bot.id == thread.botID })
            }) {
                throw BotStoreError.invalidInput("Conversation ‘\(orphan.title)’ uses this VM without an available bot. Its saved destination must be resolved before moving the VM.")
            }
            var affected: Set<BotID> = []
            var affectedThreads: [WorkspaceTransferThreadReference] = []
            for bot in bots {
                let selected = try executionDestination(botID: bot.id)
                let usingDefault = selected.virtualMachineID == id
                if usingDefault {
                    affected.insert(bot.id)
                    if let workspaceID, bot.workspaceID != workspaceID {
                        throw BotStoreError.invalidInput("\(bot.name) uses this VM and is not exclusive to the destination workspace. Move the bot first or choose another destination for it.")
                    }
                }
                for thread in references where thread.botID == bot.id {
                    let destination = thread.destination ?? selected
                    guard destination.virtualMachineID == id else { continue }
                    affected.insert(bot.id)
                    affectedThreads.append(thread)
                    if let workspaceID, bot.workspaceID != workspaceID || (thread.workspaceID != nil && thread.workspaceID != workspaceID) {
                        throw BotStoreError.invalidInput("Conversation ‘\(thread.title)’ cannot use this VM in the destination workspace. Its saved destination has not been changed.")
                    }
                }
                for routine in try listRoutines(botID: bot.id) {
                    guard (routine.definition.scheduleSpec?.executionDestination ?? selected).virtualMachineID == id else { continue }
                    affected.insert(bot.id)
                    if let workspaceID, bot.workspaceID != workspaceID {
                        throw BotStoreError.invalidInput("Schedule ‘\(routine.definition.name)’ for \(bot.name) uses this VM outside the destination workspace. Change that schedule first.")
                    }
                }
            }
            for botID in affected {
                guard try !workspaceTransferBindings(botID: botID).contains(where: { $0.state == .active && $0.hostID != hostID }) else {
                    throw BotStoreError.invalidInput("A bot using this VM has active access on another host. Revoke that access and finish its work on that host before moving the VM.")
                }
            }
            let resources: Set<BotID> = [BotID(id)]
                try assertWorkspaceTransferIdle(botIDs: affected, resources: resources, threads: affectedThreads,
                    computerControl: computerControl, hasLiveRun: hasLiveRun)
                let update = try db.prepare("UPDATE virtual_machines SET workspace_id=? WHERE id=?;")
                defer { update.reset() }
                try update.bind(1, workspaceID?.value.uuidString.lowercased())
                try update.bind(2, id.uuidString.lowercased())
                _ = try update.step()
                guard let saved = try virtualMachine(id: id) else { throw BotStoreError.notFound }
                return saved
            }
          }
        }
    }
}

private struct WorkspaceTransferThreadReference {
    let id: AgentThreadID
    let botID: BotID?
    let workspaceID: WorkspaceID?
    let title: String
    let destination: BotExecutionDestination?
}

private extension BotStore {
    func workspaceTransferResourceIDs(botID: BotID) throws -> Set<BotID> {
        var resources: Set<BotID> = [botID]
        if let machine = try executionDestination(botID: botID).virtualMachineID { resources.insert(BotID(machine)) }
        for thread in try workspaceTransferThreadReferences() where thread.botID == botID {
            if let machine = thread.destination?.virtualMachineID { resources.insert(BotID(machine)) }
        }
        for binding in try workspaceTransferBindings(botID: botID) {
            resources.insert(try BotContextRuntimeIdentity(hostID: binding.hostID, botID: botID,
                context: binding.context, policyRevision: binding.policyRevision).storageBotID)
        }
        return resources
    }

    func workspaceTransferBindings(botID: BotID) throws -> [BotContextBinding] {
        let query = try db.prepare("SELECT DISTINCT host_id FROM bot_context_bindings WHERE bot_id=?;")
        defer { query.reset() }
        try query.bind(1, botID.value.uuidString.lowercased())
        var bindings: [BotContextBinding] = []
        while try query.step() {
            guard let host = query.columnText(0) else { throw BotStoreError.invalidRow("bot context host") }
            bindings += try listContextBindings(hostID: host, botID: botID)
        }
        let count = try db.prepare("SELECT COUNT(*) FROM bot_context_bindings WHERE bot_id=?;")
        defer { count.reset() }
        try count.bind(1, botID.value.uuidString.lowercased())
        guard try count.step(), count.columnInt64(0) == Int64(bindings.count) else {
            throw BotStoreError.invalidInput("This bot has an unsupported access policy. Repair it before moving the bot.")
        }
        return bindings
    }

    func workspaceTransferThreadReferences() throws -> [WorkspaceTransferThreadReference] {
        let query = try db.prepare("""
            SELECT t.id,t.workspace_id,t.title,t.execution_destination,t.actor_json,c.bot_id
            FROM agent_threads t LEFT JOIN bot_conversations c ON c.linked_agent_thread_id=t.id COLLATE NOCASE;
            """)
        defer { query.reset() }
        var result: [WorkspaceTransferThreadReference] = []
        while try query.step() {
            guard let raw = query.columnText(0), let uuid = UUID(uuidString: raw), let title = query.columnText(2) else {
                throw BotStoreError.invalidRow("conversation reference")
            }
            let actor = try query.columnText(4).map { try JSONDecoder().decode(RunActor.self, from: Data($0.utf8)) }
            let linkedBot = query.columnText(5).flatMap(UUID.init(uuidString:)).map(BotID.init)
            if let actorBot = actor?.botID, let linkedBot, actorBot != linkedBot {
                throw BotStoreError.invalidInput("Conversation ‘\(title)’ has conflicting bot ownership. Repair it before moving resources.")
            }
            let destination = query.columnText(3).flatMap(BotExecutionDestination.init(storageValue:))
            if query.columnText(3) != nil, destination == nil {
                throw BotStoreError.invalidInput("Conversation ‘\(title)’ uses a destination requiring a newer app version.")
            }
            let workspace = query.columnText(1).flatMap(UUID.init(uuidString:)).map(WorkspaceID.init)
            if query.columnText(1) != nil, workspace == nil { throw BotStoreError.invalidRow("thread workspace") }
            result.append(WorkspaceTransferThreadReference(id: AgentThreadID(uuid), botID: actor?.botID ?? linkedBot,
                workspaceID: workspace, title: title, destination: destination))
        }
        return result
    }

    func validateWorkspaceTransferDestinations(bot: BotDefinition, threads: [WorkspaceTransferThreadReference]) throws {
        func validate(_ destination: BotExecutionDestination, label: String, threadWorkspace: WorkspaceID? = nil) throws {
            guard let id = destination.virtualMachineID else { return }
            guard let machine = try virtualMachine(id: id) else {
                throw BotStoreError.invalidInput("\(label) uses a VM that is no longer available. Choose another destination first.")
            }
            guard machine.allows(bot), machine.workspaceID == nil || threadWorkspace == nil || machine.workspaceID == threadWorkspace else {
                throw BotStoreError.invalidInput("\(label) uses VM ‘\(machine.name)’ outside the destination workspace. Its saved destination has not been changed.")
            }
        }
        let selected = try executionDestination(botID: bot.id)
        try validate(selected, label: bot.name)
        for thread in threads {
            // A contextual pin can provide explicit authority over legacy catalog
            // ownership. Unpinned workspace threads have no such override, on
            // either the Mac or a VM; never strand them by changing the owner.
            if let owner = bot.workspaceID, let original = thread.workspaceID, owner != original,
               try conversationContextPin(linkedTo: thread.id) == nil {
                throw BotStoreError.invalidInput("Conversation ‘\(thread.title)’ belongs to another workspace and has no explicit workspace access. Its saved destination has not been changed.")
            }
            try validate(thread.destination ?? selected, label: "Conversation ‘\(thread.title)’", threadWorkspace: thread.workspaceID)
        }
        for routine in try listRoutines(botID: bot.id) {
            try validate(routine.definition.scheduleSpec?.executionDestination ?? selected, label: "Schedule ‘\(routine.definition.name)’")
        }
    }

    func assertWorkspaceTransferIdle(botIDs: Set<BotID>, resources: Set<BotID>, threads: [WorkspaceTransferThreadReference],
        computerControl: BotComputerControl, hasLiveRun: (BotID) -> Bool) throws {
        for resource in resources where computerControl.isControlledByUser(resource, resourceID: resource) {
            throw BotStoreError.invalidInput("You are controlling this computer. Return control before moving it.")
        }
        for bot in botIDs {
            guard !hasLiveRun(bot) else { throw BotStoreError.invalidInput("This bot has work in progress. Finish it before moving resources.") }
            let query = try db.prepare("""
                SELECT 1 FROM bot_queued_follow_ups WHERE bot_id=?
                UNION ALL SELECT 1 FROM bot_group_turns WHERE bot_id=? AND state IN ('planned','waiting_for_bot','running') LIMIT 1;
                """)
            defer { query.reset() }
            try query.bind(1, bot.value.uuidString.lowercased())
            try query.bind(2, bot.value.uuidString.lowercased())
            guard try !query.step() else { throw BotStoreError.invalidInput("This bot has queued work. Finish or remove it before moving resources.") }
        }
        for thread in threads {
            let query = try db.prepare("SELECT 1 FROM agent_runs WHERE thread_id=? COLLATE NOCASE AND status IN ('pending','running') LIMIT 1;")
            defer { query.reset() }
            try query.bind(1, thread.id.value.uuidString)
            guard try !query.step() else {
                throw BotStoreError.invalidInput("Conversation ‘\(thread.title)’ has work in progress. Finish it before moving resources.")
            }
        }
    }
}
