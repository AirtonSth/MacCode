import XCTest
import CoreModel
import Security
@testable import Persistence

final class BotSecretStoreTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: BotStore!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
    }

    override func tearDown() {
        store = nil
        db = nil
    }

    func test_roundTripUpdateDeleteAndBotIsolation_metadataOnly() throws {
        let secretStore = InMemoryBotSecretStore()
        let first = BotID(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
        let other = BotID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

        try secretStore.save(botID: first, name: "SERVICE_TOKEN", value: "fixture-value-one")
        XCTAssertEqual(try secretStore.list(botID: first).map(\.name), ["SERVICE_TOKEN"])
        XCTAssertTrue(try secretStore.list(botID: other).isEmpty)
        XCTAssertEqual(try secretStore.load(botID: first, name: "SERVICE_TOKEN"), "fixture-value-one")

        try secretStore.save(botID: first, name: "SERVICE_TOKEN", value: "fixture-value-two")
        XCTAssertEqual(try secretStore.load(botID: first, name: "SERVICE_TOKEN"), "fixture-value-two")
        XCTAssertNil(try secretStore.load(botID: other, name: "SERVICE_TOKEN"))

        let metadata = try secretStore.list(botID: first)
        let encodedMetadata = try JSONSerialization.data(withJSONObject: metadata.map { ["name": $0.name] })
        XCTAssertFalse(String(data: encodedMetadata, encoding: .utf8)?.contains("fixture-value") == true)

        try secretStore.delete(botID: first, name: "SERVICE_TOKEN")
        XCTAssertTrue(try secretStore.list(botID: first).isEmpty)
    }

    func test_keychainRoundTrip_usesUniqueServiceAndKeepsBotsIsolated() throws {
        let service = "io.remotecode.test.bot-secrets.\(UUID().uuidString)"
        let secretStore = BotKeychainSecretStore(service: service)
        let first = BotID(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
        let other = BotID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        defer {
            let cleanup: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: false,
            ]
            _ = SecItemDelete(cleanup as CFDictionary)
        }

        try secretStore.save(botID: first, name: "SERVICE_TOKEN", value: "fixture-keychain-one")
        try secretStore.save(botID: other, name: "SERVICE_TOKEN", value: "fixture-keychain-other")
        try secretStore.save(botID: other, name: "OTHER_TOKEN", value: "fixture-keychain-other-name")
        XCTAssertEqual(try secretStore.list(botID: first).map(\.name), ["SERVICE_TOKEN"])
        XCTAssertEqual(try secretStore.list(botID: other).map(\.name), ["OTHER_TOKEN", "SERVICE_TOKEN"])
        XCTAssertEqual(try secretStore.load(botID: first, name: "SERVICE_TOKEN"), "fixture-keychain-one")
        XCTAssertEqual(try secretStore.load(botID: other, name: "SERVICE_TOKEN"), "fixture-keychain-other")

        try secretStore.save(botID: first, name: "SERVICE_TOKEN", value: "fixture-keychain-updated")
        XCTAssertEqual(try secretStore.load(botID: first, name: "SERVICE_TOKEN"), "fixture-keychain-updated")
        XCTAssertEqual(try secretStore.load(botID: other, name: "SERVICE_TOKEN"), "fixture-keychain-other")

        let metadata = try secretStore.list(botID: first)
        let encodedMetadata = String(
            data: try JSONEncoder().encode(metadata),
            encoding: .utf8
        )
        XCTAssertFalse(encodedMetadata?.contains("fixture-keychain") == true)

        var runtimeEnvironment = [BotSecretEnvironment.botIDEnvironmentKey: first.value.uuidString]
        runtimeEnvironment = try BotSecretEnvironment.applying(to: runtimeEnvironment, store: secretStore)
        XCTAssertEqual(runtimeEnvironment["SERVICE_TOKEN"], "fixture-keychain-updated")
        XCTAssertNil(runtimeEnvironment["OTHER_TOKEN"])

        try secretStore.delete(botID: first, name: "SERVICE_TOKEN")
        XCTAssertNil(try secretStore.load(botID: first, name: "SERVICE_TOKEN"))
        XCTAssertEqual(try secretStore.load(botID: other, name: "SERVICE_TOKEN"), "fixture-keychain-other")

        try secretStore.save(botID: first, name: "ANOTHER_TOKEN", value: "fixture-keychain-delete-all")
        try secretStore.deleteAll(botID: first)
        XCTAssertTrue(try secretStore.list(botID: first).isEmpty)
        XCTAssertEqual(try secretStore.list(botID: other).map(\.name), ["OTHER_TOKEN", "SERVICE_TOKEN"])
    }

    func test_contextStoreSeparatesNamespacesForSameLogicalBot() throws {
        let logicalBot = BotID()
        let identityA = try BotContextRuntimeIdentity(hostID: "host", botID: logicalBot, context: .general, policyRevision: 1)
        let identityB = try BotContextRuntimeIdentity(hostID: "host", botID: logicalBot, context: .workspace(WorkspaceID()), policyRevision: 1)
        let backing = InMemoryBotSecretStore()
        let storeA = BotContextSecretStore(identity: identityA, store: backing, authorizes: { true })
        let storeB = BotContextSecretStore(identity: identityB, store: backing, authorizes: { true })

        try storeA.save(botID: logicalBot, name: "MARKER", value: "A")
        try storeB.save(botID: logicalBot, name: "MARKER", value: "B")
        XCTAssertEqual(try storeA.load(botID: logicalBot, name: "MARKER"), "A")
        XCTAssertEqual(try storeB.load(botID: logicalBot, name: "MARKER"), "B")
        XCTAssertEqual(try backing.load(botID: logicalBot, name: "MARKER"), nil)
    }

    func test_contextStoreDeniesForeignBotAndInitialDenialWithoutStorageAccess() throws {
        let logicalBot = BotID()
        let identity = try BotContextRuntimeIdentity(hostID: "host", botID: logicalBot, context: .general, policyRevision: 1)
        let backing = CountingSecretStore()
        let denied = BotContextSecretStore(identity: identity, store: backing, authorizes: { false })
        XCTAssertThrowsError(try denied.list(botID: logicalBot))
        XCTAssertThrowsError(try BotContextSecretStore(identity: identity, store: backing, authorizes: { true }).list(botID: BotID()))
        XCTAssertEqual(backing.operationCount, 0)
    }

    func test_contextStoreRechecksAuthorizationAfterReadAndListing() throws {
        let logicalBot = BotID()
        let identity = try BotContextRuntimeIdentity(hostID: "host", botID: logicalBot, context: .general, policyRevision: 1)
        let backing = CountingSecretStore()
        try backing.save(botID: identity.storageBotID, name: "MARKER", value: "secret")
        let authorized = AuthorizationFlag()
        authorized.value = true
        backing.onRead = { authorized.value = false }
        let scoped = BotContextSecretStore(identity: identity, store: backing, authorizes: { authorized.value })
        XCTAssertThrowsError(try scoped.load(botID: logicalBot, name: "MARKER"))
        authorized.value = true
        XCTAssertThrowsError(try scoped.list(botID: logicalBot))
    }

    func test_secretNamesRequireASCIIEnvironmentKeys_andReserveRemoteCodeControlKeys() throws {
        XCTAssertTrue(BotKeychainSecretStore.isValidName("SERVICE_TOKEN"))
        XCTAssertTrue(BotKeychainSecretStore.isValidName("_private2"))
        for invalid in [
            "é_TOKEN", "1SERVICE", "SERVICE-TOKEN", "RC_REMOTE_CODE_BOT_ID",
            "RC_TOKEN_SAVER_THREAD_ID", "RC2_HTTP_PORT", "REMOTE_CODE_SUBAGENT_TELEMETRY_COMMAND",
        ] {
            XCTAssertFalse(BotKeychainSecretStore.isValidName(invalid), invalid)
        }
    }

    func test_secretToolsRequireExplicitInstruction_andNeverReturnValues() throws {
        let secretStore = InMemoryBotSecretStore()
        let caller = try store.create(name: "Alpha", title: "", description: "", provider: .claude)
        let other = try store.create(name: "Beta", title: "", description: "", provider: .codex)
        let service = BotSelfConfigService(callerBotID: caller.id, store: store, secretStore: secretStore)

        XCTAssertThrowsError(try service.invoke(name: BotSelfConfigCatalog.saveSecret, arguments: [
            "name": "SERVICE_TOKEN",
            "value": "fixture-value-one",
        ])) { error in
            XCTAssertEqual(
                error as? BotSelfConfigError,
                .invalid("Protected secret changes require explicit user instruction (user_confirmed=true).")
            )
        }

        let saved = try service.invoke(name: BotSelfConfigCatalog.saveSecret, arguments: [
            "name": "SERVICE_TOKEN",
            "value": "fixture-value-one",
            "user_confirmed": true,
        ])
        XCTAssertEqual(saved["saved"] as? Bool, true)
        XCTAssertNil(saved["value"])
        let savedJSON = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: saved),
            encoding: .utf8
        ))
        XCTAssertFalse(savedJSON.contains("fixture-value-one"))

        try secretStore.save(botID: other.id, name: "OTHER_TOKEN", value: "fixture-other-value")
        XCTAssertEqual(
            try service.invoke(name: BotSelfConfigCatalog.listSecrets)["secrets"] as? [String],
            ["SERVICE_TOKEN"]
        )
        XCTAssertThrowsError(try service.invoke(name: BotSelfConfigCatalog.listSecrets, arguments: [
            "bot_id": other.id.value.uuidString,
        ])) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .crossBot)
        }

        _ = try service.invoke(name: BotSelfConfigCatalog.saveSecret, arguments: [
            "name": "SERVICE_TOKEN",
            "value": "fixture-value-two",
            "user_confirmed": true,
        ])
        XCTAssertEqual(try secretStore.load(botID: caller.id, name: "SERVICE_TOKEN"), "fixture-value-two")

        let deleted = try service.invoke(name: BotSelfConfigCatalog.deleteSecret, arguments: [
            "name": "SERVICE_TOKEN",
            "user_confirmed": true,
        ])
        XCTAssertEqual(deleted["deleted"] as? Bool, true)
        XCTAssertTrue(try secretStore.list(botID: caller.id).isEmpty)
        XCTAssertEqual(try secretStore.list(botID: other.id).map(\.name), ["OTHER_TOKEN"])
    }
}

private final class AuthorizationFlag: @unchecked Sendable {
    var value = false
}

private final class CountingSecretStore: BotSecretStore, @unchecked Sendable {
    private let backing = InMemoryBotSecretStore()
    private let lock = NSLock()
    private var count = 0
    var onRead: (() -> Void)?

    var operationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    private func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func list(botID: BotID) throws -> [BotSecretMetadata] {
        record()
        onRead?()
        return try backing.list(botID: botID)
    }

    func save(botID: BotID, name: String, value: String) throws {
        record()
        try backing.save(botID: botID, name: name, value: value)
    }

    func load(botID: BotID, name: String) throws -> String? {
        record()
        onRead?()
        return try backing.load(botID: botID, name: name)
    }

    func delete(botID: BotID, name: String) throws {
        record()
        try backing.delete(botID: botID, name: name)
    }

    func deleteAll(botID: BotID) throws {
        record()
        try backing.deleteAll(botID: botID)
    }
}
