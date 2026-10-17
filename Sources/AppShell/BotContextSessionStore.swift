import Foundation
import AgentRuntime
import CoreModel

/// Host-owned binding between a contextual conversation and native Distill history.
enum BotContextSessionStore {
    struct Binding: Codable, Equatable {
        let version: Int
        let pin: BotConversationContextPin
        let threadID: AgentThreadID
        let parentRunID: AgentRunID?
        let cwd: String
        var providerSessionID: String?
    }

    static func directoryName(pin: BotConversationContextPin) -> String {
        ".distill-context-session-\(pin.conversationID.value.uuidString.lowercased())"
    }

    private static func identity(for pin: BotConversationContextPin) throws -> BotContextRuntimeIdentity {
        try BotContextRuntimeIdentity(hostID: pin.hostID, botID: pin.botID, context: pin.context, policyRevision: pin.policyRevision)
    }

    private static func isMissing(_ error: Error) -> Bool {
        guard case DistillGuestCredentialError.writeFailed(_, let code) = error else { return false }
        return code == ENOENT
    }

    static func validate(
        pin: BotConversationContextPin,
        threadID: AgentThreadID,
        parentRunID: AgentRunID?,
        cwd: String,
        resumeCursor: String?,
        appSupport: URL,
        authorizes: @Sendable () -> Bool
    ) throws {
        guard authorizes() else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
        let storageBotID = try identity(for: pin).storageBotID
        let name = directoryName(pin: pin)
        let homeURL = BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: storageBotID)
        let home: PrivateDirectory?
        do { home = try PrivateDirectory(homeURL, create: false) }
        catch { if isMissing(error) { home = nil } else { throw error } }
        defer { home?.close() }
        let homeEntries = try home?.entriesChecked() ?? []
        let homeExists = homeEntries.contains(name)
        if homeExists {
            let safeHome = try home!.child(name, create: false)
            safeHome.close()
        }

        let rootURL = appSupport.appendingPathComponent("bot-context-sessions", isDirectory: true)
        let root: PrivateDirectory?
        do { root = try PrivateDirectory(rootURL, create: false) }
        catch { if isMissing(error) { root = nil } else { throw error } }
        defer { root?.close() }
        let scope: PrivateDirectory?
        do { scope = try root?.child(storageBotID.value.uuidString.lowercased(), create: false) }
        catch { if isMissing(error) { scope = nil } else { throw error } }
        defer { scope?.close() }

        let filename = pin.conversationID.value.uuidString.lowercased() + ".json"
        let metadataExists = try scope?.entriesChecked().contains(filename) ?? false
        guard metadataExists else {
            guard resumeCursor == nil, !homeExists else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            return
        }
        guard let data = scope?.read(filename),
              let binding = try? JSONDecoder().decode(Binding.self, from: data),
              binding.version == 1, binding.pin == pin,
              binding.threadID == threadID, binding.parentRunID == parentRunID,
              binding.cwd == cwd, binding.providerSessionID == resumeCursor,
              homeExists || (resumeCursor == nil && binding.providerSessionID == nil) else {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
        if resumeCursor != nil, !homeExists { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
    }

    static func prepare(
        pin: BotConversationContextPin,
        threadID: AgentThreadID,
        parentRunID: AgentRunID?,
        cwd: String,
        resumeCursor: String?,
        appSupport: URL,
        authorizes: @Sendable () -> Bool
    ) throws -> URL {
        try validate(pin: pin, threadID: threadID, parentRunID: parentRunID, cwd: cwd, resumeCursor: resumeCursor, appSupport: appSupport, authorizes: authorizes)
        guard authorizes() else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
        let storageBotID = try identity(for: pin).storageBotID
        let support = try PrivateDirectory(appSupport, create: false)
        defer { support.close() }
        let root = try support.child("bot-context-sessions", create: true)
        defer { root.close() }
        let scope = try root.child(storageBotID.value.uuidString.lowercased(), create: true)
        defer { scope.close() }
        try root.synchronize()
        try support.synchronize()
        let filename = pin.conversationID.value.uuidString.lowercased() + ".json"
        let metadataExists = try scope.entriesChecked().contains(filename)
        if !metadataExists {
            guard resumeCursor == nil else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
            guard authorizes() else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
            let binding = Binding(version: 1, pin: pin, threadID: threadID, parentRunID: parentRunID, cwd: cwd, providerSessionID: nil)
            try scope.writeAtomically(JSONEncoder().encode(binding), to: filename)
            try scope.synchronize()
        } else {
            guard let data = scope.read(filename),
                  let binding = try? JSONDecoder().decode(Binding.self, from: data),
                  binding.version == 1, binding.pin == pin, binding.threadID == threadID,
                  binding.parentRunID == parentRunID, binding.cwd == cwd,
                  binding.providerSessionID == resumeCursor else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
        }
        guard authorizes() else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
        let homeURL = BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: storageBotID)
        let home = try PrivateDirectory(homeURL, create: false)
        defer { home.close() }
        let guestHome = try home.child(directoryName(pin: pin), create: true)
        defer { guestHome.close() }
        try guestHome.synchronize()
        try home.synchronize()
        try validate(pin: pin, threadID: threadID, parentRunID: parentRunID, cwd: cwd, resumeCursor: resumeCursor, appSupport: appSupport, authorizes: authorizes)
        return homeURL.appendingPathComponent(directoryName(pin: pin), isDirectory: true)
    }

    static func recordOpened(
        sessionID: String,
        pin: BotConversationContextPin,
        threadID: AgentThreadID,
        parentRunID: AgentRunID?,
        cwd: String,
        expectedResumeCursor: String?,
        appSupport: URL,
        authorizes: @Sendable () -> Bool
    ) throws {
        let trimmedID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedID == sessionID, sessionID.utf8.count <= 512,
              !sessionID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), authorizes() else {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
        try validate(pin: pin, threadID: threadID, parentRunID: parentRunID, cwd: cwd, resumeCursor: expectedResumeCursor, appSupport: appSupport, authorizes: authorizes)
        let storageBotID = try identity(for: pin).storageBotID
        let support = try PrivateDirectory(appSupport, create: false)
        defer { support.close() }
        let root = try support.child("bot-context-sessions", create: false)
        defer { root.close() }
        let scope = try root.child(storageBotID.value.uuidString.lowercased(), create: false)
        defer { scope.close() }
        let filename = pin.conversationID.value.uuidString.lowercased() + ".json"
        guard let data = scope.read(filename), var binding = try? JSONDecoder().decode(Binding.self, from: data),
              binding.version == 1, binding.pin == pin, binding.threadID == threadID,
              binding.parentRunID == parentRunID, binding.cwd == cwd,
              binding.providerSessionID == expectedResumeCursor, authorizes() else {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
        binding.providerSessionID = sessionID
        try scope.writeAtomically(JSONEncoder().encode(binding), to: filename)
        try scope.synchronize()
    }
}
