import XCTest
@testable import AppShell
import CoreModel

@MainActor
final class BotSecretStudioTests: XCTestCase {
    func test_studioSecretBindingsSaveOnlySelectedBotAndRemove() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-secret-studio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try AppContext(channel: .debug, appSupportOverride: root.path)
        let router = AppCommandRouter(context: context)
        context.router = router
        let secretStore = InMemoryBotSecretStore()
        let viewModel = BotsViewModel(context: context, router: router, secretStore: secretStore)
        router.botsViewModel = viewModel

        let selectedBot = try viewModel.create(name: "Selected", title: "Selected bot")
        let anotherBot = try viewModel.create(name: "Another", title: "Another bot")
        viewModel.openStudio(selectedBot)

        viewModel.studioState.secretNameDraft = "SERVICE_TOKEN"
        viewModel.studioState.secretValueDraft = "selected-value"
        viewModel.saveBotSecret()

        XCTAssertEqual(try secretStore.load(botID: selectedBot.id, name: "SERVICE_TOKEN"), "selected-value")
        XCTAssertEqual(viewModel.studioState.secretValueDraft, "")
        XCTAssertNil(try secretStore.load(botID: anotherBot.id, name: "SERVICE_TOKEN"))

        viewModel.removeBotSecret("SERVICE_TOKEN")

        XCTAssertNil(try secretStore.load(botID: selectedBot.id, name: "SERVICE_TOKEN"))
    }
}
