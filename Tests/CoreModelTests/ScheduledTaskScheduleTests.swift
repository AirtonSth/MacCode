import XCTest
@testable import CoreModel

/// Deterministic tests for the pure Scheduled Tasks schedule domain.
///
/// WHY: occurrence math must be provider-independent, timezone-correct, and
/// free of traps so host/runtime layers can schedule without re-implementing
/// civil calendar / DST edge cases.
final class ScheduledTaskScheduleTests: XCTestCase {

    private var ny: TimeZone {
        TimeZone(identifier: "America/New_York")!
    }

    private var gregorian: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func localDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int, _ second: Int = 0,
        timeZone: TimeZone
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var dc = DateComponents()
        dc.year = year
        dc.month = month
        dc.day = day
        dc.hour = hour
        dc.minute = minute
        dc.second = second
        guard let date = cal.date(from: dc) else {
            XCTFail("failed to build local date \(year)-\(month)-\(day) \(hour):\(minute) in \(timeZone.identifier)")
            return Date.distantPast
        }
        return date
    }

    private func next(
        after date: Date,
        _ recurrence: ScheduledTaskRecurrence,
        timeZone: TimeZone? = nil
    ) -> Date? {
        ScheduledTaskOccurrenceCalculator.nextOccurrence(
            after: date,
            recurrence: recurrence,
            timeZone: timeZone ?? ny,
            calendar: gregorian
        )
    }

    // MARK: - Validation

    func test_localTime_rejectsOutOfRangeHourAndMinute_withoutTrapping() {
        // WHY: invalid wall times must fail closed at construction, never crash callers.
        XCTAssertNil(ScheduledLocalTime(hour: -1, minute: 0), "hour -1 is invalid")
        XCTAssertNil(ScheduledLocalTime(hour: 24, minute: 0), "hour 24 is invalid")
        XCTAssertNil(ScheduledLocalTime(hour: 0, minute: -1), "minute -1 is invalid")
        XCTAssertNil(ScheduledLocalTime(hour: 0, minute: 60), "minute 60 is invalid")
    }

    func test_localTime_acceptsBoundaryValues() {
        // WHY: 00:00 and 23:59 are legal civil times and must construct.
        XCTAssertEqual(ScheduledLocalTime(hour: 0, minute: 0)?.hour, 0)
        XCTAssertEqual(ScheduledLocalTime(hour: 0, minute: 0)?.minute, 0)
        XCTAssertEqual(ScheduledLocalTime(hour: 23, minute: 59)?.hour, 23)
        XCTAssertEqual(ScheduledLocalTime(hour: 23, minute: 59)?.minute, 59)
    }

    func test_hourly_rejectsIntervalOutside1Through24() {
        // WHY: interval must be a positive hour count capped at a day to keep math simple.
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(ScheduledTaskRecurrence.makeHourly(anchor: anchor, intervalHours: 0))
        XCTAssertNil(ScheduledTaskRecurrence.makeHourly(anchor: anchor, intervalHours: 25))
        XCTAssertNil(ScheduledTaskRecurrence.makeHourly(anchor: anchor, intervalHours: -1))
        XCTAssertNotNil(ScheduledTaskRecurrence.makeHourly(anchor: anchor, intervalHours: 1))
        XCTAssertNotNil(ScheduledTaskRecurrence.makeHourly(anchor: anchor, intervalHours: 24))
    }

    func test_weekly_rejectsEmptyOrDuplicateWeekdays() {
        // WHY: empty days never fire; duplicates are ambiguous and must be rejected, not silently merged.
        let time = ScheduledLocalTime(hour: 9, minute: 0)!
        XCTAssertNil(ScheduledTaskRecurrence.makeWeekly(on: [], at: time), "empty weekdays must fail")
        XCTAssertNil(
            ScheduledTaskRecurrence.makeWeekly(on: [.monday, .monday], at: time),
            "duplicate weekdays must fail validation"
        )
        XCTAssertNotNil(ScheduledTaskRecurrence.makeWeekly(on: [.monday, .friday], at: time))
    }

    func test_monthly_rejectsDayOutside1Through28() {
        // WHY: day 29–31 does not exist in every month; domain caps at 28 to avoid month-end traps.
        let time = ScheduledLocalTime(hour: 9, minute: 0)!
        XCTAssertNil(ScheduledTaskRecurrence.makeMonthly(day: 0, at: time))
        XCTAssertNil(ScheduledTaskRecurrence.makeMonthly(day: 29, at: time))
        XCTAssertNil(ScheduledTaskRecurrence.makeMonthly(day: 31, at: time))
        XCTAssertNotNil(ScheduledTaskRecurrence.makeMonthly(day: 1, at: time))
        XCTAssertNotNil(ScheduledTaskRecurrence.makeMonthly(day: 28, at: time))
    }

    func test_codable_rejectsInvalidHourlyAndMonthlyPayloads() throws {
        // WHY: decoded JSON must not reintroduce invalid ranges that factories already reject.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let badHourly = """
        {"kind":"hourly","anchor":1700000000,"intervalHours":0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ScheduledTaskRecurrence.self, from: badHourly),
                             "intervalHours 0 must fail decode")

        let badMonthly = """
        {"kind":"monthly","day":31,"hour":9,"minute":0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ScheduledTaskRecurrence.self, from: badMonthly),
                             "monthly day 31 must fail decode")

        let badWeekly = """
        {"kind":"weekly","days":[],"hour":9,"minute":0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ScheduledTaskRecurrence.self, from: badWeekly),
                             "empty weekly days must fail decode")
    }

    func test_codable_roundTripsEachRecurrenceKind() throws {
        // WHY: wire stability for persistence/sync depends on kind-discriminated Codable.
        let time = ScheduledLocalTime(hour: 8, minute: 30)!
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [ScheduledTaskRecurrence] = [
            .once(at: anchor),
            .makeHourly(anchor: anchor, intervalHours: 3)!,
            .daily(at: time),
            .weekdays(at: time),
            .makeWeekly(on: [.tuesday, .thursday], at: time)!,
            .makeMonthly(day: 15, at: time)!,
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        for original in cases {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ScheduledTaskRecurrence.self, from: data)
            XCTAssertEqual(decoded, original, "round-trip must preserve \(original)")
        }
    }

    // MARK: - Once

    func test_once_returnsInstantWhenStrictlyAfterInput() {
        // WHY: a future one-shot must still fire; equality is not "after".
        let at = Date(timeIntervalSince1970: 1_700_000_100)
        let before = Date(timeIntervalSince1970: 1_700_000_000)
        let result = next(after: before, .once(at: at), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(result, at)
    }

    func test_once_returnsNilWhenAtOrAfterInstant() {
        // WHY: once is exhausted at/after its instant; must not re-fire.
        let at = Date(timeIntervalSince1970: 1_700_000_100)
        XCTAssertNil(next(after: at, .once(at: at), timeZone: TimeZone(secondsFromGMT: 0)!),
                     "strictly-after: equal instant must not fire again")
        XCTAssertNil(next(after: at.addingTimeInterval(1), .once(at: at), timeZone: TimeZone(secondsFromGMT: 0)!),
                     "past once must return nil")
    }

    // MARK: - Hourly

    func test_hourly_usesAbsoluteAnchorAndInterval() {
        // WHY: hourly is absolute-time anchored, not civil local hours (so DST hour skips don't matter).
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let recurrence = ScheduledTaskRecurrence.makeHourly(anchor: anchor, intervalHours: 2)!
        let tz = TimeZone(secondsFromGMT: 0)!

        // Just after anchor → next is anchor+2h
        let afterAnchor = anchor.addingTimeInterval(1)
        XCTAssertEqual(
            next(after: afterAnchor, recurrence, timeZone: tz),
            anchor.addingTimeInterval(2 * 3600)
        )

        // Exactly on an occurrence → strictly after requires the following step
        let onStep = anchor.addingTimeInterval(4 * 3600)
        XCTAssertEqual(
            next(after: onStep, recurrence, timeZone: tz),
            anchor.addingTimeInterval(6 * 3600),
            "strictly-after: landing exactly on a step must advance one interval"
        )
    }

    func test_hourly_returnsAnchorWhenStillInFuture() {
        // WHY: if the anchor itself is still ahead, it is the first occurrence.
        let anchor = Date(timeIntervalSince1970: 1_700_000_500)
        let before = Date(timeIntervalSince1970: 1_700_000_000)
        let recurrence = ScheduledTaskRecurrence.makeHourly(anchor: anchor, intervalHours: 1)!
        XCTAssertEqual(
            next(after: before, recurrence, timeZone: TimeZone(secondsFromGMT: 0)!),
            anchor
        )
    }

    // MARK: - Daily / weekdays / weekly / monthly (civil calendar)

    func test_daily_usesCivilLocalTimeNotFixed24HourArithmetic() {
        // WHY: civil daily means "same wall clock tomorrow", which can be 23h or 25h across DST.
        let time = ScheduledLocalTime(hour: 9, minute: 0)!
        let recurrence = ScheduledTaskRecurrence.daily(at: time)

        // 2025-03-08 10:00 EST → next daily 09:00 is 2025-03-09 09:00 EDT (spring-forward night).
        let after = localDate(2025, 3, 8, 10, 0, timeZone: ny)
        let expected = localDate(2025, 3, 9, 9, 0, timeZone: ny)
        let result = next(after: after, recurrence)
        XCTAssertEqual(result, expected,
                       "daily must land on local 09:00 next civil day, not +24h from previous fire")
    }

    func test_daily_strictlyAfterSkipsCurrentInstant() {
        // WHY: if "now" is exactly the scheduled wall time, the fire already belongs to this slot.
        let time = ScheduledLocalTime(hour: 9, minute: 0)!
        let recurrence = ScheduledTaskRecurrence.daily(at: time)
        let onSlot = localDate(2025, 6, 10, 9, 0, timeZone: ny)
        let expected = localDate(2025, 6, 11, 9, 0, timeZone: ny)
        XCTAssertEqual(next(after: onSlot, recurrence), expected,
                       "strictly-after daily must advance to the next civil day")
    }

    func test_weekdays_skipsSaturdayAndSunday() {
        // WHY: weekdays recurrence is Mon–Fri only; weekend must not fire.
        let time = ScheduledLocalTime(hour: 9, minute: 0)!
        let recurrence = ScheduledTaskRecurrence.weekdays(at: time)

        // 2025-06-13 is Friday. After Friday 10:00 → Monday 09:00.
        let afterFriday = localDate(2025, 6, 13, 10, 0, timeZone: ny)
        let expectedMonday = localDate(2025, 6, 16, 9, 0, timeZone: ny)
        XCTAssertEqual(next(after: afterFriday, recurrence), expectedMonday,
                       "after Friday fire, weekdays must jump to Monday, not Saturday")
    }

    func test_weekly_picksEarliestMatchingWeekday() {
        // WHY: multi-day weekly schedules must choose the soonest matching day after the bound.
        let time = ScheduledLocalTime(hour: 10, minute: 0)!
        let recurrence = ScheduledTaskRecurrence.makeWeekly(on: [.tuesday, .thursday], at: time)!

        // 2025-06-09 is Monday → next is Tuesday.
        let afterMonday = localDate(2025, 6, 9, 8, 0, timeZone: ny)
        XCTAssertEqual(
            next(after: afterMonday, recurrence),
            localDate(2025, 6, 10, 10, 0, timeZone: ny)
        )

        // After Tuesday 11:00 → Thursday.
        let afterTuesday = localDate(2025, 6, 10, 11, 0, timeZone: ny)
        XCTAssertEqual(
            next(after: afterTuesday, recurrence),
            localDate(2025, 6, 12, 10, 0, timeZone: ny)
        )
    }

    func test_monthly_usesCivilDayOfMonth() {
        // WHY: monthly must advance by calendar month/day, not by fixed day-count arithmetic.
        let time = ScheduledLocalTime(hour: 8, minute: 15)!
        let recurrence = ScheduledTaskRecurrence.makeMonthly(day: 15, at: time)!

        let after = localDate(2025, 1, 15, 9, 0, timeZone: ny)
        let expected = localDate(2025, 2, 15, 8, 15, timeZone: ny)
        XCTAssertEqual(next(after: after, recurrence), expected,
                       "after the 15th this month, next is the 15th next month at local time")
    }

    // MARK: - DST America/New_York

    func test_dstSpringForward_choosesNextValidLocalTimeThatDay() {
        // WHY: 2025-03-09 clocks jump 02:00 → 03:00; 02:30 never exists that day.
        // Policy: pick the next valid local time the same civil day (03:00).
        let time = ScheduledLocalTime(hour: 2, minute: 30)!
        let recurrence = ScheduledTaskRecurrence.daily(at: time)

        let after = localDate(2025, 3, 9, 1, 0, timeZone: ny)
        let result = next(after: after, recurrence)

        // Next valid local time on that day is 03:00 EDT.
        let expected = localDate(2025, 3, 9, 3, 0, timeZone: ny)
        XCTAssertEqual(result, expected,
                       "spring gap 02:30 must resolve to next valid local time (03:00) the same day")

        // Sanity: result wall-clock hour in NY is 3.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ny
        XCTAssertEqual(cal.component(.hour, from: result!), 3)
        XCTAssertEqual(cal.component(.day, from: result!), 9)
    }

    func test_dstFallBack_choosesFirstOccurrenceOnly() {
        // WHY: 2025-11-02 01:30 occurs twice; policy fires only the first (EDT) occurrence.
        let time = ScheduledLocalTime(hour: 1, minute: 30)!
        let recurrence = ScheduledTaskRecurrence.daily(at: time)

        // Before both occurrences: next is the first 01:30 (still EDT, UTC-4).
        let before = localDate(2025, 11, 2, 0, 30, timeZone: ny)
        let first = next(after: before, recurrence)
        XCTAssertNotNil(first)

        // First 01:30 EDT uses offset -4; second 01:30 EST uses -5. Policy picks first only.
        let expectedFirst = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: -4 * 3600),
            year: 2025, month: 11, day: 2, hour: 1, minute: 30
        ).date!
        XCTAssertEqual(first, expectedFirst,
                       "fall-back must select the first (daylight) 01:30, not the second (standard)")

        // After the first 01:30, the second 01:30 must not fire; next is the following day.
        let nextAfterFirst = next(after: expectedFirst, recurrence)
        let nextDay = localDate(2025, 11, 3, 1, 30, timeZone: ny)
        XCTAssertEqual(nextAfterFirst, nextDay,
                       "after first fall-back occurrence, calculator must skip the repeated hour and go to next day")
    }

    // MARK: - Occurrence key

    func test_occurrenceKey_isStableForSameTaskAndInstant() {
        // WHY: dedupe/idempotency keys must be deterministic across processes.
        let taskID = UUID(uuidString: "A0A0A0A0-A0A0-40A0-A0A0-A0A0A0A0A0A0")!
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        let a = ScheduledTaskOccurrenceCalculator.occurrenceKey(taskID: taskID, scheduledAt: date)
        let b = ScheduledTaskOccurrenceCalculator.occurrenceKey(taskID: taskID, scheduledAt: date)
        XCTAssertEqual(a, b, "same task + same instant must yield identical occurrence keys")
        XCTAssertTrue(a.contains(taskID.uuidString.lowercased()),
                      "key must embed the task UUID for correlation")
        XCTAssertTrue(a.hasSuffix(":1700000000500") || a.contains("1700000000500"),
                      "key must embed truncated UTC milliseconds of the scheduled instant")
    }

    func test_occurrenceKey_differsAcrossTaskOrInstant() {
        // WHY: different tasks or different fire times must not collide under the key.
        let taskA = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let taskB = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_001)

        let k1 = ScheduledTaskOccurrenceCalculator.occurrenceKey(taskID: taskA, scheduledAt: t1)
        let k2 = ScheduledTaskOccurrenceCalculator.occurrenceKey(taskID: taskA, scheduledAt: t2)
        let k3 = ScheduledTaskOccurrenceCalculator.occurrenceKey(taskID: taskB, scheduledAt: t1)

        XCTAssertNotEqual(k1, k2, "different scheduled instants must produce different keys")
        XCTAssertNotEqual(k1, k3, "different task IDs must produce different keys")
    }
}
