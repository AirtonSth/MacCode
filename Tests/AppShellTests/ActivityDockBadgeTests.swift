import XCTest
@testable import AppShell

@MainActor
final class ActivityDockBadgeTests: XCTestCase {
    func test_dockBadgeShowsTheNeedsYouCountCappedAt99Plus() {
        // WHY: the owner wants the Dock icon to carry the same red count as the
        // pet's dot, capped at 99+, and no badge when nothing needs them.
        XCTAssertEqual(ActivityDockBadge.label(for: PetActivityCounts(running: 4, needsYou: 3, newResults: 9)), "3",
                       "only Needs you drives the badge, not running or new results")
        XCTAssertEqual(ActivityDockBadge.label(for: PetActivityCounts(running: 0, needsYou: 99, newResults: 0)), "99")
        XCTAssertEqual(ActivityDockBadge.label(for: PetActivityCounts(running: 0, needsYou: 1_393, newResults: 0)), "99+")
        XCTAssertNil(ActivityDockBadge.label(for: PetActivityCounts(running: 2, needsYou: 0, newResults: 5)))
        XCTAssertNil(ActivityDockBadge.label(for: PetActivityCounts(running: 0, needsYou: 7, newResults: 0, isAvailable: false)),
                     "unknown counts must not show a number as if it were current")
    }

    func test_startPaintsTheCurrentCountAndStopClearsTheBadge() {
        var applied: [String?] = []
        let badge = ActivityDockBadge(projection: PetActivityCountsProjection(), apply: { applied.append($0) })
        badge.start()
        badge.start()
        XCTAssertEqual(applied, [nil], "the first paint mirrors the projection once; a second start adds no observer")
        badge.stop()
        XCTAssertEqual(applied, [nil], "an unchanged label is not rewritten to the Dock")
    }

    func test_appDelegateStartsTheDockBadgeAtLaunch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let delegate = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/AppDelegate.swift"), encoding: .utf8)
        let pet = try XCTUnwrap(delegate.range(of: "        startPetController()\n"))
        XCTAssertTrue(delegate[pet.upperBound...].hasPrefix("        activityDockBadge.start()"),
                      "started with the pet at launch, whether or not the pet is enabled")
    }
}
