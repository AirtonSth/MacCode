import Foundation
import CoreModel

public extension BotStore {
    func contextDelegation(childRunID: AgentRunID) throws -> BotContextDelegation? {
        let query = try db.prepare("SELECT child_run_id, parent_run_id, payload_json, typeof(closed), closed FROM bot_context_delegations WHERE child_run_id=? COLLATE NOCASE;")
        defer { query.reset() }
        try query.bind(1, childRunID.value.uuidString.lowercased())
        guard try query.step() else { return nil }
        guard query.columnText(0) == childRunID.value.uuidString.lowercased(),
              let parentRaw = query.columnText(1), let parentUUID = UUID(uuidString: parentRaw),
              query.columnText(3) == "integer", [Int64(0), 1].contains(query.columnInt64(4)),
              let json = query.columnText(2), let data = json.data(using: .utf8) else {
            throw BotStoreError.invalidInput("malformed context delegation")
        }
        let payload: BotContextDelegation
        do { payload = try JSONDecoder().decode(BotContextDelegation.self, from: data) }
        catch { throw BotStoreError.invalidInput("malformed context delegation") }
        guard payload.version == 1, payload.childRunID == childRunID,
              payload.parentRunID.value == parentUUID, payload.closed == false,
              Self.validPin(payload.parentPin), Self.validPin(payload.childPin),
              payload.parentPin.hostID == payload.childPin.hostID,
              payload.parentPin.context == payload.childPin.context,
              payload.parentRunID != payload.childRunID,
              payload.parentThreadID != payload.childThreadID,
              payload.parentPin.botID != payload.childPin.botID else {
            throw BotStoreError.invalidInput("malformed context delegation")
        }
        return BotContextDelegation(version: 1, parentRunID: payload.parentRunID, parentThreadID: payload.parentThreadID, parentPin: payload.parentPin, childRunID: payload.childRunID, childThreadID: payload.childThreadID, childPin: payload.childPin, closed: query.columnInt64(4) == 1)
    }

    func contextDelegations() throws -> [BotContextDelegation] {
        let query = try db.prepare("SELECT child_run_id FROM bot_context_delegations ORDER BY child_run_id;")
        defer { query.reset() }
        var rows: [BotContextDelegation] = []
        while try query.step() {
            guard let raw = query.columnText(0), let uuid = UUID(uuidString: raw),
                  let row = try contextDelegation(childRunID: AgentRunID(uuid)) else {
                throw BotStoreError.invalidInput("malformed context delegation")
            }
            rows.append(row)
        }
        return rows
    }

    func recordContextDelegation(hostID: String, parentRunID: AgentRunID, childRunID: AgentRunID, childThreadID: AgentThreadID) throws -> BotContextDelegation {
        try db.transaction {
            guard let parent = try AgentRunRepository(db: db).get(id: parentRunID), parent.status == .running,
                  let parentPin = try conversationContextPin(linkedTo: parent.threadId),
                  parentPin.hostID == hostID,
                  let parentConversation = try conversation(id: parentPin.conversationID),
                  parentConversation.botID == parentPin.botID, parentConversation.linkedAgentThreadID == parent.threadId,
                  let childPin = try conversationContextPin(linkedTo: childThreadID), childPin.hostID == hostID,
                  let childConversation = try conversation(id: childPin.conversationID),
                  childConversation.botID == childPin.botID, childConversation.linkedAgentThreadID == childThreadID,
                  parentRunID != childRunID, parent.threadId != childThreadID,
                  parentPin.botID != childPin.botID, parentPin.context == childPin.context,
                  try authorizesContextDelegationUnlocked(hostID: hostID, runID: parentRunID, threadID: parent.threadId),
                  try Self.grants(self, hostID: hostID, pin: parentPin, delegation: true),
                  try Self.grants(self, hostID: hostID, pin: childPin, delegation: false) else {
                throw BotStoreError.notFound
            }
            if let child = try AgentRunRepository(db: db).get(id: childRunID) {
                guard child.threadId == childThreadID, child.status == .pending || child.status == .running else {
                    throw BotStoreError.invalidInput("invalid child run")
                }
            }
            var ancestorRunIDs: Set<AgentRunID> = [parentRunID]
            var ancestorThreadIDs: Set<AgentThreadID> = [parent.threadId]
            var ancestorBotIDs: Set<BotID> = [parentPin.botID]
            var current = parentRunID
            var depth = 0
            while let edge = try contextDelegation(childRunID: current) {
                guard depth < BotContextDelegation.maximumAncestorDepth,
                      ancestorRunIDs.insert(edge.parentRunID).inserted,
                      ancestorThreadIDs.insert(edge.parentThreadID).inserted,
                      ancestorBotIDs.insert(edge.parentPin.botID).inserted else {
                    throw BotStoreError.invalidInput("context delegation ancestry invalid")
                }
                current = edge.parentRunID
                depth += 1
            }
            guard depth < BotContextDelegation.maximumAncestorDepth,
                  !ancestorRunIDs.contains(childRunID), !ancestorThreadIDs.contains(childThreadID), !ancestorBotIDs.contains(childPin.botID) else {
                throw BotStoreError.invalidInput("context delegation cycle")
            }
            if let existing = try contextDelegation(childRunID: childRunID) {
                guard !existing.closed, existing.parentRunID == parentRunID, existing.parentThreadID == parent.threadId,
                      existing.childThreadID == childThreadID, existing.parentPin == parentPin, existing.childPin == childPin else {
                    throw BotStoreError.invalidInput("context delegation conflict")
                }
                return existing
            }
            let edge = BotContextDelegation(parentRunID: parentRunID, parentThreadID: parent.threadId, parentPin: parentPin, childRunID: childRunID, childThreadID: childThreadID, childPin: childPin)
            let data = try JSONEncoder().encode(edge)
            let insert = try db.prepare("INSERT INTO bot_context_delegations(child_run_id,parent_run_id,payload_json,closed) VALUES(?,?,?,0);")
            defer { insert.reset() }
            try insert.bind(1, childRunID.value.uuidString.lowercased())
            try insert.bind(2, parentRunID.value.uuidString.lowercased())
            try insert.bind(3, String(decoding: data, as: UTF8.self))
            _ = try insert.step()
            return edge
        }
    }

    func authorizesContextDelegation(hostID: String, runID: AgentRunID, threadID: AgentThreadID) throws -> Bool {
        try db.readTransaction {
            try authorizesContextDelegationUnlocked(hostID: hostID, runID: runID, threadID: threadID)
        }
    }

    private func authorizesContextDelegationUnlocked(hostID: String, runID: AgentRunID, threadID: AgentThreadID) throws -> Bool {
        var currentRunID = runID
        var expectedThreadID = threadID
        var visitedRunIDs = Set<AgentRunID>()
        var visitedBotIDs = Set<BotID>()
        var visitedThreadIDs: Set<AgentThreadID> = [threadID]
        var expectedContext: BotContext?
        var depth = 0
        while true {
            guard visitedRunIDs.insert(currentRunID).inserted else { return false }
            guard let edge = try contextDelegation(childRunID: currentRunID) else {
                guard let root = try AgentRunRepository(db: db).get(id: currentRunID) else { return true }
                return root.threadId == expectedThreadID && (root.status == .pending || root.status == .running)
            }
            if depth == 0 { visitedBotIDs.insert(edge.childPin.botID) }
            guard depth < BotContextDelegation.maximumAncestorDepth,
                  visitedBotIDs.insert(edge.parentPin.botID).inserted,
                  !edge.closed, edge.childThreadID == expectedThreadID,
                  visitedThreadIDs.insert(edge.parentThreadID).inserted,
                  edge.parentRunID != edge.childRunID, edge.parentThreadID != edge.childThreadID,
                  edge.parentPin.botID != edge.childPin.botID,
                  edge.parentPin.hostID == hostID, edge.childPin.hostID == hostID,
                  edge.parentPin.context == edge.childPin.context,
                  expectedContext == nil || edge.childPin.context == expectedContext,
                  try conversationContextPin(linkedTo: edge.childThreadID) == edge.childPin,
                  try conversationContextPin(linkedTo: edge.parentThreadID) == edge.parentPin,
                  let childConversation = try conversation(id: edge.childPin.conversationID),
                  childConversation.botID == edge.childPin.botID, childConversation.linkedAgentThreadID == edge.childThreadID,
                  let parentConversation = try conversation(id: edge.parentPin.conversationID),
                  parentConversation.botID == edge.parentPin.botID, parentConversation.linkedAgentThreadID == edge.parentThreadID,
                  let parent = try AgentRunRepository(db: db).get(id: edge.parentRunID),
                  parent.threadId == edge.parentThreadID, parent.status == .running,
                  try Self.grants(self, hostID: hostID, pin: edge.parentPin, delegation: true),
                  try Self.grants(self, hostID: hostID, pin: edge.childPin, delegation: false) else { return false }
            if let child = try AgentRunRepository(db: db).get(id: edge.childRunID) {
                guard child.threadId == edge.childThreadID, child.status == .pending || child.status == .running else { return false }
            }
            expectedContext = edge.childPin.context
            expectedThreadID = edge.parentThreadID
            currentRunID = edge.parentRunID
            depth += 1
        }
    }

    func closeContextDelegationTree(runID: AgentRunID) throws -> [BotContextDelegation] {
        try db.transaction {
            var queue: [(AgentRunID, Int)] = [(runID, 0)]
            var seen = Set<AgentRunID>()
            var closed: [BotContextDelegation] = []
            while !queue.isEmpty {
                let (current, depth) = queue.removeFirst()
                guard seen.insert(current).inserted else { continue }
                let children = try db.prepare("SELECT child_run_id FROM bot_context_delegations WHERE parent_run_id=? ORDER BY child_run_id;")
                try children.bind(1, current.value.uuidString.lowercased())
                var ids: [AgentRunID] = []
                while try children.step() {
                    guard let raw = children.columnText(0), let uuid = UUID(uuidString: raw) else { throw BotStoreError.invalidInput("malformed context delegation") }
                    ids.append(AgentRunID(uuid))
                }
                children.reset()
                if depth >= BotContextDelegation.maximumAncestorDepth && ids.contains(where: { !seen.contains($0) }) {
                    throw BotStoreError.invalidInput("context delegation depth exceeded")
                }
                for id in ids {
                    guard let edge = try contextDelegation(childRunID: id) else { throw BotStoreError.invalidInput("malformed context delegation") }
                    let update = try db.prepare("UPDATE bot_context_delegations SET closed=1 WHERE child_run_id=? COLLATE NOCASE;")
                    try update.bind(1, id.value.uuidString.lowercased())
                    _ = try update.step()
                    update.reset()
                    closed.append(BotContextDelegation(parentRunID: edge.parentRunID, parentThreadID: edge.parentThreadID, parentPin: edge.parentPin, childRunID: edge.childRunID, childThreadID: edge.childThreadID, childPin: edge.childPin, closed: true))
                    queue.append((id, depth + 1))
                }
            }
            if let incoming = try contextDelegation(childRunID: runID), !incoming.closed {
                let update = try db.prepare("UPDATE bot_context_delegations SET closed=1 WHERE child_run_id=? COLLATE NOCASE;")
                try update.bind(1, runID.value.uuidString.lowercased())
                _ = try update.step()
                update.reset()
            }
            return closed
        }
    }

    private static func validPin(_ pin: BotConversationContextPin) -> Bool {
        !pin.hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pin.policyRevision > 0 && pin.contextVersion == BotContext.contractVersion
    }

    private static func grants(_ store: BotStore, hostID: String, pin: BotConversationContextPin, delegation: Bool) throws -> Bool {
        guard validPin(pin), pin.hostID == hostID,
              try store.authorizes(hostID: hostID, botID: pin.botID, context: pin.context, action: .read, policyRevision: pin.policyRevision),
              try store.authorizes(hostID: hostID, botID: pin.botID, context: pin.context, action: .send, policyRevision: pin.policyRevision) else { return false }
        if !delegation { return true }
        return try store.authorizes(hostID: hostID, botID: pin.botID, context: pin.context, action: .delegate, policyRevision: pin.policyRevision)
    }
}
