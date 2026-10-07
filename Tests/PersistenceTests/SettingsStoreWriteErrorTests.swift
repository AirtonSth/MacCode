import XCTest
@testable import Persistence
import CoreModel

// MARK: - Test double

/// Simulates a SettingsRepository whose set() always throws.
/// Pure value — no SQLiteDB, no MainActor, no I/O.
private final class FailingSettingsRepository: SettingsKeyValueRepository {
    enum Err: Error { case injected }

    private var store: [String: String] = [:]
    var shouldFail = false

    func get(_ key: String) throws -> String? { store[key] }

    func set(_ key: String, _ value: String) throws {
        if shouldFail { throw Err.injected }
        store[key] = value
    }

    func delete(key: String) throws {
        if shouldFail { throw Err.injected }
        store.removeValue(forKey: key)
    }
}

// MARK: - Tests

/// P2: user-initiated writes that fail must invoke onWriteError with the
/// thrown error; successful writes must NOT invoke it.
/// WHY: the previous try? swallow caused silent data loss — the user had
/// no signal that their preference change was not persisted.
final class SettingsStoreWriteErrorTests: XCTestCase {

    // MARK: failing write invokes funnel

    func test_failingWrite_invokesOnWriteError() {
        let repo = FailingSettingsRepository()
        let store = SettingsStore(repo: repo)

        var capturedError: Error?
        store.onWriteError = { capturedError = $0 }

        repo.shouldFail = true
        store.save(AppSettings())

        XCTAssertNotNil(capturedError,
            "a write failure must deliver the error to onWriteError so the app can surface it")
        XCTAssertTrue(capturedError is FailingSettingsRepository.Err,
            "the delivered error must be the one thrown by the repo, not a wrapper")
    }

    // MARK: successful write does NOT invoke funnel

    func test_successfulWrite_doesNotInvokeOnWriteError() {
        let repo = FailingSettingsRepository()
        let store = SettingsStore(repo: repo)

        var called = false
        store.onWriteError = { _ in called = true }

        repo.shouldFail = false
        store.save(AppSettings(diffWordWrap: true))

        XCTAssertFalse(called,
            "onWriteError must remain silent when the write succeeds")
    }

    // MARK: funnel is optional — nil handler must not crash

    func test_failingWrite_noHandler_doesNotCrash() {
        let repo = FailingSettingsRepository()
        let store = SettingsStore(repo: repo)
        // onWriteError left nil (default)

        repo.shouldFail = true
        // Must not crash; error is silently dropped only when no handler registered.
        store.save(AppSettings())
    }

    // MARK: update() paths through save() and also routes errors

    func test_updateFailingWrite_invokesOnWriteError() {
        let repo = FailingSettingsRepository()
        let store = SettingsStore(repo: repo)

        var capturedError: Error?
        store.onWriteError = { capturedError = $0 }

        repo.shouldFail = true
        store.update { $0.terminalFontSize = 14 }

        XCTAssertNotNil(capturedError,
            "update() internally calls save(); write failures must propagate to the funnel")
    }

    func test_promptHistoryFailingWrite_invokesOnWriteError() {
        let repo = FailingSettingsRepository()
        let store = PromptHistoryStore(repo: repo)
        var capturedError: Error?
        store.onWriteError = { capturedError = $0 }

        repo.shouldFail = true
        store.save(["build then test"], workspaceID: WorkspaceID())

        XCTAssertNotNil(capturedError,
            "PromptHistoryStore.save must route persistence failures to onWriteError so typed prompts are not lost silently")
        XCTAssertTrue(capturedError is FailingSettingsRepository.Err)
    }

    func test_customModelFailingWrite_invokesOnWriteError() {
        let repo = FailingSettingsRepository()
        let store = AgentCustomModelStore(repo: repo)
        var capturedError: Error?
        store.onWriteError = { capturedError = $0 }

        repo.shouldFail = true
        store.add("custom-model", provider: .claude)

        XCTAssertNotNil(capturedError,
            "AgentCustomModelStore must route write failures to onWriteError so Settings custom-model edits are not lost silently")
        XCTAssertTrue(capturedError is FailingSettingsRepository.Err)
    }
}
