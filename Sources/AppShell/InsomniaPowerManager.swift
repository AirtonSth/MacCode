import Foundation
import AppKit
import IOKit.pwr_mgt
import CoreGraphics
import AgentRuntime

public struct InsomniaPowerOptions: Equatable, Sendable {
    public static let defaultSession = InsomniaPowerOptions(
        allowDisplaySleep: true,
        allowSystemSleepWhenDisplayClosed: false,
        allowScreenSaverAfter45MinutesOfInactivity: true
    )

    public let allowDisplaySleep: Bool
    public let allowSystemSleepWhenDisplayClosed: Bool
    public let allowScreenSaverAfter45MinutesOfInactivity: Bool

    public init(
        allowDisplaySleep: Bool,
        allowSystemSleepWhenDisplayClosed: Bool,
        allowScreenSaverAfter45MinutesOfInactivity: Bool
    ) {
        self.allowDisplaySleep = allowDisplaySleep
        self.allowSystemSleepWhenDisplayClosed = allowSystemSleepWhenDisplayClosed
        self.allowScreenSaverAfter45MinutesOfInactivity = allowScreenSaverAfter45MinutesOfInactivity
    }
}

public protocol InsomniaPowerManaging: AnyObject {
    @discardableResult
    func activate(reason: String, options: InsomniaPowerOptions) -> Bool
    func deactivate()
    func releaseProcessAssertions()
}

public final class MacOSInsomniaPowerManager: InsomniaPowerManaging {
    private static let screenSaverInactivityInterval: TimeInterval = 45 * 60
    private var systemSleepAssertion: IOPMAssertionID = 0
    private var closedDisplaySleepAssertion: IOPMAssertionID = 0
    private var displaySleepAssertion: IOPMAssertionID = 0
    private var clamshellSleepDisabled = false
    private var reason: String = "RemoteCode Insomnia"
    private var options: InsomniaPowerOptions = .defaultSession
    private var screenSaverTimer: Timer?
    private lazy var privilegedPMSet = PrivilegedPMSetSleepDisabler(
        runPrivilegedPMSet: { disabled, watchProcessID, stopFile, sessionDirectory in
            RunAsUserProcessBootstrap.runPrivilegedPMSet(
                disabled: disabled,
                watchProcessID: watchProcessID,
                stopFile: stopFile,
                sessionDirectory: sessionDirectory
            )
        },
        rootDomainSleepDisabled: { [weak self] in
            self?.rootDomainSleepDisabled() ?? false
        }
    )

    public init() {}

    @discardableResult
    public func activate(reason: String, options: InsomniaPowerOptions) -> Bool {
        if clamshellSleepDisabled, options.allowSystemSleepWhenDisplayClosed {
            deactivate()
        } else {
            releaseProcessAssertions()
        }
        self.reason = reason
        self.options = options

        let level = IOPMAssertionLevel(kIOPMAssertionLevelOn)
        let systemStatus = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            level,
            reason as CFString,
            &systemSleepAssertion
        )

        guard systemStatus == kIOReturnSuccess else {
            deactivate()
            return false
        }

        if !options.allowSystemSleepWhenDisplayClosed {
            guard createClosedDisplaySleepAssertion() else {
                deactivate()
                return false
            }
            // PERF: privileged pmset path is slow (admin dialog + poll).
            // Fire it on a background Task so activate() returns to the
            // main actor immediately; deactivate() is called if it fails.
            Task { [weak self] in
                guard let self else { return }
                if !(await self.ensureClamshellSleepDisabledAsync()) {
                    self.deactivate()
                }
            }
        }
        if shouldPreventDisplaySleep(), !createDisplaySleepAssertion() {
            deactivate()
            return false
        }
        startScreenSaverTimerIfNeeded()
        return true
    }

    public func releaseProcessAssertions() {
        screenSaverTimer?.invalidate()
        screenSaverTimer = nil
        if systemSleepAssertion != 0 {
            IOPMAssertionRelease(systemSleepAssertion)
            systemSleepAssertion = 0
        }
        if closedDisplaySleepAssertion != 0 {
            IOPMAssertionRelease(closedDisplaySleepAssertion)
            closedDisplaySleepAssertion = 0
        }
        releaseDisplaySleepAssertion()
    }

    public func deactivate() {
        releaseProcessAssertions()
        if clamshellSleepDisabled {
            if !setClamshellSleepDisabled(false) || rootDomainSleepDisabled() {
                // PERF: privileged pmset + verification poll are blocking ops.
                // Dispatch async so deactivate() returns to main actor immediately.
                Task { [weak self] in
                    await self?.runPrivilegedDeactivateAsync()
                }
            } else {
                clamshellSleepDisabled = rootDomainSleepDisabled()
            }
        }
    }

    private func createClosedDisplaySleepAssertion() -> Bool {
        guard closedDisplaySleepAssertion == 0 else { return true }
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &closedDisplaySleepAssertion
        )
        if status != kIOReturnSuccess {
            closedDisplaySleepAssertion = 0
        }
        return status == kIOReturnSuccess
    }

    private func setClamshellSleepDisabled(_ disabled: Bool) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        var connection = io_connect_t()
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            return false
        }
        defer { IOServiceClose(connection) }

        var outputCount: UInt32 = 0
        let input: [UInt64] = [disabled ? 1 : 0]
        let status = input.withUnsafeBufferPointer { buffer in
            IOConnectCallScalarMethod(
                connection,
                UInt32(kPMSetClamshellSleepState),
                buffer.baseAddress,
                1,
                nil,
                &outputCount
            )
        }
        guard status == kIOReturnSuccess else { return false }
        if rootDomainSleepDisabled(service) != disabled { return false }
        clamshellSleepDisabled = disabled
        return true
    }

    private func rootDomainSleepDisabled() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return rootDomainSleepDisabled(service)
    }

    private func rootDomainSleepDisabled(_ service: io_service_t) -> Bool {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "SleepDisabled" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return false
        }
        return (value as? Bool) == true
    }

    // PERF: async poll — uses Task.sleep instead of Thread.sleep so the
    // calling thread (never main) is not burned during the 2 s wait.
    private func waitForRootDomainSleepDisabledAsync(_ disabled: Bool) async -> Bool {
        let timeout: TimeInterval = 2
        let intervalNs: UInt64 = 50_000_000 // 50 ms
        let start = Date()
        while true {
            let elapsed = Date().timeIntervalSince(start)
            let satisfied = rootDomainSleepDisabled() == disabled
            switch InsomniaPollDecider.pollDecision(elapsed: elapsed, timeout: timeout, satisfied: satisfied) {
            case .done: return true
            case .timedOut: return false
            case .keepPolling: try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    // PERF: async variant of ensureClamshellSleepDisabled — the privileged
    // pmset helper is dispatched to a detached background task so the main
    // actor is never blocked.
    private func ensureClamshellSleepDisabledAsync() async -> Bool {
        if rootDomainSleepDisabled() {
            clamshellSleepDisabled = true
            return true
        }
        if setClamshellSleepDisabled(true) { return true }
        // Capture privilegedPMSet reference so the detached task can call it
        // without capturing self (avoids retain cycle and actor isolation issues).
        let pmSet = privilegedPMSet
        let succeeded = await Task.detached(priority: .userInitiated) {
            pmSet.setDisabled(true)
        }.value
        guard succeeded else {
            NSLog("RemoteCode Insomnia privileged pmset failed.")
            return false
        }
        let effective = rootDomainSleepDisabled()
        if effective { clamshellSleepDisabled = true }
        return effective
    }

    // PERF: async variant of the privileged-pmset disable path used in deactivate.
    // Both the cached-helper wait and the one-shot helper call are kept off the
    // main actor.
    private func runPrivilegedDeactivateAsync() async {
        if privilegedPMSet.disableUsingCachedPermission() {
            if !(await waitForRootDomainSleepDisabledAsync(false)) {
                NSLog("RemoteCode Insomnia cached pmset disable did not clear before timeout.")
            }
        } else {
            // One-shot privileged disable — the helper blocks; run detached.
            let pmSet = privilegedPMSet
            let succeeded = await Task.detached(priority: .userInitiated) {
                pmSet.setDisabled(false)
            }.value
            if succeeded {
                clamshellSleepDisabled = false
            }
        }
        clamshellSleepDisabled = rootDomainSleepDisabled()
    }

    private func createDisplaySleepAssertion() -> Bool {
        guard displaySleepAssertion == 0 else { return true }
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &displaySleepAssertion
        )
        return status == kIOReturnSuccess
    }

    private func releaseDisplaySleepAssertion() {
        if displaySleepAssertion != 0 {
            IOPMAssertionRelease(displaySleepAssertion)
            displaySleepAssertion = 0
        }
    }

    private func shouldPreventDisplaySleep() -> Bool {
        if options.allowDisplaySleep { return false }
        if options.allowScreenSaverAfter45MinutesOfInactivity,
           inactiveLongEnoughForScreenSaver() {
            return false
        }
        return true
    }

    private func inactiveLongEnoughForScreenSaver() -> Bool {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)
            >= Self.screenSaverInactivityInterval
    }

    private func startScreenSaverTimerIfNeeded() {
        guard !options.allowDisplaySleep,
              options.allowScreenSaverAfter45MinutesOfInactivity else { return }
        scheduleNextScreenSaverCheck()
    }

    /// PERF-MAC_SHELL_WINDOW-007: instead of a fixed 60s poll for the
    /// app's lifetime, reschedule adaptively: when the user is far below
    /// the 45m inactivity threshold, sleep most of the way to it (capped at
    /// 5 minutes) so the timer fires rarely; only near the threshold do we
    /// poll at the fine 60s cadence. This lets App Nap engage between
    /// checks while keeping the assertion transition accurate.
    private func scheduleNextScreenSaverCheck() {
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)
        let remaining = Self.screenSaverInactivityInterval - idle
        let interval: TimeInterval = remaining <= 60 ? 60 : min(300, remaining - 30)
        screenSaverTimer?.invalidate()
        screenSaverTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.refreshDisplaySleepAssertion()
        }
    }

    private func refreshDisplaySleepAssertion() {
        if shouldPreventDisplaySleep() {
            _ = createDisplaySleepAssertion()
        } else {
            releaseDisplaySleepAssertion()
        }
        // Keep the adaptive cadence going while screen-saver mode is active.
        if !options.allowDisplaySleep, options.allowScreenSaverAfter45MinutesOfInactivity {
            scheduleNextScreenSaverCheck()
        }
    }

    deinit {
        releaseProcessAssertions()
    }
}

// MARK: - Poll decision helper (pure, testable)

/// Decides the next action for a verification poll loop.
enum InsomniaPollDecision: Equatable {
    case keepPolling
    case done
    case timedOut
}

/// Pure, nonisolated decision logic for the root-domain sleep-disabled
/// verification poll. Extracted so it can be unit-tested without any
/// manager state or async machinery.
enum InsomniaPollDecider {
    nonisolated static func pollDecision(
        elapsed: TimeInterval,
        timeout: TimeInterval,
        satisfied: Bool
    ) -> InsomniaPollDecision {
        if satisfied { return .done }
        if elapsed >= timeout { return .timedOut }
        return .keepPolling
    }
}

// MARK: -

final class PrivilegedPMSetSleepDisabler: @unchecked Sendable {
    private struct Session {
        let directory: URL
        let stopFile: URL
    }

    private let fileManager: FileManager
    private let processIdentifier: Int32
    private let makeSessionDirectory: () -> URL
    private let runPrivilegedPMSet: (Bool, Int32?, URL?, URL?) -> Bool
    private let rootDomainSleepDisabled: () -> Bool
    private var session: Session?

    init(
        fileManager: FileManager = .default,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        makeSessionDirectory: @escaping () -> URL = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("RemoteCodeInsomnia-\(UUID().uuidString)", isDirectory: true)
        },
        runPrivilegedPMSet: @escaping (Bool, Int32?, URL?, URL?) -> Bool,
        rootDomainSleepDisabled: @escaping () -> Bool
    ) {
        self.fileManager = fileManager
        self.processIdentifier = processIdentifier
        self.makeSessionDirectory = makeSessionDirectory
        self.runPrivilegedPMSet = runPrivilegedPMSet
        self.rootDomainSleepDisabled = rootDomainSleepDisabled
    }

    @discardableResult
    func setDisabled(_ disabled: Bool) -> Bool {
        if disabled {
            return enableWithReusablePermission()
        }
        let succeeded = runOneShotPMSet(disabled: false)
        if succeeded {
            session = nil
        }
        return succeeded
    }

    @discardableResult
    func disableUsingCachedPermission() -> Bool {
        guard let session else { return false }
        do {
            try Data().write(to: session.stopFile, options: .atomic)
            self.session = nil
            return true
        } catch {
            NSLog("RemoteCode Insomnia failed to signal cached pmset helper: %@", error.localizedDescription)
            return false
        }
    }

    private func enableWithReusablePermission() -> Bool {
        let session = makeSession()
        do {
            try fileManager.createDirectory(
                at: session.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            NSLog("RemoteCode Insomnia failed to create pmset helper state: %@", error.localizedDescription)
            return false
        }

        guard runPrivilegedPMSet(true, processIdentifier, session.stopFile, session.directory) else {
            removeSessionDirectory(session)
            return false
        }
        guard rootDomainSleepDisabled() else {
            _ = signal(session)
            return false
        }
        self.session = session
        return true
    }

    private func runOneShotPMSet(disabled: Bool) -> Bool {
        runPrivilegedPMSet(disabled, nil, nil, nil)
    }

    private func makeSession() -> Session {
        let directory = makeSessionDirectory()
        return Session(
            directory: directory,
            stopFile: directory.appendingPathComponent("disable", isDirectory: false)
        )
    }

    private func signal(_ session: Session) -> Bool {
        do {
            try Data().write(to: session.stopFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func removeSessionDirectory(_ session: Session) {
        try? fileManager.removeItem(at: session.directory)
    }

}
