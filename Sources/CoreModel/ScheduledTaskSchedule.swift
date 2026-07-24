import Foundation

// MARK: - Local wall-clock time

/// Local schedule time-of-day in civil clock components (hour/minute).
/// Not a timezone-aware instant; pair with an IANA `TimeZone` at calculation time.
public struct ScheduledLocalTime: Codable, Sendable, Equatable, Hashable {
    public let hour: Int
    public let minute: Int

    /// - Returns: `nil` when hour is outside `0...23` or minute outside `0...59`.
    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }
}

// MARK: - Weekday

/// Gregorian weekday matching `Calendar.Component.weekday` numbering (Sunday = 1 … Saturday = 7).
public enum ScheduledWeekday: Int, Codable, Sendable, Equatable, Hashable, CaseIterable, Comparable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    public static func < (lhs: ScheduledWeekday, rhs: ScheduledWeekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Recurrence

/// Versioned, provider-independent recurrence description for Scheduled Tasks.
///
/// Wire format uses a `kind` discriminator so cases can evolve without silent decode breakage.
/// Construction validates ranges without trapping; invalid inputs yield `nil` or decode errors.
public enum ScheduledTaskRecurrence: Codable, Sendable, Equatable, Hashable {
    /// Fires once at an absolute instant; no further occurrences after that instant.
    case once(at: Date)
    /// Absolute-time recurrence: `anchor + n * intervalHours` for integer `n >= 0`.
    case hourly(anchor: Date, intervalHours: Int)
    /// Every civil day at the given local wall-clock time.
    case daily(at: ScheduledLocalTime)
    /// Monday–Friday at the given local wall-clock time.
    case weekdays(at: ScheduledLocalTime)
    /// Selected weekdays (non-empty, unique) at the given local wall-clock time.
    case weekly(on: [ScheduledWeekday], at: ScheduledLocalTime)
    /// Day-of-month `1...28` at the given local wall-clock time (always exists in every month).
    case monthly(day: Int, at: ScheduledLocalTime)

    // MARK: Validated factories
    // Note: `.once` / `.daily` / `.weekdays` need no failable factories (no extra ranges).
    // Case names already form the public constructors; only constrained kinds get static helpers.

    /// - Returns: `nil` when `intervalHours` is outside `1...24`.
    public static func makeHourly(anchor: Date, intervalHours: Int) -> ScheduledTaskRecurrence? {
        guard (1...24).contains(intervalHours) else { return nil }
        // Whole-second anchors: schedule storage is ISO8601 without fractional
        // seconds; subsecond anchors re-select the spent slot after a fire.
        return .hourly(anchor: ScheduledTaskOccurrenceCalculator.canonicalInstant(anchor), intervalHours: intervalHours)
    }

    /// - Returns: `nil` when `days` is empty or contains duplicates.
    public static func makeWeekly(on days: [ScheduledWeekday], at time: ScheduledLocalTime) -> ScheduledTaskRecurrence? {
        guard Self.isValidWeeklyDays(days) else { return nil }
        return .weekly(on: days.sorted(), at: time)
    }

    /// - Returns: `nil` when `day` is outside `1...28`.
    public static func makeMonthly(day: Int, at time: ScheduledLocalTime) -> ScheduledTaskRecurrence? {
        guard (1...28).contains(day) else { return nil }
        return .monthly(day: day, at: time)
    }

    public static func isValidWeeklyDays(_ days: [ScheduledWeekday]) -> Bool {
        !days.isEmpty && Set(days).count == days.count
    }

    public static func isValidHourlyInterval(_ intervalHours: Int) -> Bool {
        (1...24).contains(intervalHours)
    }

    public static func isValidMonthlyDay(_ day: Int) -> Bool {
        (1...28).contains(day)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case kind
        case at
        case anchor
        case intervalHours
        case hour
        case minute
        case days
        case day
    }

    private enum Kind: String, Codable {
        case once
        case hourly
        case daily
        case weekdays
        case weekly
        case monthly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .once:
            // Floor legacy subsecond instants so spent-occurrence advance cannot
            // re-select the same once slot after whole-second persistence.
            self = .once(at: ScheduledTaskOccurrenceCalculator.canonicalInstant(try c.decode(Date.self, forKey: .at)))
        case .hourly:
            let interval = try c.decode(Int.self, forKey: .intervalHours)
            guard (1...24).contains(interval) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .intervalHours,
                    in: c,
                    debugDescription: "hourly intervalHours must be in 1...24"
                )
            }
            let anchor = ScheduledTaskOccurrenceCalculator.canonicalInstant(try c.decode(Date.self, forKey: .anchor))
            self = .hourly(anchor: anchor, intervalHours: interval)
        case .daily:
            self = .daily(at: try Self.decodeLocalTime(from: c))
        case .weekdays:
            self = .weekdays(at: try Self.decodeLocalTime(from: c))
        case .weekly:
            let days = try c.decode([ScheduledWeekday].self, forKey: .days)
            guard Self.isValidWeeklyDays(days) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .days,
                    in: c,
                    debugDescription: "weekly days must be non-empty and unique"
                )
            }
            self = .weekly(on: days.sorted(), at: try Self.decodeLocalTime(from: c))
        case .monthly:
            let day = try c.decode(Int.self, forKey: .day)
            guard (1...28).contains(day) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .day,
                    in: c,
                    debugDescription: "monthly day must be in 1...28"
                )
            }
            self = .monthly(day: day, at: try Self.decodeLocalTime(from: c))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .once(let date):
            try c.encode(Kind.once, forKey: .kind)
            try c.encode(ScheduledTaskOccurrenceCalculator.canonicalInstant(date), forKey: .at)
        case .hourly(let anchor, let intervalHours):
            try c.encode(Kind.hourly, forKey: .kind)
            try c.encode(ScheduledTaskOccurrenceCalculator.canonicalInstant(anchor), forKey: .anchor)
            try c.encode(intervalHours, forKey: .intervalHours)
        case .daily(let time):
            try c.encode(Kind.daily, forKey: .kind)
            try Self.encodeLocalTime(time, into: &c)
        case .weekdays(let time):
            try c.encode(Kind.weekdays, forKey: .kind)
            try Self.encodeLocalTime(time, into: &c)
        case .weekly(let days, let time):
            try c.encode(Kind.weekly, forKey: .kind)
            try c.encode(days, forKey: .days)
            try Self.encodeLocalTime(time, into: &c)
        case .monthly(let day, let time):
            try c.encode(Kind.monthly, forKey: .kind)
            try c.encode(day, forKey: .day)
            try Self.encodeLocalTime(time, into: &c)
        }
    }

    private static func decodeLocalTime(from c: KeyedDecodingContainer<CodingKeys>) throws -> ScheduledLocalTime {
        let hour = try c.decode(Int.self, forKey: .hour)
        let minute = try c.decode(Int.self, forKey: .minute)
        guard let time = ScheduledLocalTime(hour: hour, minute: minute) else {
            throw DecodingError.dataCorruptedError(
                forKey: .hour,
                in: c,
                debugDescription: "local time hour must be 0...23 and minute 0...59"
            )
        }
        return time
    }

    private static func encodeLocalTime(
        _ time: ScheduledLocalTime,
        into c: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try c.encode(time.hour, forKey: .hour)
        try c.encode(time.minute, forKey: .minute)
    }
}

// MARK: - Calculator

/// Pure next-occurrence calculator for Scheduled Tasks.
///
/// - Daily / weekdays / weekly / monthly use civil calendar components in the given time zone.
/// - Hourly uses absolute-time arithmetic from an anchor.
/// - DST spring gap: prefer the next valid local time that day (`.nextTime`).
/// - DST repeated time: prefer the first occurrence only (`.first`).
public enum ScheduledTaskOccurrenceCalculator {
    /// Schedule-domain instants are whole seconds. Subsecond precision is not a
    /// product requirement (UI is minute-oriented) and ISO8601 persistence without
    /// fractional seconds would otherwise re-select a spent hourly/once slot.
    public static func canonicalInstant(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    /// Lower bound used after a claimed/spent occurrence so the next pointer never
    /// lands on the same slot even when storage truncated subseconds.
    ///
    /// One second is safe: minimum hourly step is 1h; civil recurrences are minute+
    /// apart; `.once` has no successor. Do **not** use this for editor "next preview"
    /// or launch skip (`after: now`) — only after a real spent occurrence.
    public static let spentOccurrenceAdvance: TimeInterval = 1

    /// First occurrence strictly after `date` for `recurrence` in `timeZone`.
    ///
    /// - Parameters:
    ///   - date: Exclusive lower bound (strictly after).
    ///   - recurrence: Validated recurrence description.
    ///   - timeZone: Explicit IANA time zone used for civil-calendar cases.
    ///   - calendar: Injected calendar; must be Gregorian. `timeZone` is applied for the calculation.
    /// - Returns: Next occurrence, or `nil` when none exists (e.g. `.once` already passed).
    public static func nextOccurrence(
        after date: Date,
        recurrence: ScheduledTaskRecurrence,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> Date? {
        var cal = calendar
        cal.timeZone = timeZone

        switch recurrence {
        case .once(let at):
            let instant = canonicalInstant(at)
            return instant > date ? instant : nil

        case .hourly(let anchor, let intervalHours):
            guard ScheduledTaskRecurrence.isValidHourlyInterval(intervalHours) else { return nil }
            return nextHourly(
                after: date,
                anchor: canonicalInstant(anchor),
                intervalHours: intervalHours
            )

        case .daily(let time):
            return nextMatching(
                after: date,
                calendar: cal,
                hour: time.hour,
                minute: time.minute,
                weekday: nil,
                day: nil
            )

        case .weekdays(let time):
            let days: [ScheduledWeekday] = [.monday, .tuesday, .wednesday, .thursday, .friday]
            return nextWeekly(after: date, calendar: cal, days: days, time: time)

        case .weekly(let days, let time):
            guard ScheduledTaskRecurrence.isValidWeeklyDays(days) else { return nil }
            return nextWeekly(after: date, calendar: cal, days: days, time: time)

        case .monthly(let day, let time):
            guard ScheduledTaskRecurrence.isValidMonthlyDay(day) else { return nil }
            return nextMatching(
                after: date,
                calendar: cal,
                hour: time.hour,
                minute: time.minute,
                weekday: nil,
                day: day
            )
        }
    }

    /// Stable occurrence identity: task UUID + scheduled UTC epoch milliseconds.
    public static func occurrenceKey(taskID: UUID, scheduledAt: Date) -> String {
        let millis = utcMilliseconds(canonicalInstant(scheduledAt))
        return "\(taskID.uuidString.lowercased()):\(millis)"
    }

    /// Next occurrence after a claimed fire. Always strictly past the spent slot.
    public static func nextOccurrenceAfterSpent(
        scheduledAt: Date,
        recurrence: ScheduledTaskRecurrence,
        timeZone: TimeZone,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date? {
        nextOccurrence(
            after: canonicalInstant(scheduledAt).addingTimeInterval(spentOccurrenceAdvance),
            recurrence: recurrence,
            timeZone: timeZone,
            calendar: calendar
        )
    }

    // MARK: Private

    private static func nextHourly(after date: Date, anchor: Date, intervalHours: Int) -> Date? {
        let step = TimeInterval(intervalHours) * 3600
        guard step > 0 else { return nil }
        let anchor = canonicalInstant(anchor)
        if anchor > date { return anchor }
        let elapsed = date.timeIntervalSince(anchor)
        let steps = floor(elapsed / step)
        var candidate = anchor.addingTimeInterval(steps * step)
        // Strictly after: if we landed on or before `date`, advance one interval.
        if candidate <= date {
            candidate = candidate.addingTimeInterval(step)
        }
        return candidate
    }

    private static func nextWeekly(
        after date: Date,
        calendar: Calendar,
        days: [ScheduledWeekday],
        time: ScheduledLocalTime
    ) -> Date? {
        var best: Date?
        for day in days {
            guard let next = nextMatching(
                after: date,
                calendar: calendar,
                hour: time.hour,
                minute: time.minute,
                weekday: day.rawValue,
                day: nil
            ) else { continue }
            if best == nil || next < best! {
                best = next
            }
        }
        return best
    }

    private static func nextMatching(
        after date: Date,
        calendar: Calendar,
        hour: Int,
        minute: Int,
        weekday: Int?,
        day: Int?
    ) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.nanosecond = 0
        if let weekday {
            components.weekday = weekday
        }
        if let day {
            components.day = day
        }

        // `.nextTime` → spring gap picks next valid local time that day.
        // `.first` → fall-back repeated wall time picks the first occurrence only.
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    private static func utcMilliseconds(_ date: Date) -> Int64 {
        // Truncate toward -∞ so keys are stable across floating-point noise.
        Int64((date.timeIntervalSince1970 * 1000.0).rounded(.down))
    }
}
