import XCTest
import Combine
import CoreModel
import AgentRuntime
@testable import Persistence
@testable import Surfaces

/// AA-13 / CH-11: composer keystroke publishes and suggestion-body allocations.
///
/// WHY: the native editor reports the caret from both `textDidChange` and
/// `textViewDidChangeSelection`. `@Published` assignment always fires
/// `objectWillChange`, so an unchanged UTF-16 offset still invalidated the
/// composer subtree. Suggestion chrome then allocated `map(\.id)` plus
/// `Array(enumerated())` on every body even when the rows were identical.
@MainActor
final class AgentComposerTypingHotspotTests: XCTestCase {

    func test_identicalCursorOffsetAssignment_doesNotPublish() {
        // WHY: a keystroke reports the same caret twice. Republishing the
        // composer object for an unchanged offset is a wasted SwiftUI body.
        let state = AgentComposerState()
        var publishes = 0
        let sub = state.objectWillChange.sink { publishes += 1 }

        state.cursorOffset = 4
        XCTAssertEqual(publishes, 1, "the first caret assignment must publish")

        for _ in 0..<64 {
            state.cursorOffset = 4
        }

        XCTAssertEqual(
            publishes,
            1,
            "identical cursorOffset assignment must not publish objectWillChange"
        )
        XCTAssertEqual(state.cursorOffset, 4)
        withExtendedLifetime(sub) {}
    }

    func test_changedCursorOffset_publishesOncePerMove() {
        let state = AgentComposerState()
        var publishes = 0
        let sub = state.objectWillChange.sink { publishes += 1 }

        state.cursorOffset = 0
        state.cursorOffset = 1
        state.cursorOffset = 1
        state.cursorOffset = 2

        XCTAssertEqual(publishes, 3, "only actual caret moves may publish")
        XCTAssertEqual(state.cursorOffset, 2)
        withExtendedLifetime(sub) {}
    }

    func test_composerCursorOffsetProxy_skipsIdenticalAssignment() throws {
        // WHY: Agent App wires onCursorMoved through vm.composerCursorOffset.
        // The proxy must inherit the equality guard so call-site assignment
        // of an unchanged offset is a no-op publish.
        let (vm, rootURL) = try makeVM()
        defer {
            vm.dispose()
            try? FileManager.default.removeItem(at: rootURL)
        }

        var composerPublishes = 0
        var transcriptPublishes = 0
        let composerSub = vm.composerState.objectWillChange.sink { composerPublishes += 1 }
        let vmSub = vm.objectWillChange.sink { transcriptPublishes += 1 }

        vm.composerCursorOffset = 12
        for _ in 0..<32 {
            vm.composerCursorOffset = 12
        }

        XCTAssertEqual(composerPublishes, 1)
        XCTAssertEqual(transcriptPublishes, 0, "caret must stay off the transcript VM")
        XCTAssertEqual(vm.composerCursorOffset, 12)
        withExtendedLifetime((composerSub, vmSub)) {}
    }

    func test_keystrokeDuplicateCursorCallbacks_publishOnce() {
        // WHY: Coordinator.reportCursor is invoked from textDidChange and
        // textViewDidChangeSelection with the same new offset. Before the
        // equality guard that was 2 composer publishes per key for caret
        // alone; after, the second callback is free.
        let state = AgentComposerState()
        var publishes = 0
        let sub = state.objectWillChange.sink { publishes += 1 }

        simulateKeystrokeCursorCallbacks(on: state, offset: 7)
        simulateKeystrokeCursorCallbacks(on: state, offset: 7)
        simulateKeystrokeCursorCallbacks(on: state, offset: 8)

        XCTAssertEqual(
            publishes,
            2,
            "two keystrokes that move 7 then 8 must publish twice, not four times"
        )
        withExtendedLifetime(sub) {}
    }

    func test_suggestionOnChange_observesEquatableArrayNotMappedIds() throws {
        // WHY: `onChange(of: suggestions.map(\.id))` allocates a new [String]
        // on every composer body, even when the rows are unchanged.
        let chrome = try source("Sources/Surfaces/AgentChatTranscriptChrome.swift")
        XCTAssertFalse(
            chrome.contains("suggestions.map(\\.id)"),
            "composer onChange must not allocate map(\\ .id) per body"
        )
        XCTAssertTrue(
            chrome.contains("onChange(of: suggestions)"),
            "observe the Equatable suggestions array directly"
        )
    }

    func test_suggestionPanel_iteratesIdentifiableRowsNotEnumeratedArray() throws {
        // WHY: `ForEach(Array(suggestions.enumerated()), id: \\.element.id)`
        // allocates a tuple array on every panel body. Identifiable rows
        // (or indices) keep identity without that extra Array.
        let chrome = try source("Sources/Surfaces/AgentComposerChrome.swift")
        XCTAssertFalse(
            chrome.contains("Array(suggestions.enumerated())"),
            "suggestion panel must not allocate enumerated identity per body"
        )
        XCTAssertTrue(
            chrome.contains("ForEach(suggestions)"),
            "ForEach the Identifiable suggestion rows"
        )
    }

    func test_unchangedSuggestionsAreEqual_soOnChangeIsANoOp() {
        // WHY: Equatable array comparison is the cheap onChange signal.
        // Identical rows must compare equal without mapping ids.
        let row = AgentComposerSuggestion(
            title: "/goal",
            subtitle: "Pass through",
            insertText: "/goal ",
            kind: .slashCommand
        )
        let previous = [row, row]
        let current = [row, row]
        XCTAssertEqual(previous, current)
        XCTAssertFalse(
            ComposerSuggestionObservation.shouldResetHighlight(from: previous, to: current)
        )

        let next = [
            AgentComposerSuggestion(
                title: "/clear",
                subtitle: "Clear",
                insertText: "/clear ",
                kind: .slashCommand
            )
        ]
        XCTAssertTrue(
            ComposerSuggestionObservation.shouldResetHighlight(from: previous, to: next)
        )
        XCTAssertEqual(
            ComposerSuggestionObservation.extraArrayAllocationsPerBody,
            0,
            "identity + ForEach must not allocate map/enumerated arrays per body"
        )
    }

    func test_highlightedSuggestionUsesIndexWithoutEnumeratedCopy() {
        let rows = [
            AgentComposerSuggestion(
                title: "/goal",
                subtitle: "Pass through",
                insertText: "/goal ",
                kind: .slashCommand
            ),
            AgentComposerSuggestion(
                title: "/clear",
                subtitle: "Clear",
                insertText: "/clear ",
                kind: .slashCommand
            )
        ]
        XCTAssertEqual(
            AgentComposerSuggestionPanel.highlightedSuggestionID(in: rows, index: 1),
            rows[1].id
        )
        XCTAssertNil(AgentComposerSuggestionPanel.highlightedSuggestionID(in: rows, index: nil))
        XCTAssertNil(AgentComposerSuggestionPanel.highlightedSuggestionID(in: rows, index: 9))
    }

    func test_plainTyping_skipsMentionableBotsProvider() throws {
        // WHY (F1): composerSuggestions used to call mentionableBotsProvider on
        // every body before suggestions() could short-circuit. Plain typing
        // must not touch the bots catalog.
        let (vm, rootURL) = try makeVM()
        defer {
            vm.dispose()
            try? FileManager.default.removeItem(at: rootURL)
        }
        var providerCalls = 0
        vm.mentionableBotsProvider = {
            providerCalls += 1
            return []
        }
        #if DEBUG
        let before = AgentAppViewModel.composerMentionableBotsProviderCallCountForTesting
        #endif
        vm.prompt = "hello world without mentions"
        vm.composerCursorOffset = vm.prompt.utf16.count
        for _ in 0..<50 {
            _ = vm.composerSuggestions
        }
        XCTAssertEqual(providerCalls, 0, "plain typing must not call mentionableBotsProvider")
        #if DEBUG
        XCTAssertEqual(
            AgentAppViewModel.composerMentionableBotsProviderCallCountForTesting,
            before,
            "DEBUG counter must stay flat for non-trigger tokens"
        )
        #endif
        XCTAssertTrue(vm.composerSuggestions.isEmpty)
    }

    func test_atToken_invokesMentionableBotsProviderOncePerRead() throws {
        // WHY (F1): @ mentions still need the bots catalog; the gate must not
        // drop that path.
        let (vm, rootURL) = try makeVM()
        defer {
            vm.dispose()
            try? FileManager.default.removeItem(at: rootURL)
        }
        var providerCalls = 0
        vm.mentionableBotsProvider = {
            providerCalls += 1
            return []
        }
        vm.prompt = "ask @ceo"
        vm.composerCursorOffset = vm.prompt.utf16.count
        _ = vm.composerSuggestions
        _ = vm.composerSuggestions
        XCTAssertEqual(providerCalls, 2, "@ token must still load mentionable bots")
    }

    // MARK: - Helpers

    private func simulateKeystrokeCursorCallbacks(on state: AgentComposerState, offset: Int) {
        state.cursorOffset = offset
        state.cursorOffset = offset
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func makeVM() throws -> (AgentAppViewModel, URL) {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-composer-hotspot-" + UUID().uuidString)
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
