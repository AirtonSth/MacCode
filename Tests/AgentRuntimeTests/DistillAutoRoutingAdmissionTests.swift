import Foundation
import XCTest
import CoreModel
@testable import AgentRuntime

final class DistillAutoRoutingAdmissionTests: XCTestCase {
    func test_autoRoutingRequiresEnabledOptionsAndConnectedReferencedAccountsWithoutWritingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DistillAutoAdmission-\(UUID().uuidString)")
        let home = root.appendingPathComponent("distill")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func save(enabled: Bool, options: [DistillAutoOption], connected: Bool = true) throws {
            let account = DistillAccountStatus(provider: .chatgpt, connected: true, id: "acct", legacy: false)
            let registry = DistillAccountRegistry(version: 1, accounts: [account],
                routing: DistillAutoRouting(enabled: enabled, options: options))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(registry).write(to: home.appendingPathComponent("accounts.json"), options: .atomic)
            let accountHome = home.appendingPathComponent("accounts/acct", isDirectory: true)
            try FileManager.default.createDirectory(at: accountHome, withIntermediateDirectories: true)
            if connected {
                try Data(#"{"tokens":{"access_token":"connected"}}"#.utf8)
                    .write(to: accountHome.appendingPathComponent("codex-auth.json"), options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: accountHome.appendingPathComponent("codex-auth.json"))
            }
        }
        let option = DistillAutoOption(id: "route", accountID: "acct", mainModel: "chatgpt/model")
        func error(_ expected: DistillAutoRoutingError, file: StaticString = #filePath, line: UInt = #line) throws {
            do { _ = try DistillAccounts.autoRoutingAccounts(home: home); XCTFail("Expected \(expected)", file: file, line: line) }
            catch { XCTAssertEqual(error as? DistillAutoRoutingError, expected, file: file, line: line) }
        }

        try save(enabled: false, options: [option])
        try error(.disabled)
        try save(enabled: true, options: [])
        try error(.missingOptions)
        try save(enabled: true, options: [option], connected: false)
        try error(.noConnectedAccounts)
        try save(enabled: true, options: [DistillAutoOption(id: "route", accountID: "absent", mainModel: "m")])
        let beforeUnreferenced = try Data(contentsOf: home.appendingPathComponent("accounts.json"))
        try error(.noConnectedAccounts)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("accounts.json")), beforeUnreferenced)

        try save(enabled: true, options: [option])
        let registryBytes = try Data(contentsOf: home.appendingPathComponent("accounts.json"))
        let accounts = try DistillAccounts.autoRoutingAccounts(home: home)
        XCTAssertEqual(accounts.map(\.id), ["acct"])
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("accounts.json")), registryBytes)
        XCTAssertEqual(try DistillGuestCredentials.accountsForRun(model: "auto", hostConfig: "", hostHome: home).map(\.id), ["acct"])
    }

    func test_startSessionRejectsDisabledAutoBeforeAttemptingProviderSpawn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DistillAutoPreflight-\(UUID().uuidString)")
        let home = root.appendingPathComponent("distill")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = DistillACPAdapter(binaryNameOverride: root.appendingPathComponent("missing-binary").path)
        do {
            _ = try await adapter.startSession(AgentRunRequest(threadId: AgentThreadID(), provider: .distill,
                model: "auto", cwd: root.path, prompt: "Run", environment: ["DISTILL_HOME": home.path])) { _ in }
            XCTFail("Disabled Auto must fail before provider launch")
        } catch {
            XCTAssertEqual(error as? DistillAutoRoutingError, .disabled)
        }
    }
}
