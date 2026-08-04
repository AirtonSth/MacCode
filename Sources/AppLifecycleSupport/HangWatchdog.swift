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
    public var providerProcessCount: Int
    public var recoveryInFlight: Bool
    public var bootId: String
    public var pid: Int32
    public var sampleCountRequested: Int

    public init(
        providerProcessCount: Int = 0,
        recoveryInFlight: Bool = false,
        bootId: String = "",
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        sampleCountRequested: Int = 3
    ) {
        self.providerProcessCount = providerProcessCount
        self.recoveryInFlight = recoveryInFlight
        self.bootId = bootId
        self.pid = pid
        self.sampleCountRequested = sampleCountRequested
    }

    public var lifecycleLine: String {
        [
            "hang_breach",
            "providerProcesses=\(providerProcessCount)",
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

/// Off-main hang watchdog. Forensic only — callbacks must not flip run status.
public final class HangWatchdog: @unchecked Sendable {
    public typealias MainPinger = (@escaping @Sendable () -> Void) -> Void
    public typealias AwakeProvider = () -> HangWatchdogAwakeState
    public typealias SideContextProvider = () -> HangWatchdogSideContext
    public typealias BreachHandler = (HangWatchdogBreach) -> Void

    private let pingInterval: TimeInterval
    private let hangThreshold: TimeInterval
    private let mainPinger: MainPinger
    private let awakeProvider: AwakeProvider
    private let sideContextProvider: SideContextProvider
    private let onBreach: BreachHandler
    private let queue: DispatchQueue

    private var timer: DispatchSourceTimer?
    private var lastAck = Date()
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
        onBreach: @escaping BreachHandler = { _ in }
    ) {
        self.pingInterval = max(0.2, pingInterval)
        self.hangThreshold = max(pingInterval, hangThreshold)
        self.breachCooldown = max(0, breachCooldown)
        self.queue = queue
        self.mainPinger = mainPinger
        self.awakeProvider = awakeProvider
        self.sideContextProvider = sideContextProvider
        self.onBreach = onBreach
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
    public func evaluateForTests(now: Date, lastAck: Date) -> HangWatchdogBreach? {
        self.lastAck = lastAck
        return evaluate(now: now)
    }

    private func tick() {
        let now = Date()
        if let breach = evaluate(now: now) {
            onBreach(breach)
        }
        // Schedule main ping; acknowledgement updates lastAck off the main path.
        mainPinger { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.lastAck = Date()
            }
        }
    }

    private func evaluate(now: Date) -> HangWatchdogBreach? {
        let gap = now.timeIntervalSince(lastAck)
        let awake = awakeProvider()
        let kind = HangWatchdogClassifier.classifyGap(
            gapSeconds: gap,
            hangThresholdSeconds: hangThreshold,
            awake: awake
        )
        guard kind == .hangLikely else { return nil }
        if let lastBreachAt, now.timeIntervalSince(lastBreachAt) < breachCooldown {
            return nil
        }
        lastBreachAt = now
        return HangWatchdogBreach(
            gapSeconds: gap,
            kind: kind,
            awake: awake,
            sideContext: sideContextProvider(),
            at: now
        )
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
