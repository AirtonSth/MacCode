import XCTest
import CoreModel

final class BotWorkspaceMaintenanceTests: XCTestCase {
    func test_maintenanceRefusesActiveAndWaitingClaimsAndBlocksNewStarts() throws {
        let registry = BotVMRunRegistry()
        let resource = BotID()
        let run = BotVMRunRegistry.Entry(threadID: AgentThreadID(), runID: AgentRunID(), title: "Running", workspace: "")
        XCTAssertNil(registry.tryBegin(botID: resource, entry: run))
        XCTAssertThrowsError(try registry.withWorkspaceMaintenance(resourceIDs: [resource]) {})
        registry.endRun(runID: run.runID)
        registry.addWaiting(botID: resource, threadID: run.threadID)
        XCTAssertThrowsError(try registry.withWorkspaceMaintenance(resourceIDs: [resource]) {})
        XCTAssertNotNil(registry.popWaitingIfFree(botID: resource))
        try registry.withWorkspaceMaintenance(resourceIDs: [resource]) {
            XCTAssertNotNil(registry.tryBegin(botID: resource, entry: run))
        }
        XCTAssertNil(registry.tryBegin(botID: resource, entry: run))
    }

    func test_failedMaintenanceAlwaysReleasesAllResources() throws {
        enum Failure: Error { case expected }
        let registry = BotVMRunRegistry()
        let a = BotID(), b = BotID()
        XCTAssertThrowsError(try registry.withWorkspaceMaintenance(resourceIDs: [a, b]) { throw Failure.expected })
        XCTAssertNil(registry.active(botID: a))
        XCTAssertNil(registry.active(botID: b))
        try registry.withWorkspaceMaintenance(resourceIDs: [a, b]) {}
    }

    func test_userControlAndWorkspaceMoveCannotAcquireEachOthersResource() throws {
        let control = BotComputerControl()
        let bot = BotID(), resource = BotID()
        control.configureResourceLookup { _, _ in resource }
        XCTAssertTrue(control.take(bot))
        XCTAssertThrowsError(try control.withWorkspaceMaintenance(resourceIDs: [resource], botIDs: [bot]) {})
        control.release(bot)
        try control.withWorkspaceMaintenance(resourceIDs: [resource], botIDs: [bot]) {
            XCTAssertFalse(control.take(bot))
            XCTAssertFalse(control.isControlledByUser(bot, resourceID: resource))
        }
        XCTAssertTrue(control.take(bot))
    }
}
