import XCTest
import CoreModel
import Persistence
@testable import AppShell

private final class FixedVirtualizationProbe: BotDesktopVirtualizationProbe {
    let isSupported: Bool
    var bootResult: BotDesktopVMBootAttempt
    var haltCount = 0

    init(isSupported: Bool, bootResult: BotDesktopVMBootAttempt = BotDesktopVMBootAttempt(didStart: false, failure: "unused")) {
        self.isSupported = isSupported
        self.bootResult = bootResult
    }

    func boot(diskImage: URL) -> BotDesktopVMBootAttempt { bootResult }

    func halt() { haltCount += 1 }
}

final class BotDesktopVMRuntimeTests: XCTestCase {
    func test_startWithoutGuestImageStaysStopped_becauseHonestyMustMatchWhatRuns() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bot-desktops-rt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = BotDesktopVMRuntime(
            store: BotDesktopVMStore(root: root),
            probe: FixedVirtualizationProbe(isSupported: true)
        )
        let botID = BotID()

        let started = try runtime.start(botID: botID)
        XCTAssertEqual(started.state, .stopped)
        XCTAssertEqual(started.lastError, BotDesktopVMIdentity.noGuestImageCode)
        XCTAssertTrue(started.virtualizationSupported)
        XCTAssertTrue(started.honestyLabel.localizedCaseInsensitiveContains("no guest image"))

        let stopped = try runtime.stop(botID: botID)
        XCTAssertEqual(stopped.id, started.id)
        XCTAssertEqual(stopped.state, .stopped)
    }

    func test_startReportsUnsupported_whenVirtualizationProbeIsOff() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bot-desktops-rt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = BotDesktopVMRuntime(
            store: BotDesktopVMStore(root: root),
            probe: FixedVirtualizationProbe(isSupported: false)
        )

        let started = try runtime.start(botID: BotID())
        XCTAssertEqual(started.lastError, BotDesktopVMIdentity.virtualizationUnsupportedCode)
        XCTAssertEqual(started.state, .stopped)
    }

    func test_startWithDiskImageAttemptsHypervisorBoot_becauseAGuestFileMustNotBeIgnored() throws {
        // WHY: A Disk.img next to the identity is a real guest artifact. Start
        // must call Virtualization.framework and persist running or a failed boot.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bot-desktops-rt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = FixedVirtualizationProbe(
            isSupported: true,
            bootResult: BotDesktopVMBootAttempt(didStart: false, failure: "The disk image is not a valid virtual disk.")
        )
        let store = BotDesktopVMStore(root: root)
        let runtime = BotDesktopVMRuntime(store: store, probe: probe)
        let botID = BotID()
        let identity = try store.ensure(botID: botID)
        try Data(repeating: 0, count: 64).write(
            to: URL(fileURLWithPath: identity.bundlePath).appendingPathComponent("Disk.img")
        )

        let started = try runtime.start(botID: botID)
        XCTAssertEqual(started.state, .failed)
        XCTAssertEqual(started.lastError, BotDesktopVMIdentity.bootFailedCode)
        XCTAssertEqual(started.lastErrorDetail, "The disk image is not a valid virtual disk.")
        XCTAssertTrue(started.honestyLabel.localizedCaseInsensitiveContains("boot failed"))
        XCTAssertTrue(started.honestyLabel.localizedCaseInsensitiveContains("not isolated"))
        XCTAssertFalse(started.honestyLabel.localizedCaseInsensitiveContains("active now"))

        let stopped = try runtime.stop(botID: botID)
        XCTAssertEqual(probe.haltCount, 1)
        XCTAssertEqual(stopped.state, .stopped)
    }

    func test_startPersistsRunningOnlyWhenHypervisorStarts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bot-desktops-rt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotDesktopVMStore(root: root)
        let runtime = BotDesktopVMRuntime(
            store: store,
            probe: FixedVirtualizationProbe(
                isSupported: true,
                bootResult: BotDesktopVMBootAttempt(didStart: true)
            )
        )
        let botID = BotID()
        let identity = try store.ensure(botID: botID)
        try Data(repeating: 0, count: 64).write(
            to: URL(fileURLWithPath: identity.bundlePath).appendingPathComponent("Disk.img")
        )

        let started = try runtime.start(botID: botID)
        XCTAssertEqual(started.state, .running)
        XCTAssertNil(started.lastError)
        XCTAssertTrue(started.honestyLabel.localizedCaseInsensitiveContains("running"))
        XCTAssertTrue(started.honestyLabel.localizedCaseInsensitiveContains("not isolated"))
    }

    func test_startPersistsStarting_whenHypervisorIsStillComingUp() throws {
        // WHY: VZ state 4 is starting. Reporting boot-failed while the guest
        // is still coming up is a lie and hides a live Virtualization session.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bot-desktops-rt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotDesktopVMStore(root: root)
        let runtime = BotDesktopVMRuntime(
            store: store,
            probe: FixedVirtualizationProbe(
                isSupported: true,
                bootResult: BotDesktopVMBootAttempt(didStart: false, isStarting: true)
            )
        )
        let botID = BotID()
        let identity = try store.ensure(botID: botID)
        try Data(repeating: 0, count: 64).write(
            to: URL(fileURLWithPath: identity.bundlePath).appendingPathComponent("Disk.img")
        )

        let started = try runtime.start(botID: botID)
        XCTAssertEqual(started.state, .starting)
        XCTAssertNil(started.lastError)
        XCTAssertTrue(started.honestyLabel.localizedCaseInsensitiveContains("starting"))
        XCTAssertTrue(started.honestyLabel.localizedCaseInsensitiveContains("not isolated"))
        XCTAssertFalse(started.honestyLabel.localizedCaseInsensitiveContains("boot failed"))
    }

    func test_systemProbeSourceInstallsEFIBootLoader_becauseNilBootLoaderCannotStartAGuest() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotDesktopVMRuntime.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("VZEFIBootLoader"), "Disk.img start must set an EFI boot loader")
        XCTAssertTrue(source.contains("config.bootLoader = bootLoader"))
        XCTAssertFalse(source.contains("Isolated network"))
        XCTAssertFalse(source.contains("Take over"))
    }
}
