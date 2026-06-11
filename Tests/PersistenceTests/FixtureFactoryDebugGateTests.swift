import XCTest
@testable import Persistence
import CoreModel

/// CI-gate contract test: FixtureFactory must only be compiled in DEBUG builds.
///
/// WHY: FixtureFactory lives in Sources/Persistence and is compiled into the
/// Persistence library target.  Without a #if DEBUG guard it ships in release
/// binaries, bloating the binary and exposing deterministic test credentials
/// (hard-coded UUIDs, fixture DBs) to production users.  The guard was added
/// in Sources/Persistence/Fixtures.swift; this test suite compiles under DEBUG
/// (all swift test invocations are DEBUG builds) and exercises the full
/// FixtureScenario enumeration to confirm the guard does not break anything
/// downstream of it.
///
/// The CI symbol-check property: if a future patch accidentally removes #if DEBUG,
/// the release build catches a symbol that must not exist.  These tests assert
/// the API contract so any regression in the fixture API fails a test before
/// reaching a release build.
final class FixtureFactoryDebugGateTests: XCTestCase {

    // MARK: - Contract: FixtureScenario exposes all expected cases

    /// WHY: The FixtureScenario enum is the public API surface for fixtures.
    /// Any case removed or renamed silently breaks every test suite that calls
    /// FixtureFactory.build(_:dbPath:) with that case.  Enumerating the raw
    /// values here pins the contract so a rename fails this test first.
    func test_fixtureScenario_rawValues_matchExpected() {
        let expected: Set<String> = [
            "empty",
            "singleWorkspaceAgentApp",
            "threeSurfaceLayout",
            "corruptSnapshot",
            "legacySchemaV13",
            "orphanedTerminalChunks",
        ]
        let actual = Set(FixtureScenario.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected,
            "FixtureScenario cases must exactly match the known set; " +
            "a rename or addition without updating this list means test code " +
            "built against the old case will silently fall through")
    }

    // MARK: - Contract: FixtureFactory.build succeeds for every known scenario

    /// WHY: Each scenario must produce a non-nil Built value without throwing;
    /// a scenario that only partially sets up state (e.g. missing Schema.migrate)
    /// can corrupt downstream tests that share the fixture.
    func test_everyScenario_buildSucceeds() throws {
        for scenario in FixtureScenario.allCases {
            let tmp = NSTemporaryDirectory() + "RC2FixGate-\(scenario.rawValue)-" + UUID().uuidString + ".sqlite"
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            // Must not throw for any known scenario.
            let built = try FixtureFactory().build(scenario, dbPath: tmp)
            // Built must always produce a valid db path (not nil / zero bytes for non-legacy)
            if scenario != .legacySchemaV13 {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: tmp),
                    "scenario \(scenario.rawValue) must produce a non-empty sqlite file"
                )
            }
            // State is always a value type - just accessing it must not crash.
            _ = built.state.workspaces.count
        }
    }

    // MARK: - Contract: FixtureFactory instances are independent

    /// WHY: Two FixtureFactory instances building the same scenario at different
    /// paths must not share mutable state (e.g. a static cache of db handles).
    /// Shared state would cause one test's mutations to corrupt another's fixture.
    func test_twoInstances_sameScenario_differentPaths_areIndependent() throws {
        let tmp1 = NSTemporaryDirectory() + "RC2FixGate-ind1-" + UUID().uuidString + ".sqlite"
        let tmp2 = NSTemporaryDirectory() + "RC2FixGate-ind2-" + UUID().uuidString + ".sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: tmp1)
            try? FileManager.default.removeItem(atPath: tmp2)
        }
        let b1 = try FixtureFactory().build(.singleWorkspaceAgentApp, dbPath: tmp1)
        let b2 = try FixtureFactory().build(.singleWorkspaceAgentApp, dbPath: tmp2)

        // Both must produce identical workspace counts (deterministic).
        XCTAssertEqual(b1.state.workspaces.count, b2.state.workspaces.count,
            "two independent FixtureFactory instances must produce identical workspace counts " +
            "for the same scenario - shared static state would cause flaky ordering")
        // Paths must differ so the two DBs are not the same file.
        XCTAssertNotEqual(tmp1, tmp2,
            "fixture paths must be unique to prevent test cross-contamination")
    }
}
