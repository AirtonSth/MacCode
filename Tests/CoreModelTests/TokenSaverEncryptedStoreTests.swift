import XCTest
@testable import CoreModel

final class TokenSaverEncryptedStoreTests: XCTestCase {
    private var keyProviders: [String: TokenSaverInMemoryProjectKeyProvider] = [:]

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func openReadyStore(at dir: URL) throws -> TokenSaverEncryptedStore {
        let store = try makeStore(at: dir)
        try store.markMigrationComplete()
        return store
    }

    private func makeStore(at dir: URL) throws -> TokenSaverEncryptedStore {
        let key = dir.standardizedFileURL.path
        let provider = keyProviders[key] ?? TokenSaverInMemoryProjectKeyProvider()
        keyProviders[key] = provider
        return try TokenSaverEncryptedStore(projectRoot: dir, keyProvider: provider)
    }

    private func scope(_ gen: UInt64 = 1) -> TokenSaverEncryptedStore.Scope {
        .init(uid: 501, workspaceID: "w", projectID: "p", threadID: "t", provider: "claude", sessionGeneration: gen)
    }

    func test_storeReadback_byteExact() throws {
        let store = try openReadyStore(at: tempDir())
        let raw = Data("envelope-bytes".utf8)
        _ = try store.store(id: "1", plaintext: raw, scope: scope())
        XCTAssertEqual(try store.readback(id: "1", expectedScope: scope()), raw)
        XCTAssertFalse(store.plaintextExistsOnDisk(scanning: raw))
    }

    func test_scopeDigestUsesUnambiguousFramingAndIncompleteScopeIsDenied() throws {
        let first = TokenSaverEncryptedStore.Scope(
            uid: 501,
            workspaceID: "a|b",
            projectID: "c",
            threadID: "t",
            provider: "claude",
            sessionGeneration: 1
        )
        let second = TokenSaverEncryptedStore.Scope(
            uid: 501,
            workspaceID: "a",
            projectID: "b|c",
            threadID: "t",
            provider: "claude",
            sessionGeneration: 1
        )
        XCTAssertNotEqual(first.digest, second.digest)

        let incomplete = TokenSaverEncryptedStore.Scope(
            uid: 501,
            workspaceID: " ",
            projectID: "p",
            threadID: "t",
            provider: "claude",
            sessionGeneration: 0
        )
        XCTAssertFalse(incomplete.isComplete)
        let store = try openReadyStore(at: tempDir())
        XCTAssertThrowsError(try store.store(
            id: "incomplete",
            plaintext: Data("x".utf8),
            scope: incomplete
        ))
    }

    func test_storeDoesNotOverwriteExistingHandle_orEscapeStoreRoot() throws {
        let dir = try tempDir()
        let store = try openReadyStore(at: dir)
        let handle = "../../outside"
        _ = try store.store(id: handle, plaintext: Data("first".utf8), scope: scope())
        XCTAssertThrowsError(
            try store.store(id: handle, plaintext: Data("second".utf8), scope: scope())
        ) { error in
            XCTAssertEqual(error as? TokenSaverEncryptedStore.StoreError, .conflict)
        }
        XCTAssertEqual(try store.readback(id: handle, expectedScope: scope()), Data("first".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dir.deletingLastPathComponent().appendingPathComponent("outside.tsrec").path
            )
        )
    }

    func test_reopen_survivesProcessBoundary() throws {
        let dir = try tempDir()
        let raw = Data("persist-across-reopen".utf8)
        do {
            let store = try openReadyStore(at: dir)
            _ = try store.store(id: "p1", plaintext: raw, scope: scope())
        }
        // Drop first instance; reopen from encapsulated project key + meta.
        let reopened = try makeStore(at: dir)
        XCTAssertTrue(reopened.migrationComplete)
        XCTAssertEqual(try reopened.readback(id: "p1", expectedScope: scope()), raw)
        XCTAssertTrue(reopened.lossyAdmissionAllowed)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("token-saver-store/dek.bin").path
            )
        )
    }

    func test_storeless_roundTrip() {
        let raw = Data("abc\nstderr".utf8)
        XCTAssertTrue(TokenSaverEncryptedStore.Storeless.roundTrip(raw))
    }

    func test_deleteEpoch_rejectsLateOutcome() throws {
        let store = try openReadyStore(at: tempDir())
        XCTAssertTrue(store.acceptLateOutcome())
        try store.markDeleted()
        XCTAssertFalse(store.acceptLateOutcome())
        XCTAssertEqual(store.lateOutcomesRejected, 1)
    }

    func test_delete_reopen_blocksWriteAndLateOutcome() throws {
        let dir = try tempDir()
        let store = try openReadyStore(at: dir)
        _ = try store.store(id: "1", plaintext: Data("x".utf8), scope: scope())
        try store.markDeleted()
        XCTAssertThrowsError(try store.readback(id: "1", expectedScope: scope()))
        XCTAssertThrowsError(try store.store(id: "2", plaintext: Data("y".utf8), scope: scope()))

        let reopened = try makeStore(at: dir)
        XCTAssertGreaterThan(reopened.deleteEpoch, 0)
        XCTAssertFalse(reopened.lossyAdmissionAllowed)
        XCTAssertFalse(reopened.acceptLateOutcome())
        XCTAssertThrowsError(try reopened.store(id: "3", plaintext: Data("z".utf8), scope: scope()))
        // DEK must be gone
        let dek = dir.appendingPathComponent("token-saver-store/dek.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dek.path))
    }

    func test_wrongScopeExpiredRevoked_denied() throws {
        let store = try openReadyStore(at: tempDir())
        _ = try store.store(id: "1", plaintext: Data("x".utf8), scope: scope())
        let wrong = TokenSaverEncryptedStore.Scope(
            uid: 502, workspaceID: "w", projectID: "p", threadID: "t", provider: "claude", sessionGeneration: 1
        )
        XCTAssertThrowsError(try store.readback(id: "1", expectedScope: wrong))
        XCTAssertThrowsError(try store.retrieve(id: "1", scope: scope(), expired: true, revoked: false))
        XCTAssertThrowsError(try store.retrieve(id: "1", scope: scope(), expired: false, revoked: true))
    }

    func test_retentionZero_deniesLossy() throws {
        let store = try openReadyStore(at: tempDir())
        try store.setRetentionDays(0)
        XCTAssertFalse(store.lossyAdmissionAllowed)
        XCTAssertThrowsError(try store.store(id: "1", plaintext: Data("x".utf8), scope: scope()))
    }

    func test_reader_N_and_NMinus1_onDisk() throws {
        let store = try openReadyStore(at: tempDir())
        let raw = Data("legacy".utf8)
        try store.seedLegacyRecord(id: "leg", plaintext: raw, scope: scope())
        XCTAssertEqual(try store.readback(id: "leg", expectedScope: scope()), raw)
        XCTAssertTrue(TokenSaverEncryptedStore.readerSupports(formatVersion: 1))
        XCTAssertTrue(TokenSaverEncryptedStore.readerSupports(formatVersion: 2))
        XCTAssertFalse(TokenSaverEncryptedStore.readerSupports(formatVersion: 99))
    }

    func test_shadowMigration_upgradesAndCompletes() throws {
        let dir = try tempDir()
        let store = try makeStore(at: dir)
        let raw = Data("migrate-me".utf8)
        try store.seedLegacyRecord(id: "leg", plaintext: raw, scope: scope())
        XCTAssertFalse(store.migrationComplete)
        try store.runShadowMigration()
        XCTAssertTrue(store.migrationComplete)
        XCTAssertEqual(try store.readback(id: "leg", expectedScope: scope()), raw)
        // Reopen still complete + readable
        let reopened = try makeStore(at: dir)
        XCTAssertTrue(reopened.migrationComplete)
        XCTAssertEqual(try reopened.readback(id: "leg", expectedScope: scope()), raw)
    }

    func test_ciphertext_notEqual_plaintext() throws {
        let store = try openReadyStore(at: tempDir())
        let raw = Data("secret-payload".utf8)
        let env = try store.store(id: "1", plaintext: raw, scope: scope())
        XCTAssertNotEqual(env.ciphertext, raw)
    }

    func test_deleteClearsBlobs_andBlocksNewStore() throws {
        let store = try openReadyStore(at: tempDir())
        _ = try store.store(id: "1", plaintext: Data("x".utf8), scope: scope())
        try store.markDeleted()
        XCTAssertThrowsError(try store.readback(id: "1", expectedScope: scope()))
        XCTAssertThrowsError(try store.store(id: "2", plaintext: Data("y".utf8), scope: scope()))
    }

    func test_migrationIncomplete_deniesLossy() throws {
        let store = try makeStore(at: tempDir())
        XCTAssertFalse(store.lossyAdmissionAllowed)
        XCTAssertThrowsError(try store.store(id: "1", plaintext: Data("x".utf8), scope: scope()))
    }

    func test_corruptMeta_failsClosed() throws {
        let dir = try tempDir()
        _ = try openReadyStore(at: dir)
        let metaURL = dir.appendingPathComponent("token-saver-store/meta.json")
        try Data("{not-json".utf8).write(to: metaURL, options: .atomic)
        XCTAssertThrowsError(try makeStore(at: dir)) { err in
            XCTAssertEqual(err as? TokenSaverEncryptedStore.StoreError, .corruptMeta)
        }
    }

    /// Simulates crash after tombstone write but before DEK wipe: reopen must stay shredded.
    func test_tombstoneBeforeShred_reopenStaysTerminal() throws {
        let dir = try tempDir()
        let store = try openReadyStore(at: dir)
        _ = try store.store(id: "1", plaintext: Data("x".utf8), scope: scope())
        // Manually write tombstone without wiping DEK (crash mid-shred simulation).
        let metaURL = dir.appendingPathComponent("token-saver-store/meta.json")
        let tombstone = """
        {"migrationComplete":false,"deleteEpoch":1,"retentionDays":30,"lateOutcomesRejected":0,"pendingMigrationIDs":[],"shredActive":true}
        """
        try Data(tombstone.utf8).write(to: metaURL, options: .atomic)
        let reopened = try makeStore(at: dir)
        XCTAssertFalse(reopened.lossyAdmissionAllowed)
        XCTAssertThrowsError(try reopened.store(id: "2", plaintext: Data("y".utf8), scope: scope()))
    }
}
