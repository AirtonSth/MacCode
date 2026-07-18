import XCTest
@testable import Persistence

final class TerminalOutputUTF8BoundaryTests: XCTestCase {
    func test_duplicateChunkIndexThrowsAndPreservesOriginalRow() throws {
        // WHY: INSERT OR IGNORE reports a successful append while dropping the
        // replacement bytes. History cursors then advance across a silent hole.
        let directory = NSTemporaryDirectory() + "RC2TerminalStrictInsert-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: directory).run()
        let repo = TerminalOutputRepository(db: db)
        let surfaceID = "terminal-strict-duplicate"
        let original = Data("ORIGINAL_HISTORY\n".utf8)
        let duplicate = Data("SILENTLY_DROPPED_BEFORE_FIX\n".utf8)
        try repo.append(
            surfaceID: surfaceID,
            workspaceID: nil,
            chunkIndex: 1,
            data: original
        )

        XCTAssertThrowsError(
            try repo.append(
                surfaceID: surfaceID,
                workspaceID: nil,
                chunkIndex: 1,
                data: duplicate
            )
        )
        let window = try repo.readWindow(surfaceID: surfaceID)
        XCTAssertEqual(window.chunks.count, 1)
        XCTAssertEqual(window.chunks.first?.data, original)
        XCTAssertFalse(window.text.contains("SILENTLY_DROPPED_BEFORE_FIX"))
    }

    func test_readWindowTextDecodesUTF8AfterJoiningPersistenceChunks() throws {
        // WHY: PTY history flush boundaries are byte-based. Splitting one scalar
        // across two rows must not corrupt restored terminal text with U+FFFD.
        let directory = NSTemporaryDirectory() + "RC2TerminalUTF8-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: directory).run()
        let repo = TerminalOutputRepository(db: db)
        let surfaceID = "terminal-utf8-boundary"
        let expected = Data("before 🙂 after".utf8)
        let split = Data("before ".utf8).count + 2

        try repo.append(
            surfaceID: surfaceID,
            workspaceID: nil,
            chunkIndex: 1,
            data: expected.prefix(split)
        )
        try repo.append(
            surfaceID: surfaceID,
            workspaceID: nil,
            chunkIndex: 2,
            data: expected.dropFirst(split)
        )

        let window = try repo.readWindow(surfaceID: surfaceID)

        XCTAssertEqual(
            window.text,
            "before 🙂 after",
            "terminal history must concatenate raw bytes before UTF-8 decoding so arbitrary persistence boundaries cannot corrupt restored output"
        )
    }
}
