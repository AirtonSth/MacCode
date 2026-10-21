import XCTest
@testable import AppShell

@MainActor
final class ActivityDockBadgeTests: XCTestCase {
    func test_dockBadgeAddsNeedsYouAndJustFinishedCappedAt99Plus() {
        // WHY: the Dock badge is the total of work waiting on the owner: items that need
        // them plus results that finished and were not opened yet. Running work is not counted.
        XCTAssertEqual(ActivityDockBadge.label(for: PetActivityCounts(running: 9, needsYou: 2, newResults: 4)), "6")
        XCTAssertEqual(ActivityDockBadge.label(for: PetActivityCounts(running: 0, needsYou: 0, newResults: 4)), "4")
        XCTAssertEqual(ActivityDockBadge.label(for: PetActivityCounts(running: 0, needsYou: 60, newResults: 50)), "99+")
        XCTAssertEqual(ActivityDockBadge.label(for: PetActivityCounts(running: 0, needsYou: 99, newResults: 0)), "99")
        XCTAssertEqual(ActivityDockBadge.label(for: PetActivityCounts(running: 0, needsYou: 1_393, newResults: 0)), "99+")
        XCTAssertNil(ActivityDockBadge.label(for: PetActivityCounts(running: 2, needsYou: 0, newResults: 0)))
        XCTAssertNil(ActivityDockBadge.label(for: PetActivityCounts(running: 0, needsYou: 7, newResults: 0, isAvailable: false)),
                     "unknown counts must not show a number as if it were current")
    }

    func test_viewingAJustFinishedResultLowersTheBadge() {
        // WHY: opening a finished result clears it from the Dock count right away, so the
        // number always matches what is still unread.
        let before = PetActivityCounts(running: 0, needsYou: 2, newResults: 4)
        let after = PetActivityCounts(running: 0, needsYou: 2, newResults: 3)
        XCTAssertEqual(ActivityDockBadge.label(for: before), "6")
        XCTAssertEqual(ActivityDockBadge.label(for: after), "5")
    }

    func test_badgeTotalSaturatesInsteadOfOverflowing() {
        // WHY: a corrupt or huge count must not trap the app while computing the badge.
        XCTAssertEqual(PetActivityCounts(running: 0, needsYou: Int.max, newResults: 1).badgeTotal, Int.max)
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
        XCTAssertNotNil(delegate[pet.upperBound...].range(of: "\n        activityDockBadge.start()\n"),
                        "started at launch after the pet, not inside a conditional")
    }
}
