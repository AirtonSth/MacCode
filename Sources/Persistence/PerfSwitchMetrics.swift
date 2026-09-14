import Foundation
import OSLog

/// Tab/conversation switch and main-thread SQLite wait intervals.
///
/// Instruments Points of Interest: subsystem `io.remotecode.perf`.
/// Test seams record the same intervals without requiring a GUI session.
public enum PerfSwitchMetrics {
    public static let subsystem = "io.remotecode.perf"
    public static let signposter = OSSignposter(
        subsystem: subsystem,
        category: .pointsOfInterest
    )

    public static let tabSwitchName: StaticString = "tab_switch"
    public static let conversationSwitchName: StaticString = "conversation_switch"
    public static let sqliteMainSyncName: StaticString = "sqlite_main_sync"

    public static let slowMainSyncNanoseconds: UInt64 = 2_000_000
    /// EV-20: the interval/wait arrays are test seams, but they were appended for
    /// the whole process lifetime in release. Keep a bounded ring so a long
    /// session with N runs does not grow them without limit.
    static let recordedIntervalCapacity = 512

    public struct Interval: Equatable, Sendable {
        public var name: String
        public var nanoseconds: UInt64
        public var onMainThread: Bool

        public var milliseconds: Double { Double(nanoseconds) / 1_000_000.0 }
    }

    private struct OpenInterval {
        var name: String
        var start: DispatchTime
        var signpostState: OSSignpostIntervalState
    }

    private struct State: @unchecked Sendable {
        var tab: OpenInterval?
        var conversation: OpenInterval?
        var conversationDidPublish = false
        var recorded: [Interval] = []
        var mainThreadSyncCount: Int = 0
        var mainThreadSyncNanoseconds: [UInt64] = []
        var queueOccupiedNanoseconds: UInt64 = 0
        var slowMainSyncLogCount: Int = 0
        var lastSlowMainSyncStack: String?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    public static func resetForTesting() {
        state.withLock { $0 = State() }
    }

    public static func recordedIntervalsForTesting() -> [Interval] {
        state.withLock { $0.recorded }
    }

    public static func mainThreadSyncCountForTesting() -> Int {
        state.withLock { $0.mainThreadSyncCount }
    }

    public static func mainThreadSyncNanosecondsForTesting() -> [UInt64] {
        state.withLock { $0.mainThreadSyncNanoseconds }
    }

    public static func queueOccupiedNanosecondsForTesting() -> UInt64 {
        state.withLock { $0.queueOccupiedNanoseconds }
    }

    public static func slowMainSyncLogCountForTesting() -> Int {
        state.withLock { $0.slowMainSyncLogCount }
    }

    public static func lastSlowMainSyncStackForTesting() -> String? {
        state.withLock { $0.lastSlowMainSyncStack }
    }

    public static func percentileMilliseconds(
        _ values: [UInt64],
        percentile: Double
    ) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 100)
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * clamped / 100.0).rounded())))
        return Double(sorted[index]) / 1_000_000.0
    }

    // MARK: - Tab switch (focusSurface → installSelectedContent → CA commit)

    public static func beginTabSwitch(surfaceID: String) {
        let interval = signposter.beginInterval(tabSwitchName, id: signposter.makeSignpostID())
        signposter.emitEvent("tab_switch_surface")
        _ = surfaceID
        Self.state.withLock {
            $0.tab = OpenInterval(
                name: "tab_switch",
                start: DispatchTime.now(),
                signpostState: interval
            )
        }
    }

    public static func endTabSwitchInstall() {
        signposter.emitEvent("tab_switch_install")
    }

    public static func endTabSwitchCommitted() {
        finishTabOrConversation(isTab: true)
    }

    // MARK: - Conversation switch (selectThread → first publish → hydrate)

    public static func beginConversationSwitch(threadID: String) {
        let interval = signposter.beginInterval(conversationSwitchName, id: signposter.makeSignpostID())
        _ = threadID
        Self.state.withLock {
            $0.conversation = OpenInterval(
                name: "conversation_switch",
                start: DispatchTime.now(),
                signpostState: interval
            )
            $0.conversationDidPublish = false
        }
    }

    public static func markConversationFirstPublish() {
        let shouldEmit = state.withLock { current -> Bool in
            guard current.conversation != nil, !current.conversationDidPublish else { return false }
            current.conversationDidPublish = true
            return true
        }
        guard shouldEmit else { return }
        signposter.emitEvent("conversation_first_publish")
        let start = state.withLock { $0.conversation?.start }
        if let start {
            let ns = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
            record(Interval(name: "conversation_first_publish", nanoseconds: ns, onMainThread: Thread.isMainThread))
        }
    }

    public static func endConversationHydrate() {
        finishTabOrConversation(isTab: false)
    }

    // MARK: - SQLite main-thread wait

    public static func measureQueueSync<T>(onMainThread: Bool, body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now()
        let signpostState = onMainThread
            ? signposter.beginInterval(sqliteMainSyncName, id: signposter.makeSignpostID())
            : nil
        defer {
            let ns = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
            if let signpostState {
                signposter.endInterval(sqliteMainSyncName, signpostState)
            }
            recordQueueOccupied(nanoseconds: ns, onMainThread: onMainThread)
        }
        return try body()
    }

    public static func recordQueueOccupied(nanoseconds: UInt64, onMainThread: Bool) {
        guard nanoseconds > 0 else { return }
        state.withLock {
            $0.queueOccupiedNanoseconds &+= nanoseconds
        }
        guard onMainThread else { return }
        record(Interval(name: "sqlite_main_sync", nanoseconds: nanoseconds, onMainThread: true))
        state.withLock {
            $0.mainThreadSyncCount += 1
            if $0.mainThreadSyncNanoseconds.count >= recordedIntervalCapacity {
                $0.mainThreadSyncNanoseconds.removeFirst()
            }
            $0.mainThreadSyncNanoseconds.append(nanoseconds)
        }
        guard nanoseconds > slowMainSyncNanoseconds else { return }
#if DEBUG
        // EV-20: `Thread.callStackSymbols` symbolicates on the MAIN thread, right
        // after a main-thread SQLite wait already exceeded 2 ms — i.e. exactly
        // under lock contention. In release that was a positive feedback loop
        // (more contention → more main-thread symbolication). Debug only.
        let stack = Thread.callStackSymbols.prefix(16).joined(separator: "\n")
        state.withLock {
            $0.slowMainSyncLogCount += 1
            $0.lastSlowMainSyncStack = stack
        }
        NSLog(
            "SQLiteDB main-thread wait %.2fms\n%@",
            Double(nanoseconds) / 1_000_000.0,
            stack
        )
#else
        state.withLock { $0.slowMainSyncLogCount += 1 }
#endif
    }

    // MARK: - Private

    private static func finishTabOrConversation(isTab: Bool) {
        let opened: OpenInterval? = state.withLock { current in
            if isTab {
                let value = current.tab
                current.tab = nil
                return value
            }
            let value = current.conversation
            current.conversation = nil
            return value
        }
        guard let opened else { return }
        signposter.endInterval(
            isTab ? tabSwitchName : conversationSwitchName,
            opened.signpostState
        )
        let ns = DispatchTime.now().uptimeNanoseconds &- opened.start.uptimeNanoseconds
        record(Interval(
            name: isTab ? "tab_switch" : "conversation_switch",
            nanoseconds: ns,
            onMainThread: Thread.isMainThread
        ))
    }

    private static func record(_ interval: Interval) {
        state.withLock {
            if $0.recorded.count >= recordedIntervalCapacity {
                $0.recorded.removeFirst()
            }
            $0.recorded.append(interval)
        }
    }
}
