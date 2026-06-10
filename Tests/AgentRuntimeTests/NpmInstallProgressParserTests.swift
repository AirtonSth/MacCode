import XCTest
@testable import AgentRuntime

final class NpmInstallProgressParserTests: XCTestCase {

    // MARK: - Representative line coverage

    // WHY: the UI must show a "resolving" stage while npm resolves the dep tree,
    // not a blank spinner, so the user knows the first-turn SDK provision is working.
    func test_idealTreeLineMapsToresolvingStage() {
        let result = NpmInstallProgressParser.parse(line: "npm timing idealTreeBuildDeps:loadExisting Completed in 120ms")
        XCTAssertNotNil(result, "idealTree timing lines must produce a progress event")
        XCTAssertEqual(result?.stage, "resolving")
    }

    // WHY: network fetch lines show the SDK is being downloaded from the registry.
    func test_httpFetchLineMapsToFetchingStage() {
        let result = NpmInstallProgressParser.parse(line: "npm http fetch GET 200 https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk 1234ms")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.stage, "fetching")
    }

    // WHY: reify timing is the install-to-disk phase; UI must label it "installing".
    func test_reifyLineMapsToInstallingStage() {
        let result = NpmInstallProgressParser.parse(line: "npm timing reifyNode:/node_modules/@anthropic-ai/claude-agent-sdk Completed in 340ms")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.stage, "installing")
    }

    // WHY: "added N packages" is the npm completion summary; parser must detect it
    // as the terminal stage so the UI can close the provisioning banner.
    func test_addedPackagesLineMapsToCompleteStage() {
        let result = NpmInstallProgressParser.parse(line: "added 42 packages in 3s")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.stage, "complete")
        XCTAssertEqual(result!.progress, 1.0, accuracy: 0.001)
    }

    // WHY: "added 1 package" (singular) is also a valid completion line.
    func test_addedOnePackageLineMapsToCompleteStage() {
        let result = NpmInstallProgressParser.parse(line: "added 1 package in 1s")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.stage, "complete")
    }

    // WHY: non-progress lines (warnings, blank lines, unrecognised output) must be
    // ignored so the parser does not emit spurious events for every stderr line.
    func test_warnLineIsIgnored() {
        let result = NpmInstallProgressParser.parse(line: "npm warn deprecated inflight@1.0.6: This module is not supported, and leaks memory.")
        XCTAssertNil(result, "npm warn lines are noise and must not produce a progress event")
    }

    func test_emptyLineIsIgnored() {
        XCTAssertNil(NpmInstallProgressParser.parse(line: ""))
        XCTAssertNil(NpmInstallProgressParser.parse(line: "   "))
    }

    func test_unrelatedTextLineIsIgnored() {
        XCTAssertNil(NpmInstallProgressParser.parse(line: "some random unrecognised npm output"))
    }

    // MARK: - Progress monotonicity

    // WHY: stages must map to monotonically increasing progress values so the UI
    // progress bar never moves backwards when multiple stage lines arrive.
    func test_stagesHaveMonotonicallyIncreasingProgress() {
        let stages = ["resolving", "fetching", "installing", "complete"]
        let progresses: [Double] = stages.compactMap { stage -> Double? in
            let lines: [String: String] = [
                "resolving": "npm timing idealTreeBuildDeps Completed in 50ms",
                "fetching": "npm http fetch GET 200 https://registry.npmjs.org/foo 10ms",
                "installing": "npm timing reifyNode:/node_modules/foo Completed in 10ms",
                "complete": "added 5 packages in 1s"
            ]
            guard let line = lines[stage], let r = NpmInstallProgressParser.parse(line: line) else { return nil }
            return r.progress
        }
        XCTAssertEqual(progresses.count, 4, "all four representative stage lines must produce a progress result")
        for i in 1 ..< progresses.count {
            XCTAssertGreaterThan(progresses[i], progresses[i - 1],
                                 "stage \(stages[i]) progress must exceed \(stages[i-1]) progress — UI bar must not move backwards")
        }
    }

    // MARK: - Progress range

    // WHY: progress value must be in [0, 1] so the UI can pass it directly to a
    // ProgressView fraction without clamping.
    func test_progressValuesAreInUnitInterval() {
        let testLines = [
            "npm timing idealTreeBuildDeps Completed in 50ms",
            "npm http fetch GET 200 https://registry.npmjs.org/foo 10ms",
            "npm timing reifyNode:/node_modules/foo Completed in 10ms",
            "added 5 packages in 1s"
        ]
        for line in testLines {
            if let result = NpmInstallProgressParser.parse(line: line) {
                XCTAssertGreaterThanOrEqual(result.progress, 0.0, "progress for \"\(line)\" must be >= 0")
                XCTAssertLessThanOrEqual(result.progress, 1.0, "progress for \"\(line)\" must be <= 1")
            }
        }
    }
}
