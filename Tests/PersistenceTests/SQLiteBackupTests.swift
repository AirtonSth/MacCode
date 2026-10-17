import XCTest
@testable import Persistence

final class SQLiteBackupTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func count(_ table: String, in db: SQLiteDB) throws -> Int64 {
        let statement = try db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return statement.columnInt64(0)
    }

    func test_backupCopiesCommittedWALRowsAndLeavesReadonlySourceUnchanged() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourcePath = directory.appendingPathComponent("source.sqlite").path
        let destinationPath = directory.appendingPathComponent("destination.sqlite").path
        let source = try SQLiteDB(path: sourcePath)
        try source.execute("CREATE TABLE records (value TEXT NOT NULL);")
        try source.execute("INSERT INTO records VALUES ('committed in WAL');")
        let readonlySource = try SQLiteDB(path: sourcePath, readonly: true)
        let destination = try SQLiteDB(path: destinationPath)
        try destination.execute("CREATE TABLE records (value TEXT NOT NULL);")
        try destination.execute("INSERT INTO records VALUES ('old destination row');")

        destination.rememberEventRowCount(0)
        destination.rememberTerminalOutputBytes(0)
        try readonlySource.backup(to: destination)
        XCTAssertNil(destination.cachedEventRowCountIfKnown())
        XCTAssertTrue(destination.terminalOutputRetentionRequired(maxBytes: 1))

        XCTAssertEqual(try count("records", in: destination), 1)
        let reopened = try SQLiteDB(path: destinationPath, readonly: true)
        XCTAssertEqual(try count("records", in: reopened), 1)
        XCTAssertEqual(try count("records", in: readonlySource), 1)
        let value = try reopened.prepare("SELECT value FROM records;")
        XCTAssertTrue(try value.step())
        XCTAssertEqual(value.columnText(0), "committed in WAL")
        value.reset()
    }

    func test_backupRejectsSelfAndHardlinkWithoutChangingFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourcePath = directory.appendingPathComponent("source.sqlite").path
        let hardlinkPath = directory.appendingPathComponent("hardlink.sqlite").path
        let source = try SQLiteDB(path: sourcePath)
        try source.execute("CREATE TABLE records (value TEXT NOT NULL);")
        try source.execute("INSERT INTO records VALUES ('keep');")
        try source.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        let before = try Data(contentsOf: URL(fileURLWithPath: sourcePath))

        XCTAssertThrowsError(try source.backup(to: source))
        try FileManager.default.linkItem(atPath: sourcePath, toPath: hardlinkPath)
        let hardlink = try SQLiteDB(path: hardlinkPath, readonly: true)
        XCTAssertThrowsError(try source.backup(to: hardlink))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourcePath)), before)
        let reopened = try SQLiteDB(path: sourcePath, readonly: true)
        XCTAssertEqual(try count("records", in: reopened), 1)
    }

    func test_backupFailureOnLockedDestinationPreservesExistingRows() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourcePath = directory.appendingPathComponent("source.sqlite").path
        let destinationPath = directory.appendingPathComponent("destination.sqlite").path
        let source = try SQLiteDB(path: sourcePath)
        try source.execute("CREATE TABLE records (value TEXT NOT NULL);")
        try source.execute("INSERT INTO records VALUES ('source');")
        let destination = try SQLiteDB(path: destinationPath)
        try destination.execute("CREATE TABLE records (value TEXT NOT NULL);")
        try destination.execute("INSERT INTO records VALUES ('preserve');")
        let lock = try SQLiteDB(path: destinationPath)
        try lock.execute("BEGIN EXCLUSIVE;")
        try lock.execute("INSERT INTO records VALUES ('lock');")
        defer { try? lock.execute("ROLLBACK;") }

        XCTAssertThrowsError(try source.backup(to: destination))
        XCTAssertEqual(try count("records", in: destination), 1,
            "a failed backup must leave the committed destination content intact")
    }
}
