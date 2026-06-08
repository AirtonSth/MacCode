import XCTest
@testable import AgentRuntime

final class SessionLearnRegionTests: XCTestCase {
    private func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-learn-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("AGENTS.md")
    }

    func test_appendAndReadRules() throws {
        let region = SessionLearnRegion(fileURL: tempFile())
        try region.append("Do not run the full build to check a one-line change; build the target.")
        try region.append("Prefer `swift test --filter` over the whole suite while iterating.")
        XCTAssertEqual(try region.rules().count, 2)
        XCTAssertTrue(try region.rules().contains("Prefer `swift test --filter` over the whole suite while iterating."))
    }

    func test_dedupIdenticalRule() throws {
        let region = SessionLearnRegion(fileURL: tempFile())
        try region.append("Same rule.")
        try region.append("Same rule.")
        XCTAssertEqual(try region.rules(), ["Same rule."])
    }

    func test_fifoCapEvictsOldest() throws {
        let region = SessionLearnRegion(fileURL: tempFile(), maxRules: 3)
        for i in 1...5 { try region.append("rule \(i)") }
        XCTAssertEqual(try region.rules(), ["rule 3", "rule 4", "rule 5"], "FIFO keeps the newest maxRules")
    }

    func test_upperFilePrefixStaysByteStable() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preamble = "# AGENTS\n\nUser-authored guidance the writer must never disturb.\n"
        try Data(preamble.utf8).write(to: url)

        let region = SessionLearnRegion(fileURL: url)
        try region.append("learned correction one")
        try region.append("learned correction two")

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(preamble), "the user-authored prefix above the region is byte-stable (cache-cold append)")
        XCTAssertTrue(text.contains(SessionLearnRegion.beginMarker))
        XCTAssertTrue(text.contains(SessionLearnRegion.endMarker))
    }

    func test_clearRemovesRegionButKeepsUserContent() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preamble = "# AGENTS\n\nUser content.\n"
        try Data(preamble.utf8).write(to: url)
        let region = SessionLearnRegion(fileURL: url)
        try region.append("a learned rule")

        try region.clear()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("User content."), "user-authored content survives clear")
        XCTAssertFalse(text.contains(SessionLearnRegion.beginMarker), "managed region removed")
        XCTAssertEqual(try region.rules(), [])
    }

    func test_shouldMinePreFilter() {
        XCTAssertTrue(SessionLearnRegion.shouldMine(runFailed: true, inputTokens: 10), "failed runs are mined")
        XCTAssertTrue(SessionLearnRegion.shouldMine(runFailed: false, inputTokens: 80_000), "expensive runs are mined")
        XCTAssertFalse(SessionLearnRegion.shouldMine(runFailed: false, inputTokens: 1_000), "routine cheap successes are not mined")
    }
}
