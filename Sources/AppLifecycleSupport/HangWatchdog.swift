import Foundation
import Darwin

/// Forensic-only MainActor hang detector (plan-final W0).
///
/// Pings the main queue periodically from an off-main timer. When acknowledgements
/// stop while the host is still awake, records a breach. **Never** mutates agent
/// run/thread status — only diagnostics.
public enum HangWatchdogAwakeState: String, Sendable, Equatable {
    case awake
    case displaySleep
    case appNap
    case unknown
}

/// Pure classification of a heartbeat gap. Sleep-aware: a long gap during
/// display sleep is not a hang (plan-final E-F-003).
public enum HangWatchdogGapKind: String, Sendable, Equatable {
    case hangLikely
    case suspendedOrSleep
    case normal
}

public enum HangWatchdogClassifier {
    /// Classifies an observed gap between scheduled main pings.
    /// - Parameters:
    ///   - gapSeconds: wall time since last main acknowledgement
    ///   - hangThresholdSeconds: breach threshold while awake
    ///   - awake: current host awake state
    public static func classifyGap(
        gapSeconds: TimeInterval,
        hangThresholdSeconds: TimeInterval,
        awake: HangWatchdogAwakeState
    ) -> HangWatchdogGapKind {
        guard gapSeconds >= hangThresholdSeconds else { return .normal }
        switch awake {
        case .displaySleep, .appNap:
            return .suspendedOrSleep
        case .awake:
            return .hangLikely
        case .unknown:
            // Fail closed toward suspended so we never claim hang without awake proof.
            return .suspendedOrSleep
        }
    }

    /// Boot continuity: when boot UUID changes, prior PID samples belong to another boot.
    public static func bootIdChanged(previous: String?, current: String) -> Bool {
        guard let previous, !previous.isEmpty else { return false }
        return previous != current
    }
}

/// Side-context pack captured on hang breach (allowlisted, no secrets).
public struct HangWatchdogSideContext: Sendable, Equatable {
    /// Active agent threads (not OS provider processes; heartbeats report those).
    public var activeAgentThreadCount: Int
    public var recoveryInFlight: Bool
    public var bootId: String
    public var pid: Int32
    public var sampleCountRequested: Int

    public init(
        activeAgentThreadCount: Int = 0,
        recoveryInFlight: Bool = false,
        bootId: String = "",
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        sampleCountRequested: Int = 3
    ) {
        self.activeAgentThreadCount = activeAgentThreadCount
        self.recoveryInFlight = recoveryInFlight
        self.bootId = bootId
        self.pid = pid
        self.sampleCountRequested = sampleCountRequested
    }

    public var lifecycleLine: String {
        [
            "hang_breach",
            "activeAgentThreads=\(activeAgentThreadCount)",
            "recoveryInFlight=\(recoveryInFlight ? 1 : 0)",
            "bootId=\(bootId)",
            "pid=\(pid)",
            "samplesRequested=\(sampleCountRequested)"
        ].joined(separator: " ")
    }
}

public struct HangWatchdogBreach: Sendable, Equatable {
    public var gapSeconds: TimeInterval
    public var kind: HangWatchdogGapKind
    public var awake: HangWatchdogAwakeState
    public var sideContext: HangWatchdogSideContext
    public var at: Date

    public init(
        gapSeconds: TimeInterval,
        kind: HangWatchdogGapKind,
        awake: HangWatchdogAwakeState,
        sideContext: HangWatchdogSideContext,
        at: Date = Date()
    ) {
        self.gapSeconds = gapSeconds
        self.kind = kind
        self.awake = awake
        self.sideContext = sideContext
        self.at = at
    }
}

/// Thread-safe box for awake state (shared between NSWorkspace observers and watchdog).
public final class HangWatchdogAwakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: HangWatchdogAwakeState
    public init(initial: HangWatchdogAwakeState) { _value = initial }
    public var value: HangWatchdogAwakeState {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Off-main hang watchdog. Forensic only — callbacks must not flip run status.
public final class HangWatchdog: @unchecked Sendable {
    public typealias MainPinger = (@escaping @Sendable () -> Void) -> Void
    public typealias AwakeProvider = () -> HangWatchdogAwakeState
    public typealias SideContextProvider = () -> HangWatchdogSideContext
    public typealias BreachHandler = (HangWatchdogBreach) -> Void
    /// Called on the watchdog queue every tick with the current gap, its kind,
    /// and the last acknowledgement (constant for the whole hang episode).
    public typealias GapObserver = (_ gapSeconds: TimeInterval, _ kind: HangWatchdogGapKind, _ episodeStart: Date) -> Void

    private let pingInterval: TimeInterval
    private let hangThreshold: TimeInterval
    private let mainPinger: MainPinger
    private let awakeProvider: AwakeProvider
    private let sideContextProvider: SideContextProvider
    private let onBreach: BreachHandler
    private let gapObserver: GapObserver?
    private let queue: DispatchQueue

    private var timer: DispatchSourceTimer?
    private var lastAck = Date()
    private var lastAckUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lastBreachAt: Date?
    private let breachCooldown: TimeInterval
    private var started = false

    public init(
        pingInterval: TimeInterval = 1.0,
        hangThreshold: TimeInterval = 2.0,
        breachCooldown: TimeInterval = 30.0,
        queue: DispatchQueue = DispatchQueue(label: "io.remotecode.hang-watchdog"),
        mainPinger: @escaping MainPinger = { ack in
            DispatchQueue.main.async { ack() }
        },
        awakeProvider: @escaping AwakeProvider = { .unknown },
        sideContextProvider: @escaping SideContextProvider = { HangWatchdogSideContext() },
        onBreach: @escaping BreachHandler = { _ in },
        gapObserver: GapObserver? = nil
    ) {
        self.pingInterval = max(0.2, pingInterval)
        self.hangThreshold = max(pingInterval, hangThreshold)
        self.breachCooldown = max(0, breachCooldown)
        self.queue = queue
        self.mainPinger = mainPinger
        self.awakeProvider = awakeProvider
        self.sideContextProvider = sideContextProvider
        self.onBreach = onBreach
        self.gapObserver = gapObserver
    }

    public func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.lastAck = Date()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.pingInterval, repeating: self.pingInterval)
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.started = false
        }
    }

    /// Test seam: force a tick evaluation with a synthetic last-ack age.
    public func evaluateForTests(
        now: Date,
        lastAck: Date,
        wallGap: TimeInterval? = nil,
        uptimeGap: TimeInterval? = nil
    ) -> HangWatchdogBreach? {
        self.lastAck = lastAck
        return evaluate(now: now, wallGapOverride: wallGap, uptimeGapOverride: uptimeGap)
    }

    private func tick() {
        let now = Date()
        if let breach = evaluate(now: now) {
            onBreach(breach)
        }
        if let gapObserver {
            let gap = classify(now: now)
            gapObserver(gap.wallGap, gap.kind, lastAck)
        }
        // Schedule main ping; acknowledgement updates lastAck off the main path.
        mainPinger { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.lastAck = Date()
                self.lastAckUptime = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    private func evaluate(
        now: Date,
        wallGapOverride: TimeInterval? = nil,
        uptimeGapOverride: TimeInterval? = nil
    ) -> HangWatchdogBreach? {
        let (wallGap, awake, kind) = classify(
            now: now,
            wallGapOverride: wallGapOverride,
            uptimeGapOverride: uptimeGapOverride
        )
        // Record sleep gaps too (distinct kind) so the sleep branch leaves evidence.
        guard kind == .hangLikely || kind == .suspendedOrSleep else { return nil }
        if kind == .hangLikely {
            if let lastBreachAt, now.timeIntervalSince(lastBreachAt) < breachCooldown {
                return nil
            }
            lastBreachAt = now
        }
        return HangWatchdogBreach(
            gapSeconds: wallGap,
            kind: kind,
            awake: awake,
            sideContext: sideContextProvider(),
            at: now
        )
    }

    private func classify(
        now: Date,
        wallGapOverride: TimeInterval? = nil,
        uptimeGapOverride: TimeInterval? = nil
    ) -> (wallGap: TimeInterval, awake: HangWatchdogAwakeState, kind: HangWatchdogGapKind) {
        let wallGap = wallGapOverride ?? now.timeIntervalSince(lastAck)
        let uptimeGap = uptimeGapOverride ?? max(0, ProcessInfo.processInfo.systemUptime - lastAckUptime)
        // Wall clock advances during sleep; uptime does not. Large wall≫uptime ⇒ sleep.
        var awake = awakeProvider()
        if wallGap >= hangThreshold, wallGap > uptimeGap + max(1.0, hangThreshold) {
            awake = .displaySleep
        }
        let kind = HangWatchdogClassifier.classifyGap(
            gapSeconds: wallGap,
            hangThresholdSeconds: hangThreshold,
            awake: awake
        )
        return (wallGap, awake, kind)
    }
}

/// Best-effort current boot UUID (empty when unavailable).
public enum HostBootIdentity {
    public static func currentBootId() -> String {
        var size = 0
        sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        guard size > 1 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        let rc = sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0)
        guard rc == 0 else { return "" }
        return String(cString: buffer)
    }
}
