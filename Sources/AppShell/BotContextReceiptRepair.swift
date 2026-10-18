import AgentRuntime
import CoreModel
import Foundation
import Darwin
import Persistence

/// Repairs cleanup evidence, never an ambiguous command's execution outcome.
enum BotContextReceiptRepair {
    struct Receipt: Codable {
        let version: Int
        let hostID: String
        let botID: BotID
        let context: BotContext
        let policyRevision: Int64
        let conversationID: BotConversationID
        let threadID: AgentThreadID
        let runID: AgentRunID
        let authorityStateAtRepair: String
        let authorityRevisionAtRepair: Int64?
        let runStatus: String
        let cleanup: String
    }

    struct Report: Codable {
        var repaired: [Receipt] = []
        var existing: [Receipt] = []
        var failures: [String: String] = [:]
    }

    private struct Candidate {
        let scope: String
        let name: String
        let record: BotContextGuestRecovery.Record
        let identity: BotContextRuntimeIdentity
        let threadID: AgentThreadID
    }

    static func run(databaseURL: URL, appSupport: URL) throws -> Report {
        var file = stat()
        guard databaseURL.isFileURL, lstat(databaseURL.path, &file) == 0,
              (file.st_mode & S_IFMT) == S_IFREG, file.st_nlink == 1 else {
            throw SQLiteError.open("contextual repair requires an existing regular host database")
        }
        let db = try SQLiteDB(path: databaseURL.path)
        let version = try db.prepare("SELECT MAX(version), typeof(MAX(version)) FROM schema_meta;")
        guard try version.step(), version.columnText(1) == "integer",
              version.columnInt64(0) == Int64(Schema.currentVersion) else {
            throw SQLiteError.execute("contextual repair requires the current host schema")
        }
        version.reset()
        try db.enableFullDurability()
        let store = BotStore(db: db)
        let support = try PrivateDirectory(appSupport, create: false)
        defer { support.close() }
        guard try PrivateDirectoryTree.childNames(support).contains("guest-runs") else { return Report() }
        let root = try support.child("guest-runs", create: false)
        defer { root.close() }
        var candidates: [Candidate] = []
        for scope in try PrivateDirectoryTree.childNames(root) {
            if scope == ".DS_Store" || scope.hasSuffix(".env") { continue }
            guard UUID(uuidString: scope)?.uuidString.lowercased() == scope else {
                throw SQLiteError.execute("unrecognized contextual repair scope")
            }
            let directory = try root.child(scope, create: false)
            defer { directory.close() }
            for name in try PrivateDirectoryTree.childNames(directory) where name.hasSuffix(".context.json") {
                let data = try PrivateDirectoryTree.readFile(name, in: directory, maximumBytes: 1_024 * 1_024)
                let record = try JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: data)
                guard record.version == 1, let identity = record.identity,
                      identity.storageBotID.value.uuidString.lowercased() == scope,
                      name == record.runID.value.uuidString.lowercased() + ".context.json",
                      let conversationID = record.conversationID,
                      let pin = try store.conversationContextPin(conversationID: conversationID),
                      pin.hostID == record.hostID, pin.botID == record.botID,
                      pin.context == record.context, pin.policyRevision == record.policyRevision,
                      let conversation = try store.conversation(id: conversationID),
                      let threadID = conversation.linkedAgentThreadID,
                      let thread = try AgentThreadRepository(db: db).get(id: threadID),
                      thread.actor == .bot(record.botID), thread.executionTarget == .vm,
                      thread.provider == .distill,
                      let run = try AgentRunRepository(db: db).get(id: record.runID),
                      run.threadId == threadID, run.provider == .distill else {
                    throw SQLiteError.execute("contextual repair requires canonical conversation and run identity")
                }
                let candidate = Candidate(scope: scope, name: name, record: record, identity: identity, threadID: threadID)
                try verifyNativeHome(candidate, support: support, requireNoConfig: false)
                candidates.append(candidate)
            }
        }
        for candidate in candidates {
            if let runtime = try ProviderSessionRuntimeRepository(db: db).get(threadId: candidate.threadID),
               runtime.status == .running || runtime.status == .pending {
                guard let currentRun = runtime.lastRunId,
                      candidates.contains(where: {
                          $0.threadID == candidate.threadID && $0.scope == candidate.scope && $0.record.runID == currentRun
                      }) else {
                    throw SQLiteError.execute("contextual repair cannot target a different provider run")
                }
            }
        }
        var report = Report()
        guard !candidates.isEmpty else { return report }
        // Fence interrupted remote claims; repair never releases or replays them.
        try CommandReceiptRepository(db: db).recoverInterruptedClaims()
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        let scopes = Set(candidates.filter { $0.record.state == .pending }.map(\.scope))
        let cleanup = BotContextGuestRecovery.reconcile(docker: docker, appSupport: appSupport, selectedScopes: scopes)
        report.failures = cleanup.failures.mapValues { _ in "Contextual runtime cleanup remains unconfirmed." }
        for candidate in candidates {
            let runID = candidate.record.runID.value.uuidString.lowercased()
            guard report.failures[candidate.scope] == nil else { continue }
            do {
                try verifyEnded(candidate, support: support, runs: root, docker: docker, appSupport: appSupport)
                let runs = AgentRunRepository(db: db)
                try runs.markStopped(id: candidate.record.runID, status: .interrupted)
                let providerSessions = ProviderSessionRuntimeRepository(db: db)
                if let runtime = try providerSessions.get(threadId: candidate.threadID),
                   runtime.lastRunId == candidate.record.runID,
                   runtime.status == .running || runtime.status == .pending {
                    try providerSessions.markStopped(threadId: candidate.threadID, status: .interrupted)
                }
                _ = try store.closeContextDelegationTree(runID: candidate.record.runID)
                guard let run = try runs.get(id: candidate.record.runID), run.status != .running, run.status != .pending,
                      let conversationID = candidate.record.conversationID else {
                    throw SQLiteError.execute("contextual repair has no terminal run proof")
                }
                let binding = try store.getContextBinding(hostID: candidate.record.hostID, botID: candidate.record.botID,
                                                         context: candidate.record.context)
                let receipt = Receipt(version: 1, hostID: candidate.record.hostID, botID: candidate.record.botID,
                    context: candidate.record.context, policyRevision: candidate.record.policyRevision,
                    conversationID: conversationID, threadID: candidate.threadID, runID: candidate.record.runID,
                    authorityStateAtRepair: binding?.state.rawValue ?? "missing",
                    authorityRevisionAtRepair: binding?.policyRevision, runStatus: run.status.rawValue, cleanup: "confirmed")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let json = String(decoding: try encoder.encode(receipt), as: UTF8.self)
                let persisted = try EventLogRepository(db: db).recordContextCleanupRepair(runID: candidate.record.runID, payloadJSON: json)
                let proof = try JSONDecoder().decode(Receipt.self, from: Data(persisted.payloadJSON.utf8))
                guard proof.runID == receipt.runID, proof.threadID == receipt.threadID,
                      proof.hostID == receipt.hostID, proof.botID == receipt.botID, proof.context == receipt.context,
                      proof.policyRevision == receipt.policyRevision, proof.conversationID == receipt.conversationID,
                      proof.cleanup == "confirmed" else {
                    throw SQLiteError.execute("contextual cleanup receipt identity mismatch")
                }
                if persisted.created { report.repaired.append(proof) } else { report.existing.append(proof) }
            } catch {
                // Output is content-free; detailed paths/provider messages never enter the receipt.
                report.failures[runID] = "Contextual cleanup receipt repair remains incomplete."
            }
        }
        return report
    }

    private static func verifyEnded(_ candidate: Candidate, support: PrivateDirectory, runs: PrivateDirectory,
                                    docker: BotComputerDockerCLI, appSupport: URL) throws {
        let directory = try runs.child(candidate.scope, create: false)
        defer { directory.close() }
        let data = try PrivateDirectoryTree.readFile(candidate.name, in: directory, maximumBytes: 1_024 * 1_024)
        let record = try JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: data)
        guard record.version == 1, record.identity == candidate.identity, record.runID == candidate.record.runID,
              record.conversationID == candidate.record.conversationID, record.state == .ended,
              try !PrivateDirectoryTree.childNames(directory).contains(record.runID.value.uuidString.lowercased() + ".env") else {
            throw SQLiteError.execute("contextual cleanup is not confirmed")
        }
        let service = BotComputerGuestService(appSupport: appSupport, docker: docker, recipeContext: nil)
        if let actual = try service.inspectForContextRecovery(identity: candidate.identity), actual.running {
            throw SQLiteError.execute("contextual runtime cleanup is not confirmed")
        }
        try verifyNativeHome(candidate, support: support, requireNoConfig: true)
    }

    private static func verifyNativeHome(_ candidate: Candidate, support: PrivateDirectory, requireNoConfig: Bool) throws {
        guard try PrivateDirectoryTree.childNames(support).contains("bot-guests") else { return }
        let guests = try support.child("bot-guests", create: false)
        defer { guests.close() }
        guard try PrivateDirectoryTree.childNames(guests).contains(candidate.scope) else { return }
        let guest = try guests.child(candidate.scope, create: false)
        defer { guest.close() }
        guard try PrivateDirectoryTree.childNames(guest).contains("home") else { return }
        let home = try guest.child("home", create: false)
        defer { home.close() }
        let name = ".distill-context-session-" + candidate.record.conversationID!.value.uuidString.lowercased()
        guard try PrivateDirectoryTree.childNames(home).contains(name) else { return }
        let native = try home.child(name, create: false)
        defer { native.close() }
        if requireNoConfig, try PrivateDirectoryTree.childNames(native).contains("config.toml") {
            throw SQLiteError.execute("contextual configuration cleanup is not confirmed")
        }
    }
}
