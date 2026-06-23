import XCTest
@testable import AgentRuntime

final class ProjectScriptsTests: XCTestCase {
    private func tmp() -> String {
        let d = NSTemporaryDirectory() + "rc2-ps-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    func test_emptyDir_yieldsNothing() {
        let d = tmp(); defer { try? FileManager.default.removeItem(atPath: d) }
        XCTAssertTrue(ProjectScripts.discover(in: d).isEmpty)
    }

    func test_packageJson_scriptsBecomeNpmRunSortedByName() throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(atPath: d) }
        try #"{"scripts":{"test":"vitest","build":"tsc"}}"#
            .write(toFile: d + "/package.json", atomically: true, encoding: .utf8)
        let s = ProjectScripts.discover(in: d)
        XCTAssertEqual(s.map(\.name), ["build", "test"], "scripts must be name-sorted, deterministic")
        XCTAssertEqual(s.first?.command, "npm run build")
        XCTAssertEqual(s.first?.source, "package.json")
    }

    func test_makefile_realTargetsOnly() throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(atPath: d) }
        try """
        # a comment
        .PHONY: build test
        build:
        \tswift build
        test:
        \tswift test
        """.write(toFile: d + "/Makefile", atomically: true, encoding: .utf8)
        let names = Set(ProjectScripts.discover(in: d).map(\.name))
        XCTAssertTrue(names.contains("build") && names.contains("test"),
                      "real targets must be discovered")
        XCTAssertFalse(names.contains(".PHONY"), "directives must not be treated as targets")
        XCTAssertFalse(names.contains("# a comment"), "comments must be ignored")
    }

    func test_swiftPM_yieldsBuildAndTest() {
        let d = tmp(); defer { try? FileManager.default.removeItem(atPath: d) }
        FileManager.default.createFile(atPath: d + "/Package.swift", contents: Data("// swift-tools".utf8))
        let s = ProjectScripts.discover(in: d)
        XCTAssertEqual(Set(s.map(\.name)), ["build", "test"])
        XCTAssertEqual(s.first { $0.name == "test" }?.command, "swift test")
        XCTAssertEqual(s.first?.source, "Package.swift")
    }

    func test_openInEditor_missingWorkspaceFailsLoudInsteadOfReportingFinder() {
        let missing = NSTemporaryDirectory() + "rc2-ps-missing-" + UUID().uuidString
        XCTAssertThrowsError(try ProjectScripts.openInEditor(cwd: missing, preferred: []),
                             "a deleted workspace path must not be reported as successfully opened in Finder")
    }
}
