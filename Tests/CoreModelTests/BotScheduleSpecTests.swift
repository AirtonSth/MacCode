import XCTest
@testable import CoreModel

final class BotScheduleSpecTests: XCTestCase {
    func test_parseDisplayNoteRecoversVisibleFrequencies_becauseEmptySpecMustNotBecomeDaily() throws {
        // WHY: Fleet Edit Scheduled Task used BotScheduleSpec() when
        // schedule_spec_json was empty. Bot-created When notes like
        // "Weekdays 9:00" then opened as Daily at now, and Save overwrote
        // the visible schedule.
        let weekdays = try XCTUnwrap(BotScheduleSpec.parseDisplayNote("Weekdays 9:00"))
        XCTAssertEqual(weekdays.frequency, .weekdays)
        XCTAssertEqual(weekdays.localTimeHour, 9)
        XCTAssertEqual(weekdays.localTimeMinute, 0)

        let padded = try XCTUnwrap(BotScheduleSpec.parseDisplayNote("Weekdays 09:00"))
        XCTAssertEqual(padded.frequency, .weekdays)
        XCTAssertEqual(padded.localTimeHour, 9)

        let daily = try XCTUnwrap(BotScheduleSpec.parseDisplayNote("Daily 23:58"))
        XCTAssertEqual(daily.frequency, .daily)
        XCTAssertEqual(daily.localTimeHour, 23)
        XCTAssertEqual(daily.localTimeMinute, 58)

        let hourly = try XCTUnwrap(BotScheduleSpec.parseDisplayNote("Every 2h"))
        XCTAssertEqual(hourly.frequency, .hourly)
        XCTAssertEqual(hourly.intervalHours, 2)

        let monthly = try XCTUnwrap(BotScheduleSpec.parseDisplayNote("Monthly day 3 08:00"))
        XCTAssertEqual(monthly.frequency, .monthly)
        XCTAssertEqual(monthly.monthlyDay, 3)
        XCTAssertEqual(monthly.localTimeHour, 8)

        XCTAssertNil(BotScheduleSpec.parseDisplayNote("Daily"), "incomplete When must not invent 09:00")
        XCTAssertNil(BotScheduleSpec.parseDisplayNote("when the build fails"))

        var spec = BotScheduleSpec()
        spec.frequency = .weekdays
        spec.localTimeHour = 9
        spec.localTimeMinute = 0
        let resolved = BotScheduleSpec.resolved(json: "", note: "Weekdays 9:00")
        XCTAssertEqual(resolved.frequency, .weekdays)
        XCTAssertEqual(resolved.localTimeHour, 9)
        XCTAssertEqual(resolved.displayNote(), spec.displayNote())
    }
}
