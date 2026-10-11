import XCTest
@testable import AppShell

final class SilentWakeBudgetTests: XCTestCase {
    /// Table B1 of the F5 spec: the class is admitted while `used` is below this.
    private static let limits: [MaterialWakeCoalesceClass: Int] = [
        .attention: 3,
        .tailcat: 2,
        .boot: 2,
        .notification: 2,
        .runProgress: 1,
        .git: 1,
        .other: 1,
    ]

    func testAdmissionTableForEveryClassAndUsedCount() {
        // WHY: Apple's guidance is two or three silent pushes per hour. The
        // order inside it is the product rule: attention first; the Tailcat
        // address, the boot rebaseline and a host notification (whose silent
        // wake is its only push) before progress traffic.
        XCTAssertEqual(MaterialWakeBudget.capacity, 3)
        XCTAssertEqual(
            Set(Self.limits.keys),
            Set(MaterialWakeCoalesceClass.allCases),
            "every class has a row in the table"
        )
        for coalesceClass in MaterialWakeCoalesceClass.allCases {
            let limit = Self.limits[coalesceClass]
            XCTAssertEqual(MaterialWakeBudget.limit(for: coalesceClass), limit, coalesceClass.rawValue)
            for used in 0...3 {
                XCTAssertEqual(
                    MaterialWakeBudget.admits(coalesceClass, used: used),
                    limit.map { used < $0 },
                    "\(coalesceClass.rawValue) used=\(used)"
                )
            }
        }
    }

    func testOnlyAttentionReachesTheThirdSlot() {
        // WHY: the attention class (approval, question, failed run) is never
        // starved: after two delivered wakes of any kind the last slot of the
        // hour can only be taken by attention.
        for coalesceClass in MaterialWakeCoalesceClass.allCases {
            XCTAssertEqual(
                MaterialWakeBudget.admits(coalesceClass, used: 2),
                coalesceClass == .attention,
                coalesceClass.rawValue
            )
            XCTAssertFalse(
                MaterialWakeBudget.admits(coalesceClass, used: MaterialWakeBudget.capacity),
                "\(coalesceClass.rawValue): nothing is admitted above the capacity"
            )
        }
    }

    func testWindowIsRollingOneHour() {
        // WHY: with fixed clock hours six pushes fit across a boundary; and a
        // slot must come back once its hour has passed, or three wakes would
        // silence the phone for ever.
        let sent: TimeInterval = 1_000_000
        func inWindow(_ times: [TimeInterval], at now: TimeInterval) -> [TimeInterval] {
            MaterialWakeBudget.sentInWindow(times, now: Date(timeIntervalSince1970: now))
        }

        XCTAssertEqual(MaterialWakeBudget.windowSeconds, 3_600)
        XCTAssertEqual(inWindow([sent], at: sent), [sent])
        XCTAssertEqual(inWindow([sent], at: sent + 3_599), [sent])
        XCTAssertEqual(inWindow([sent], at: sent + 3_600), [])
        XCTAssertEqual(
            inWindow([sent - 3_600, sent - 1, sent, sent + 1], at: sent),
            [sent - 1, sent],
            "a time later than now (the wall clock was set back) is dropped too"
        )
    }
}
