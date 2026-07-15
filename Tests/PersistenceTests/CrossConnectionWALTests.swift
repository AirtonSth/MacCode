import XCTest
@testable import Persistence
import CoreModel

/// QA-mac:50 -- the app + the Token Saver sidecar open the SAME sqlite file as two
/// independent connections (documented at SQLite.swift:45-49 and
/// ReversibleContentStore.swift:10-13), but nothing exercised that two-connection
/// contract. These tests open two SQLiteDB connections on one WAL file -- the same
/// cross-connection mechanism the two-process case relies on -- and assert
/// busy_timeout serialization, totals consistency, and CCR store visibility across
/// connections.
final class CrossConnectionWALTests: XCTestCase {

    private func makeFilePath() -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2WAL-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shared.sqlite").path
    }

    func test_writesOnOneConnectionAreVisibleToTheOther() throws {
        let path = makeFilePath()
        let connA = try SQLiteDB(path: path)
        try Schema.migrate(connA)
        let connB = try SQLiteDB(path: path)   // second connection on the same WAL file

        let writeRepo = NotificationRepository(db: connA)
        let readRepo = NotificationRepository(db: connB)

        for i in 0..<25 {
            try writeRepo.insert(AppNotification(id: "x-\(i)", title: "t\(i)", category: "wal"))
        }

        // WAL: connection B must see every committed row from connection A -- this is
        // the app<->sidecar totals-consistency contract.
        XCTAssertEqual(try readRepo.list(limit: 100).count, 25,
            "a second connection on the same WAL file must see all rows committed by the first (cross-connection visibility)")
    }

    func test_concurrentWritersOnTwoConnectionsAllSucceed_busyTimeoutSerializes() throws {
        let path = makeFilePath()
        let connA = try SQLiteDB(path: path)
        try Schema.migrate(connA)
        let connB = try SQLiteDB(path: path)

        let repoA = NotificationRepository(db: connA)
        let repoB = NotificationRepository(db: connB)
        let lock = NSLock()
        var failures = 0

        // Two connections writing at once. WAL allows one writer at a time; the
        // 5s busy_timeout (SQLite.swift) must make the loser WAIT rather than fail
        // with SQLITE_BUSY, so every insert lands.
        let group = DispatchGroup()
        for (tag, repo) in [("a", repoA), ("b", repoB)] {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<60 {
                    do { try repo.insert(AppNotification(id: "\(tag)-\(i)", title: "t", category: "wal")) }
                    catch { lock.lock(); failures += 1; lock.unlock() }
                }
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(failures, 0,
            "busy_timeout must serialize cross-connection writers so no insert fails with SQLITE_BUSY")
        // Both writers' rows are present, seen from either connection.
        XCTAssertEqual(try repoA.list(limit: 500).count, 120,
            "all 120 rows from both connections must persist and be visible")
    }

    func test_validDeviceAuthorizationSurvivesCachedReadAndSidecarCommit() throws {
        let path = makeFilePath()
        let appConnection = try SQLiteDB(path: path)
        try Schema.migrate(appConnection)
        let sidecarConnection = try SQLiteDB(path: path)
        let trustRepository = DeviceTrustRepository(db: appConnection)
        let pairingCode = try trustRepository.createPairingCode()
        let pairedDevice = try XCTUnwrap(
            trustRepository.redeemPairingCode(pairingCode.code, deviceName: "Test iPhone")
        )

        try appConnection.performSync { db in
            let statement = try db.prepare("SELECT MAX(version) FROM schema_meta;")
            XCTAssertTrue(try statement.step())
            XCTAssertGreaterThan(statement.columnInt64(0), 0)
        }

        try NotificationRepository(db: sidecarConnection).insert(
            AppNotification(id: "sidecar-auth-write", title: "Token Saver", category: "wal")
        )

        let verifiedDevice = try trustRepository.verify(
            token: pairedDevice.token,
            threshold: 0,
            now: Date().addingTimeInterval(1)
        )

        XCTAssertEqual(verifiedDevice?.id, pairedDevice.0.id,
            "a valid iPhone token must not become unauthorized after a sidecar commit")
    }

    func test_pairingWriteSucceedsAfterCachedReadAndSidecarCommit() throws {
        let path = makeFilePath()
        let appConnection = try SQLiteDB(path: path)
        try Schema.migrate(appConnection)
        let sidecarConnection = try SQLiteDB(path: path)

        try appConnection.performSync { db in
            let statement = try db.prepare("SELECT MAX(version) FROM schema_meta;")
            XCTAssertTrue(try statement.step())
            XCTAssertGreaterThan(statement.columnInt64(0), 0)
            // Intentionally stop after the first row. `performSync` owns the
            // lifecycle of this cached statement and must release its WAL read
            // snapshot before another connection commits.
        }

        try NotificationRepository(db: sidecarConnection).insert(
            AppNotification(id: "sidecar-write", title: "Token Saver", category: "wal")
        )

        let pairing = try DeviceTrustRepository(db: appConnection)
            .createPairingRequest(deviceName: "Test iPhone", clientDeviceID: "ios-test-device")

        XCTAssertEqual(pairing.deviceName, "Test iPhone",
            "a sidecar commit after an early cached read must not lock the Mac pairing INSERT")
    }

    func test_pairingWriteSucceedsWhenCachedReadOperationThrowsBeforeSidecarCommit() throws {
        struct IntentionalStop: Error {}

        let path = makeFilePath()
        let appConnection = try SQLiteDB(path: path)
        try Schema.migrate(appConnection)
        let sidecarConnection = try SQLiteDB(path: path)

        XCTAssertThrowsError(try appConnection.performSync { db in
            let statement = try db.prepare("SELECT MAX(version) FROM schema_meta;")
            XCTAssertTrue(try statement.step())
            throw IntentionalStop()
        }) { error in
            XCTAssertTrue(error is IntentionalStop)
        }

        try NotificationRepository(db: sidecarConnection).insert(
            AppNotification(id: "sidecar-write-after-error", title: "Token Saver", category: "wal")
        )

        let pairing = try DeviceTrustRepository(db: appConnection)
            .createPairingRequest(deviceName: "Test iPhone")

        XCTAssertEqual(pairing.deviceName, "Test iPhone",
            "an interrupted cached read must release its snapshot before pairing resumes")
    }

    func test_reversibleContentStoreVisibleAcrossConnections() throws {
        let path = makeFilePath()
        let connA = try SQLiteDB(path: path)
        try Schema.migrate(connA)
        let connB = try SQLiteDB(path: path)

        // The sidecar stores a CCR original on one connection; the app must retrieve
        // it byte-for-byte on the other (the [[rc:handle]] retrieve contract).
        let writer = ReversibleContentStore(db: connA)
        let reader = ReversibleContentStore(db: connB)

        let original = String(repeating: "exact bytes the app must recover ", count: 50)
        let handle = try writer.store(original)

        XCTAssertEqual(try reader.retrieveText(handle), original,
            "a CCR original stored by one connection must be retrievable byte-for-byte by the other (app<->sidecar visibility)")
        XCTAssertEqual(try reader.retrieveText(ReversibleContentStore.marker(for: handle)), original,
            "retrieval via the [[rc:handle]] marker must also cross the connection boundary")
    }
}
