import XCTest
@testable import AppShell

final class ScheduledTaskLaunchReconciliationTests: XCTestCase {
    func test_scheduledTaskAgentSkipsSharedDBLaunchReconciliation_becauseInteractiveRunsMustStayOwned() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("performLaunchRunReconciliation: false"),
            "Scheduled Task Agent must not reconcile running Agent App runs to interrupted on shared SQLite"
        )
    }

    func test_appContextSupportsSkippingLaunchReconciliation() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("performLaunchRunReconciliation: Bool = true"))
        XCTAssertTrue(source.contains("if performLaunchRunReconciliation"))
    }
}
