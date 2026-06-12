import XCTest
import CoreModel
@testable import SocketServer

/// Tests for QA-002: injectable clock in FileEditSessionStore.
///
/// WHY per assertion:
///  - open() captures session.openedAt via the injected clock so future TTL/expiry
///    paths can be tested deterministically without sleep.
///  - The openedAt is returned in the session payload (opened_at field) so callers
///    (iOS, tests) can reason about session age without querying the real clock.
///  - setClockForTests must freeze the openedAt so multiple sessions opened in the
///    same test share a known reference time.
final class FileEditSessionStoreClockTests: XCTestCase {

    private var root: URL!
    private var store: FileEditSessionStore!
    private let surface = SurfaceID()
    private let workspace = WorkspaceID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc2-editsession-clk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = FileEditSessionStore()
        store.resetForTests()
    }

    override func tearDownWithError() throws {
        store.resetForTests()
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Helpers

    /// Write a small UTF-8 text file inside root and return its relative path.
    private func makeFile(name: String, content: String = "hello") throws -> String {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return name
    }

    // MARK: - Default clock: openedAt is near wall time

    /// WHY: in production openedAt must capture the real wall time so TTL
    /// comparisons (e.g. "session is older than 1 hour") are meaningful.
    func test_defaultClock_openedAtIsNearWallTime() throws {
        let path = try makeFile(name: "default-clock.txt")
        let before = Date()
        let payload = try store.open(surfaceID: surface, workspaceID: workspace,
                                     root: root.path, path: path)
        let after = Date()

        guard case .number(let ts) = payload.objectValue?["opened_at"] else {
            return XCTFail("session payload must include opened_at as a number")
        }
        let openedAt = Date(timeIntervalSince1970: ts)
        XCTAssertGreaterThanOrEqual(openedAt, before,
            "openedAt must not precede the open() call (real clock)")
        XCTAssertLessThanOrEqual(openedAt, after,
            "openedAt must not follow the open() call (real clock)")
    }

    // MARK: - Frozen clock: openedAt equals injected value

    /// WHY: future session-TTL logic (e.g. close sessions older than 1 h) will
    /// compare openedAt to a current timestamp. Injecting a frozen clock gives
    /// tests exact control over that comparison without real time passing.
    func test_frozenClock_openedAtEqualsFrozenTime() throws {
        let frozen = Date(timeIntervalSince1970: 500_000)
        store.setClockForTests { frozen }

        let path = try makeFile(name: "frozen-clock.txt")
        let payload = try store.open(surfaceID: surface, workspaceID: workspace,
                                     root: root.path, path: path)

        guard case .number(let ts) = payload.objectValue?["opened_at"] else {
            return XCTFail("session payload must include opened_at as a number")
        }
        XCTAssertEqual(ts, 500_000,
            "openedAt must equal the frozen clock value so TTL assertions are deterministic")
    }

    // MARK: - Multiple sessions share same frozen openedAt

    /// WHY: if the clock is frozen, two sessions opened in the same test must
    /// have identical openedAt values. This confirms the clock is read per-open,
    /// not once at store construction — which is what TTL logic requires.
    func test_frozenClock_twoSessions_shareOpenedAt() throws {
        let frozen = Date(timeIntervalSince1970: 999_999)
        store.setClockForTests { frozen }

        let pathA = try makeFile(name: "frozen-a.txt", content: "alpha")
        let pathB = try makeFile(name: "frozen-b.txt", content: "beta")
        let payloadA = try store.open(surfaceID: surface, workspaceID: workspace,
                                      root: root.path, path: pathA)
        let payloadB = try store.open(surfaceID: surface, workspaceID: workspace,
                                      root: root.path, path: pathB)

        guard case .number(let tsA) = payloadA.objectValue?["opened_at"],
              case .number(let tsB) = payloadB.objectValue?["opened_at"] else {
            return XCTFail("both session payloads must include opened_at as a number")
        }
        XCTAssertEqual(tsA, tsB,
            "two sessions opened with the same frozen clock must have the same openedAt (TTL batching must not diverge)")
    }

    // MARK: - Advancing clock: later sessions have later openedAt

    /// WHY: when simulating elapsed time between opens (e.g. a long editing session
    /// followed by a new open), an advancing clock must produce strictly increasing
    /// openedAt values so age-based expiry sorts correctly.
    func test_advancingClock_laterSessionHasLaterOpenedAt() throws {
        var tick: TimeInterval = 100
        store.setClockForTests {
            let t = tick
            tick += 500
            return Date(timeIntervalSince1970: t)
        }

        let pathA = try makeFile(name: "adv-a.txt", content: "first")
        let pathB = try makeFile(name: "adv-b.txt", content: "second")
        let payloadA = try store.open(surfaceID: surface, workspaceID: workspace,
                                      root: root.path, path: pathA)
        let payloadB = try store.open(surfaceID: surface, workspaceID: workspace,
                                      root: root.path, path: pathB)

        guard case .number(let tsA) = payloadA.objectValue?["opened_at"],
              case .number(let tsB) = payloadB.objectValue?["opened_at"] else {
            return XCTFail("both session payloads must include opened_at as a number")
        }
        XCTAssertGreaterThan(tsB, tsA,
            "second session must have a later openedAt when the advancing clock increments between opens")
    }

    // MARK: - resetForTests clears clock back to real Date

    /// WHY: tests that leave a frozen clock behind would contaminate later tests
    /// that expect real timestamps. resetForTests must restore the real clock.
    func test_resetForTests_restoresRealClock() throws {
        store.setClockForTests { Date(timeIntervalSince1970: 0) }
        store.resetForTests()

        let path = try makeFile(name: "reset-clock.txt")
        let before = Date()
        let payload = try store.open(surfaceID: surface, workspaceID: workspace,
                                     root: root.path, path: path)
        let after = Date()

        guard case .number(let ts) = payload.objectValue?["opened_at"] else {
            return XCTFail("session payload must include opened_at as a number after resetForTests")
        }
        let openedAt = Date(timeIntervalSince1970: ts)
        XCTAssertGreaterThanOrEqual(openedAt, before,
            "after resetForTests the clock must be restored to real wall time")
        XCTAssertLessThanOrEqual(openedAt, after,
            "after resetForTests the clock must be restored to real wall time")
    }
}
