import Combine
import XCTest
import CoreModel
@testable import AppShell
@testable import AgentRuntime
@testable import Persistence
import Surfaces

@MainActor
final class BotsDeskActiveThreadComposerPerformanceTests: XCTestCase {
    func test_studioTyping_doesNotRepublishBotsViewModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotsStudioDraftPerformanceTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try AppContext(channel: .debug, appSupportOverride: root.path)
        let viewModel = BotsViewModel(context: context)
        let bot = try viewModel.create(name: "Piper", title: "Scout")
        viewModel.beginEdit(bot)

        var viewModelEmissions = 0
        var studioStateEmissions = 0
        let subscription = viewModel.objectWillChange.sink { _ in
            viewModelEmissions += 1
        }
        let studioSubscription = viewModel.studioState.objectWillChange.sink { _ in
            studioStateEmissions += 1
        }
        defer {
            subscription.cancel()
            studioSubscription.cancel()
        }

        viewModel.didEditStudioName("P")
        viewModel.didEditStudioName("Pi")

        XCTAssertEqual(
            viewModelEmissions,
            0,
            "Studio keystrokes must not rebuild the roster and every other Bots destination"
        )
        XCTAssertEqual(
            studioStateEmissions,
            2,
            "each keystroke must publish one atomic Studio draft update"
        )
        XCTAssertEqual(viewModel.studioDraft.name, "Pi")
        XCTAssertEqual(viewModel.studioDraft.handle, "pi")
    }

    func test_liveDeskReplay_doesNotRepublishDeskViewModelWhenComposerOrCaretChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotsDeskActiveThreadComposerPerformanceTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try AppContext(channel: .debug, appSupportOverride: root.path)
        let viewModel = BotsViewModel(context: context)
        let bot = try viewModel.create(name: "Piper", title: "Replay-backed composer")
        let thread = AgentThread(title: "Active replay", provider: .claude, model: "opus")
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(run)
        let replay = [
            AssistantEvent.turnStarted(turnId: "turn-live"),
            AssistantEvent.itemStarted(item: AssistantItem(
                id: "reasoning-live",
                turnId: "turn-live",
                type: .reasoning,
                state: .streaming,
                body: "replayed",
                startedAtMs: 1
            ))
        ]
        let writes = try replay.enumerated().map { index, event in
            let data = try JSONEncoder().encode(event)
            return AgentRunRepository.StreamWriteIntent(
                seq: index + 1,
                kind: event.debugDescription,
                payloadJSON: String(decoding: data, as: UTF8.self),
                providerEvent: nil
            )
        }
        try context.runRepo.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: writes,
            shouldPruneStreamEvents: false
        )
        let conversation = BotConversation(
            botID: bot.id,
            title: "Active replay",
            linkedAgentThreadID: thread.id
        )
        try context.botStore.upsertConversation(conversation)

        viewModel.openDesk(bot)
        XCTAssertTrue(viewModel.deskRunIsLive)
        XCTAssertEqual(viewModel.deskLiveTimeline.turns.first?.items.first?.body, "replayed")

        viewModel.applyDeskLiveEventForTesting(
            .itemDelta(itemId: "reasoning-live", bodyAppend: " live", outputAppend: nil, summary: nil),
            threadId: thread.id
        )
        XCTAssertEqual(viewModel.deskLiveTimeline.turns.first?.items.first?.body, "replayed live")

        var deskViewModelEmissions = 0
        var composerStateEmissions = 0
        let deskViewModelSubscription = viewModel.objectWillChange.sink { _ in
            deskViewModelEmissions += 1
        }
        let composerStateSubscription = viewModel.composerState.objectWillChange.sink { _ in
            composerStateEmissions += 1
        }
        defer {
            deskViewModelSubscription.cancel()
            composerStateSubscription.cancel()
        }

        // WHY: typing and caret movement while this real Desk replay is active
        // must not rebuild the view model body that projects the live timeline.
        viewModel.composerText = "h"
        viewModel.composerCursorOffset = 0
        viewModel.composerText = "hi"
        viewModel.composerCursorOffset = 2

        XCTAssertEqual(
            deskViewModelEmissions,
            0,
            "active Desk prompt/caret edits must not republish the transcript-owning view model"
        )
        XCTAssertGreaterThanOrEqual(
            composerStateEmissions,
            4,
            "each prompt/caret edit must still invalidate the composer subtree"
        )
        XCTAssertEqual(viewModel.composerText, "hi")
        XCTAssertEqual(viewModel.composerCursorOffset, 2)
    }
}
