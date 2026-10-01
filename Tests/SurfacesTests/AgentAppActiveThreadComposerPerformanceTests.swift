import XCTest
import Combine
import CoreModel
import AgentRuntime
@testable import Persistence
@testable import Surfaces

@MainActor
final class AgentAppActiveThreadComposerPerformanceTests: XCTestCase {
    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    /// WHY: the native editor reports both prompt edits and caret movement. While
    /// a thread is active, neither input event may publish the transcript-bearing
    /// view model, or SwiftUI rebuilds the long conversation for every keystroke.
    func test_activeThreadComposerEditsStayOutOfTranscriptViewModel() throws {
        let fixture = try makeFixture()
        defer {
            fixture.vm.dispose()
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        fixture.vm.createThread(title: "active composer")
        let threadID = try XCTUnwrap(fixture.vm.selectedThreadId)
        fixture.vm.status = .running
        fixture.vm.messages = (0..<256).map { index in
            AgentMessage(
                threadId: threadID,
                role: .assistant,
                content: "historical transcript item \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        var transcriptViewModelPublishes = 0
        var composerPublishes = 0
        let vmCancellable = fixture.vm.objectWillChange.sink { transcriptViewModelPublishes += 1 }
        let composerCancellable = fixture.vm.composerState.objectWillChange.sink { composerPublishes += 1 }

        for index in 0..<64 {
            fixture.vm.prompt = "prompt \(index)"
            fixture.vm.composerCursorOffset = index
        }

        XCTAssertEqual(
            transcriptViewModelPublishes,
            0,
            "active-thread composer edits must not invalidate the transcript-bearing AgentAppViewModel"
        )
        XCTAssertEqual(fixture.vm.prompt, "prompt 63")
        XCTAssertEqual(fixture.vm.composerCursorOffset, 63)
        XCTAssertEqual(
            composerPublishes,
            128,
            "prompt and caret edits must still publish through the composer-local state"
        )

        withExtendedLifetime((vmCancellable, composerCancellable)) {}
    }

    /// WHY: a text callback runs on the AppKit main thread. Persisting every
    /// character synchronously competes with active stream painting, so edits
    /// must be coalesced while the final draft still reaches SQLite promptly.
    func test_activeThreadComposerDraftWritesAreDebounced() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.vm.dispose()
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        fixture.vm.createThread(title: "active composer draft")
        let threadID = try XCTUnwrap(fixture.vm.selectedThreadId)
        fixture.vm.status = .running
        fixture.vm.prompt = "draft text"
        fixture.vm.promptWasEdited()

        XCTAssertNotEqual(
            try fixture.vm.draftRepo?.get(
                threadId: threadID,
                providerInstanceId: AgentProvider.codex.rawValue
            )?.text,
            "draft text",
            "typing must not synchronously write SQLite on the main thread"
        )

        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(
            try fixture.vm.draftRepo?.get(
                threadId: threadID,
                providerInstanceId: AgentProvider.codex.rawValue
            )?.text,
            "draft text",
            "the coalesced draft must still be durable after the debounce window"
        )
    }

    private func makeFixture() throws -> (vm: AgentAppViewModel, rootURL: URL) {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-active-composer-" + UUID().uuidString)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: rootURL.path).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: rootURL.path,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db)
        )
        return (vm, rootURL)
    }
}
