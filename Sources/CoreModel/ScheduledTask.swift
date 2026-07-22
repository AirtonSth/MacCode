import Foundation

public enum ScheduledTaskRunStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case skipped
}

public enum ScheduledTaskRunTrigger: String, Codable, Sendable, CaseIterable {
    case scheduled
    case catchUp
    case manual
}

public struct ScheduledTask: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var prompt: String
    public var workspaceID: WorkspaceID
    public var workspacePathSnapshot: String
    public var runAsUser: String
    public var runAsUID: UInt32
    public var provider: AgentProvider
    public var providerInstanceID: String
    public var model: String
    public var reasoningEffort: AgentReasoningEffort
    /// Optional for backward-compatible Codable decoding of tasks serialized
    /// before scheduled Auto routing existed. Missing values mean Manual.
    public var routingMode: AgentRoutingMode?
    public var recurrence: ScheduledTaskRecurrence
    public var timeZoneIdentifier: String
    public var isEnabled: Bool
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        workspaceID: WorkspaceID,
        workspacePathSnapshot: String,
        runAsUser: String,
        runAsUID: UInt32,
        provider: AgentProvider,
        providerInstanceID: String,
        model: String,
        reasoningEffort: AgentReasoningEffort,
        routingMode: AgentRoutingMode = .manual,
        recurrence: ScheduledTaskRecurrence,
        timeZoneIdentifier: String,
        isEnabled: Bool = true,
        nextRunAt: Date? = nil,
        lastRunAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.workspaceID = workspaceID
        self.workspacePathSnapshot = workspacePathSnapshot
        self.runAsUser = runAsUser
        self.runAsUID = runAsUID
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.routingMode = routingMode
        self.recurrence = recurrence
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isEnabled = isEnabled
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var effectiveRoutingMode: AgentRoutingMode { routingMode ?? .manual }

    public func validationErrors() -> [String] {
        var errors: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { errors.append("Title is required.") }
        if trimmedTitle.count > 120 { errors.append("Title must be at most 120 characters.") }
        if trimmedPrompt.isEmpty { errors.append("Prompt is required.") }
        if trimmedPrompt.utf8.count > 65_536 { errors.append("Prompt must be at most 64 KiB.") }
        if workspacePathSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("Workspace path is required.") }
        if runAsUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("System user is required.") }
        if runAsUID < 500 || runAsUID == UInt32.max { errors.append("System user must be an eligible non-root account.") }
        if effectiveRoutingMode == .manual {
            if providerInstanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("Provider instance is required.") }
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("Model is required.") }
        }
        if TimeZone(identifier: timeZoneIdentifier) == nil { errors.append("Time zone must be a valid IANA identifier.") }
        switch recurrence {
        case .hourly(_, let interval) where !ScheduledTaskRecurrence.isValidHourlyInterval(interval):
            errors.append("Hourly interval must be between 1 and 24.")
        case .weekly(let days, _) where !ScheduledTaskRecurrence.isValidWeeklyDays(days):
            errors.append("Weekly schedules require unique weekdays.")
        case .monthly(let day, _) where !ScheduledTaskRecurrence.isValidMonthlyDay(day):
            errors.append("Monthly day must be between 1 and 28.")
        default:
            break
        }
        return errors
    }

    public func calculatedNextRun(after date: Date) -> Date? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        return ScheduledTaskOccurrenceCalculator.nextOccurrence(
            after: date,
            recurrence: recurrence,
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        )
    }
}

public struct ScheduledTaskRun: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let occurrenceKey: String
    public let trigger: ScheduledTaskRunTrigger
    public let scheduledAt: Date
    public let queuedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var status: ScheduledTaskRunStatus
    public var threadID: AgentThreadID?
    public var agentRunID: AgentRunID?
    public var errorCode: String?
    public var errorSummary: String?
    public var leaseOwner: String?
    public var heartbeatAt: Date?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        occurrenceKey: String,
        trigger: ScheduledTaskRunTrigger,
        scheduledAt: Date,
        queuedAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        status: ScheduledTaskRunStatus = .queued,
        threadID: AgentThreadID? = nil,
        agentRunID: AgentRunID? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil,
        leaseOwner: String? = nil,
        heartbeatAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.occurrenceKey = occurrenceKey
        self.trigger = trigger
        self.scheduledAt = scheduledAt
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.threadID = threadID
        self.agentRunID = agentRunID
        self.errorCode = errorCode
        self.errorSummary = errorSummary
        self.leaseOwner = leaseOwner
        self.heartbeatAt = heartbeatAt
    }
}

public enum ScheduledTaskFrequency: String, Sendable, CaseIterable, Identifiable {
    case once
    case hourly
    case daily
    case weekdays
    case weekly
    case monthly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .once: return "Once"
        case .hourly: return "Hourly"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}
