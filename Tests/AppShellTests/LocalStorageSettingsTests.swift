import XCTest
@testable import AppShell
import Persistence

@MainActor
final class LocalStorageSettingsTests: XCTestCase {
    private func makeContext() throws -> (AppContext, String) {
        let directory = NSTemporaryDirectory() + "RC2StorageSettings-" + UUID().uuidString
        return (try AppContext(channel: .debug, appSupportOverride: directory), directory)
    }

    func test_refreshStorageUsagePublishesAllBudgetClassesForVisiblePanel() async throws {
        let (context, directory) = try makeContext()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        _ = try ReversibleContentStore(db: context.db).store(Data(repeating: 0x61, count: 64))
        let attachmentSource = context.appSupportDirectory.appendingPathComponent("settings-attachment.txt")
        try Data(repeating: 0x62, count: 32).write(to: attachmentSource)
        _ = try AgentAttachmentStore(
            root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
        ).stage(path: attachmentSource.path)
        let viewModel = SettingsViewModel(context: context)

        await viewModel.refreshStorageUsage()

        let snapshot = try XCTUnwrap(viewModel.storageSnapshot)
        XCTAssertEqual(snapshot.classes.map(\.storageClass), LocalStorageClass.allCases)
        XCTAssertEqual(snapshot.classes.first(where: { $0.storageClass == .reversibleContent })?.payloadBytes, 64)
        XCTAssertEqual(snapshot.classes.first(where: { $0.storageClass == .attachmentBlobs })?.payloadBytes, 32,
                       "the visible Settings panel must use the production attachment root")
        XCTAssertFalse(viewModel.storageOperationInProgress)
    }

    func test_cleanupActionUpdatesPanelAndExplainsOutcome() async throws {
        let (context, directory) = try makeContext()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = ReversibleContentStore(db: context.db)
        let handle = try store.store("expired", at: Date(timeIntervalSince1970: 1))
        let viewModel = SettingsViewModel(context: context)

        await viewModel.cleanUpExpiredStorage(compact: false)

        XCTAssertNil(try store.retrieve(handle))
        XCTAssertEqual(viewModel.storageSnapshot?.classes.first(where: {
            $0.storageClass == .reversibleContent
        })?.rowCount, 0)
        XCTAssertEqual(viewModel.storageOperationStatus, "Removed 1 expired item.")
        XCTAssertFalse(viewModel.storageOperationInProgress)
    }
}
