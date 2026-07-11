import AppKit
import XCTest
@testable import AppShell

@MainActor
final class PetSystemActivityMonitorTests: XCTestCase {
    func test_mapsEverySystemNotificationToOneSemanticCallback() async {
        let workspaceCenter = NotificationCenter()
        let applicationCenter = NotificationCenter()
        let monitor = PetSystemActivityMonitor(
            workspaceNotificationCenter: workspaceCenter,
            applicationNotificationCenter: applicationCenter
        )
        var locks: [Bool] = []
        var wakes = 0
        var screenChanges = 0
        var accessibilityChanges = 0
        let callbacks = expectation(description: "all callbacks")
        callbacks.expectedFulfillmentCount = 10
        monitor.onScreenLockChanged = { locks.append($0); callbacks.fulfill() }
        monitor.onWake = { wakes += 1; callbacks.fulfill() }
        monitor.onScreenParametersChanged = { screenChanges += 1; callbacks.fulfill() }
        monitor.onAccessibilityDisplayOptionsChanged = { accessibilityChanges += 1; callbacks.fulfill() }
        monitor.start()
        defer { monitor.stop() }

        workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        await fulfillment(of: [callbacks], timeout: 1)
        XCTAssertEqual(locks, [true, false, true, false, true, false])
        XCTAssertEqual(wakes, 2)
        XCTAssertEqual(screenChanges, 1)
        XCTAssertEqual(accessibilityChanges, 1)
    }

    func test_startIsIdempotentAndStopRemovesEveryObserver() async {
        let workspaceCenter = NotificationCenter()
        let applicationCenter = NotificationCenter()
        let monitor = PetSystemActivityMonitor(
            workspaceNotificationCenter: workspaceCenter,
            applicationNotificationCenter: applicationCenter
        )
        var locks: [Bool] = []
        var wakes = 0
        let firstCycle = expectation(description: "one screen sleep and wake cycle")
        firstCycle.expectedFulfillmentCount = 3
        monitor.onScreenLockChanged = { locks.append($0); firstCycle.fulfill() }
        monitor.onWake = { wakes += 1; firstCycle.fulfill() }
        monitor.start()
        monitor.start()

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await fulfillment(of: [firstCycle], timeout: 1)
        XCTAssertEqual(locks, [true, false], "Calling start twice must not duplicate observers.")
        XCTAssertEqual(wakes, 1, "Calling start twice must not duplicate observers.")

        monitor.stop()
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(locks, [true, false], "Stopped monitors must deliver no callbacks.")
        XCTAssertEqual(wakes, 1, "Stopped monitors must deliver no callbacks.")
    }
}
