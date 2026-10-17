import Darwin
import Foundation
import XCTest
@testable import AppShell
@testable import Persistence

/// Drives the packaged host binary: orphan quarantine is an explicit trailing opt-in of
/// `--restore-database-backup`, never a default and never accepted by other operations.
final class HostRestoreQuarantineCLITests: XCTestCase {
    private struct Fixture {
        let root: URL
        let support: URL
        let database: URL
        let backup: URL
    }

    private let thread = "11111111-1111-4111-8111-111111111111"
    private let lostThread = "22222222-2222-4222-8222-222222222222"

    private func binary() throws -> String {
        guard let binary = ProcessInfo.processInfo.environment["RC_HOST_MATRIX_BINARY"], FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("RC_HOST_MATRIX_BINARY must name packaged host binary")
        }
        return binary
    }

    private func fixture() throws -> Fixture {
        let probe = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"], "RC_CONTEXT_PROBE_ROOT must name invocation-owned scratch"), isDirectory: true)
        let root = probe.appendingPathComponent("HostRestoreQuarantine-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = root.appendingPathComponent("current.sqlite")
        try Schema.migrate(SQLiteDB(path: database.path))
        let source = try SQLiteDB(path: root.appendingPathComponent("source.sqlite").path)
        try Schema.migrate(source)
        try source.execute("""
            INSERT INTO agent_threads(id,title,provider,model,status,created_at,updated_at) VALUES('\(thread)','kept','distill','test','completed','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
            INSERT INTO agent_messages(id,thread_id,role,content,created_at) VALUES('m-kept','\(thread)','user','hello','2026-01-01T00:00:00Z');
            PRAGMA foreign_keys=OFF;
            INSERT INTO agent_messages(id,thread_id,role,content,created_at) VALUES('m-orphan','\(lostThread)','user','lost parent','2026-01-01T00:00:00Z');
            """)
        let backup = root.appendingPathComponent("backup.sqlite")
        try source.backup(to: SQLiteDB(path: backup.path))
        return Fixture(root: root, support: support, database: database, backup: backup)
    }

    private func run(_ arguments: [String], _ f: Fixture) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try binary())
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["RC2_APP_SUPPORT"] = f.support.path
        environment["RC2_DB_PATH"] = f.database.path
        environment["RC2_CHANNEL"] = "debug"
        environment["RC2_DISABLE_MANAGED_DISTILL_RECONCILE"] = "1"
        process.environment = environment
        let outURL = f.root.appendingPathComponent("stdout-\(UUID().uuidString)")
        let errURL = f.root.appendingPathComponent("stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try out.close()
        try err.close()
        return (process.terminationStatus, try String(contentsOf: outURL, encoding: .utf8), try String(contentsOf: errURL, encoding: .utf8))
    }

    private func count(_ url: URL, _ table: String) throws -> Int64 {
        let db = try SQLiteDB(path: url.path)
        let statement = try db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { statement.reset() }
        XCTAssertTrue(try statement.step())
        return statement.columnInt64(0)
    }

    func testRestoreRefusesOrphansWithoutTheFlagAndChangesNothing() throws {
        _ = try binary()
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try Data(contentsOf: f.database)
        let result = try run(["--restore-database-backup", f.backup.path], f)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.err.contains("foreign key check failed"), result.err)
        XCTAssertTrue(result.err.contains("agent_messages=1"), result.err)
        XCTAssertEqual(try Data(contentsOf: f.database), before, "refused restore must not alter the database")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.root.path).filter { $0.hasPrefix(".restore-") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testRestoreWithTheFlagKeepsEveryOrphanInTheReportedQuarantine() throws {
        _ = try binary()
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let result = try run(["--restore-database-backup", f.backup.path, "--quarantine-orphans"], f)
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertEqual(try count(f.database, "agent_messages"), 1, "only the message with a parent stays")
        let line = try XCTUnwrap(result.out.split(separator: "\n").first { $0.hasPrefix("Orphan rows were saved aside in: ") }, result.out)
        let quarantine = URL(fileURLWithPath: String(line.dropFirst("Orphan rows were saved aside in: ".count)))
        XCTAssertEqual(try count(quarantine, "agent_messages"), 1, "the orphan must be saved, not dropped")
        XCTAssertTrue(result.out.contains("Recovery backup: "), result.out)
    }

    func testFlagIsOnlyAcceptedAsTheLastArgumentOfRestore() throws {
        _ = try binary()
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try Data(contentsOf: f.database)
        for arguments in [["--inspect-database-backup", f.backup.path, "--quarantine-orphans"],
                          ["--create-database-backup", f.root.appendingPathComponent("new.sqlite").path, "--quarantine-orphans"],
                          ["--restore-database-backup", "--quarantine-orphans", f.backup.path],
                          ["--restore-database-backup", f.backup.path, "--quarantine-orphans", "--quarantine-orphans"]] {
            let result = try run(arguments, f)
            XCTAssertNotEqual(result.status, 0, "\(arguments)")
        }
        XCTAssertEqual(try Data(contentsOf: f.database), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new.sqlite").path))
    }
}
