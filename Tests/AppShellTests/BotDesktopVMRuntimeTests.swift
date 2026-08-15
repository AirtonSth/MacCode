import XCTest
import CoreModel
import Persistence
@testable import AppShell

private struct FixedVirtualizationProbe: BotDesktopVirtualizationProbe {
    let isSupported: Bool
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
}
