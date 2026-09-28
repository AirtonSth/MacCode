import XCTest
@testable import CoreModel

final class BotScheduleSpecTests: XCTestCase {
    func test_distillScheduleCannotPersistAutomaticModelRouting_becauseDistillRequiresPinnedModels() throws {
        var spec = BotScheduleSpec(
            provider: .distill,
            providerInstanceID: "distill",
            model: "grok-4.6",
            routingMode: .auto
        )
        XCTAssertEqual(spec.routingMode, .manual, "new Distill schedules must be manual")

        spec.routingMode = .auto
        let encoded = try XCTUnwrap(spec.encodedJSON().data(using: .utf8))
        let savedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(savedObject["routingMode"] as? String, AgentRoutingMode.manual.rawValue)

        var legacyObject = savedObject
        legacyObject["routingMode"] = AgentRoutingMode.auto.rawValue
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let restored = try XCTUnwrap(
            BotScheduleSpec.decodeJSON(String(decoding: legacyData, as: UTF8.self))
        )
        XCTAssertEqual(restored.routingMode, .manual, "legacy Distill schedules must restore manually")
    }

    func test_distillRoutineSpecRoundTripsSeparateModelsAndEfforts_becauseRoutineRunsMustRetainRouting() throws {
        let spec = BotScheduleSpec(
            provider: .distill,
            providerInstanceID: "distill",
            model: "main-model",
            reasoningEffort: .high,
            reasoningModel: "reasoning-model",
            distillMainEffortSelection: .fixed(.high),
            distillReasoningEffortSelection: .automatic,
            routingMode: .manual
        )

        let restored = try XCTUnwrap(BotScheduleSpec.decodeJSON(spec.encodedJSON()))

        XCTAssertEqual(restored.model, "main-model")
        XCTAssertEqual(restored.reasoningModel, "reasoning-model")
        XCTAssertEqual(restored.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(restored.distillReasoningEffortSelection, .automatic)
    }

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
