import Foundation

/// Agent App schedule routing + frequency for a Bot routine.
/// Encoded on `bot_routine_definitions.schedule_spec_json`.
public struct BotScheduleSpec: Codable, Sendable, Equatable {
    public var provider: AgentProvider
    public var providerInstanceID: String
    public var model: String
    public var reasoningEffort: AgentReasoningEffort
    public var routingMode: AgentRoutingMode
    public var frequency: ScheduledTaskFrequency
    public var scheduledDate: Date
    public var intervalHours: Int
    public var localTimeHour: Int
    public var localTimeMinute: Int
    public var weekdays: [ScheduledWeekday]
    public var monthlyDay: Int
    public var timeZoneIdentifier: String

    public init(
        provider: AgentProvider = .grok,
        providerInstanceID: String = AgentProvider.grok.rawValue,
        model: String = "",
        reasoningEffort: AgentReasoningEffort = .medium,
        routingMode: AgentRoutingMode = .auto,
        frequency: ScheduledTaskFrequency = .daily,
        scheduledDate: Date = Date().addingTimeInterval(60 * 60),
        intervalHours: Int = 1,
        localTime: Date = Date(),
        weekdays: Set<ScheduledWeekday> = [.monday],
        monthlyDay: Int = 1,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.routingMode = routingMode
        self.frequency = frequency
        self.scheduledDate = scheduledDate
        self.intervalHours = intervalHours
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: localTime)
        self.localTimeHour = parts.hour ?? 9
        self.localTimeMinute = parts.minute ?? 0
        self.weekdays = weekdays.sorted()
        self.monthlyDay = monthlyDay
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var weekdaySet: Set<ScheduledWeekday> {
        get { Set(weekdays) }
        set { weekdays = newValue.sorted() }
    }

    public var localTime: Date {
        get {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
            return calendar.date(bySettingHour: localTimeHour, minute: localTimeMinute, second: 0, of: Date()) ?? Date()
        }
        set {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
            let parts = calendar.dateComponents([.hour, .minute], from: newValue)
            localTimeHour = parts.hour ?? 9
            localTimeMinute = parts.minute ?? 0
        }
    }

    public func makeRecurrence() throws -> ScheduledTaskRecurrence {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw BotScheduleSpecError.invalid("Select a valid IANA time zone.")
        }
        guard let time = ScheduledLocalTime(hour: localTimeHour, minute: localTimeMinute) else {
            throw BotScheduleSpecError.invalid("Select a valid local time.")
        }
        switch frequency {
        case .once:
            return .once(at: ScheduledTaskOccurrenceCalculator.canonicalInstant(scheduledDate))
        case .hourly:
            guard let value = ScheduledTaskRecurrence.makeHourly(anchor: scheduledDate, intervalHours: intervalHours) else {
                throw BotScheduleSpecError.invalid("Hourly interval must be between 1 and 24.")
            }
            return value
        case .daily:
            return .daily(at: time)
        case .weekdays:
            return .weekdays(at: time)
        case .weekly:
            guard let value = ScheduledTaskRecurrence.makeWeekly(on: weekdays, at: time) else {
                throw BotScheduleSpecError.invalid("Select at least one weekday.")
            }
            return value
        case .monthly:
            guard let value = ScheduledTaskRecurrence.makeMonthly(day: monthlyDay, at: time) else {
                throw BotScheduleSpecError.invalid("Monthly day must be between 1 and 28.")
            }
            return value
        }
    }

    public func displayNote() -> String {
        let time = String(format: "%02d:%02d", localTimeHour, localTimeMinute)
        switch frequency {
        case .once:
            return "Once"
        case .hourly:
            return "Every \(intervalHours)h"
        case .daily:
            return "Daily \(time)"
        case .weekdays:
            return "Weekdays \(time)"
        case .weekly:
            return "Weekly \(time)"
        case .monthly:
            return "Monthly day \(monthlyDay) \(time)"
        }
    }

    public func encodedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    public static func decodeJSON(_ raw: String) -> BotScheduleSpec? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BotScheduleSpec.self, from: data)
    }
}

public enum BotScheduleSpecError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}
