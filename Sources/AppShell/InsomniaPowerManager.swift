import Foundation
import AppKit
import IOKit.pwr_mgt
import CoreGraphics

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
            let closedDisplayReady = createClosedDisplaySleepAssertion()
                && ensureClamshellSleepDisabled()
            guard closedDisplayReady else {
                deactivate()
                return false
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
                _ = runPrivilegedPMSetDisableSleep(false)
            }
            clamshellSleepDisabled = rootDomainSleepDisabled()
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

    private func runPrivilegedPMSetDisableSleep(_ disabled: Bool) -> Bool {
        let value = disabled ? "1" : "0"
        let command = "/usr/bin/pmset -a disablesleep \(value)"
        guard runPrivilegedShellCommand(command) else {
            NSLog("RemoteCode Insomnia privileged pmset failed.")
            return false
        }
        let effective = rootDomainSleepDisabled()
        guard effective == disabled else { return false }
        clamshellSleepDisabled = disabled
        return true
    }

    private func ensureClamshellSleepDisabled() -> Bool {
        if rootDomainSleepDisabled() {
            clamshellSleepDisabled = true
            return true
        }
        return setClamshellSleepDisabled(true) || runPrivilegedPMSetDisableSleep(true)
    }

    private func runPrivilegedShellCommand(_ command: String) -> Bool {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escapedCommand)\" with administrator privileges"
        var error: NSDictionary?
        guard NSAppleScript(source: source)?.executeAndReturnError(&error) != nil else {
            if let error {
                NSLog("RemoteCode Insomnia privileged command failed: %@", error)
            }
            return false
        }
        return true
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
        screenSaverTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshDisplaySleepAssertion()
        }
    }

    private func refreshDisplaySleepAssertion() {
        if shouldPreventDisplaySleep() {
            _ = createDisplaySleepAssertion()
        } else {
            releaseDisplaySleepAssertion()
        }
    }

    deinit {
        releaseProcessAssertions()
    }
}
