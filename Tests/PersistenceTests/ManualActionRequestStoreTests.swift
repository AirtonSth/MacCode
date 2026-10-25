import XCTest
import CoreModel
@testable import Persistence

/// WHY: a manual-action card must survive app restart and a late timer or double tap must
/// never close a newer request or resolve one twice.
final class ManualActionRequestStoreTests: XCTestCase {
    private func makeDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualActionStore-\(UUID().uuidString)", isDirectory: true)
    }

    func test_roundTrip_returnsOpenRequestForThread() throws {
        let store = ManualActionRequestStore(appSupportDirectory: makeDir())
        let thread = AgentThreadID()
        let request = ManualActionRequest(botID: BotID(), threadID: thread, kind: .login, reason: "Entre na conta")
        try store.upsert(request)
        XCTAssertEqual(store.open(threadID: thread), request)
        XCTAssertEqual(store.all(threadID: thread), [request])
        XCTAssertNil(store.open(threadID: AgentThreadID()))
    }

    func test_resolve_isIdempotent() throws {
        let store = ManualActionRequestStore(appSupportDirectory: makeDir())
        let thread = AgentThreadID()
        let request = ManualActionRequest(botID: BotID(), threadID: thread, kind: .captcha, reason: "x")
        try store.upsert(request)
        let first = try store.resolve(id: request.id, state: .continued, note: "ok")
        XCTAssertEqual(first?.state, .continued)
        XCTAssertEqual(first?.note, "ok")
        XCTAssertNil(try store.resolve(id: request.id, state: .declined))
        XCTAssertNil(store.open(threadID: thread))
        XCTAssertEqual(store.all(threadID: thread).first?.state, .continued)
    }

    func test_expireStaleID_leavesNewerRequestOpen() throws {
        let store = ManualActionRequestStore(appSupportDirectory: makeDir())
        let bot = BotID()
        let thread = AgentThreadID()
        let old = ManualActionRequest(botID: bot, threadID: thread, kind: .login, reason: "old")
        try store.upsert(old)
        try store.resolve(id: old.id, state: .continued)
        let newer = ManualActionRequest(botID: bot, threadID: thread, kind: .login, reason: "new")
        try store.upsert(newer)
        XCTAssertNil(try store.expire(id: old.id))
        XCTAssertEqual(store.open(threadID: thread)?.id, newer.id)
        XCTAssertEqual(try store.expire(id: newer.id)?.state, .expired)
    }

    func test_newStoreInstanceOverSameDirectory_stillReturnsOpenRequest() throws {
        let dir = makeDir()
        let thread = AgentThreadID()
        let request = ManualActionRequest(botID: BotID(), threadID: thread, kind: .twoFactor, reason: "codigo")
        try ManualActionRequestStore(appSupportDirectory: dir).upsert(request)
        XCTAssertEqual(ManualActionRequestStore(appSupportDirectory: dir).open(threadID: thread)?.id, request.id)
    }

    func test_closeAll_expiresOnlyThatBot() throws {
        let store = ManualActionRequestStore(appSupportDirectory: makeDir())
        let botA = BotID()
        let botB = BotID()
        let threadA = AgentThreadID()
        let threadB = AgentThreadID()
        try store.upsert(ManualActionRequest(botID: botA, threadID: threadA, kind: .other, reason: "a"))
        try store.upsert(ManualActionRequest(botID: botB, threadID: threadB, kind: .other, reason: "b"))
        try store.closeAll(botID: botA)
        XCTAssertNil(store.open(threadID: threadA))
        XCTAssertEqual(store.all(threadID: threadA).first?.state, .expired)
        XCTAssertNotNil(store.open(threadID: threadB))
    }

    /// WHY: thread payloads read the store on MainActor, so it keeps the decoded
    /// file in memory; a bot deleted from a paired device closes its requests
    /// through another store instance, and the cached reader must see that at
    /// once instead of showing a card nobody can answer.
    func test_cachedReaderSeesAnotherInstancesCloseAllAndCloseAllReturnsWhatItClosed() throws {
        let dir = makeDir()
        let reader = ManualActionRequestStore(appSupportDirectory: dir)
        let bot = BotID()
        let thread = AgentThreadID()
        let request = ManualActionRequest(botID: bot, threadID: thread, kind: .login, reason: "x")
        try reader.upsert(request)
        XCTAssertEqual(reader.openByThread()[thread]?.id, request.id, "warm the reader's cache")

        let closed = try ManualActionRequestStore(appSupportDirectory: dir).closeAll(botID: bot)

        XCTAssertEqual(closed.map(\.id), [request.id])
        XCTAssertEqual(closed.first?.state, .expired, "callers announce the closed state")
        XCTAssertNil(reader.open(threadID: thread))
        XCTAssertTrue(reader.openByThread().isEmpty)
        XCTAssertEqual(reader.all(threadID: thread).first?.state, .expired)
        XCTAssertTrue(try reader.closeAll(botID: bot).isEmpty, "nothing left to close or announce")
    }

    private func unwritableStore() throws -> (ManualActionRequestStore, URL) {
        // A regular file where the ManualActions directory must be makes every write fail.
        let dir = makeDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("ManualActions"))
        return (ManualActionRequestStore(appSupportDirectory: dir), dir)
    }

    func test_writeFailuresThrowInsteadOfBeingSwallowed() throws {
        // WHY: a swallowed write error made the UI think a request was resolved while disk still held it open.
        let (store, _) = try unwritableStore()
        let request = ManualActionRequest(botID: BotID(), threadID: AgentThreadID(), kind: .login, reason: "x")
        XCTAssertThrowsError(try store.upsert(request))
    }

    func test_resolveReturnsNilOnlyAfterSuccessfulWriteAndThrowsOtherwise() throws {
        let dir = makeDir()
        let store = ManualActionRequestStore(appSupportDirectory: dir)
        let request = ManualActionRequest(botID: BotID(), threadID: AgentThreadID(), kind: .login, reason: "x")
        try store.upsert(request)
        let actions = dir.appendingPathComponent("ManualActions")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: actions.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: actions.path) }
        XCTAssertThrowsError(try store.resolve(id: request.id, state: .continued))
        XCTAssertEqual(store.open(threadID: request.threadID!)?.state, .open)
    }

    func test_takeOnlyMovesOpenToTaken() throws {
        // WHY: a stale card must never revive a continued or declined request.
        let store = ManualActionRequestStore(appSupportDirectory: makeDir())
        let thread = AgentThreadID()
        let request = ManualActionRequest(botID: BotID(), threadID: thread, kind: .login, reason: "x")
        try store.upsert(request)
        XCTAssertEqual(try store.take(id: request.id)?.state, .taken)
        XCTAssertNil(try store.take(id: request.id), "already taken")
        XCTAssertEqual(try store.resolve(id: request.id, state: .continued)?.state, .continued)
        XCTAssertNil(try store.take(id: request.id), "terminal state is final")
        XCTAssertEqual(store.all(threadID: thread).first?.state, .continued)
        XCTAssertNil(try store.take(id: UUID()))
    }

    func test_maintenanceDenialRestoresOpenRequestAndAllowsLaterTake() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManualActionRequestStore(appSupportDirectory: dir)
        let bot = BotID(), resource = BotID(), thread = AgentThreadID()
        let request = ManualActionRequest(botID: bot, threadID: thread, kind: .login, reason: "Sign in")
        try store.upsert(request)
        let control = BotComputerControl()
        control.configureResourceLookup { _, _ in resource }
        try control.withWorkspaceMaintenance(resourceIDs: [resource], botIDs: [bot]) {
            XCTAssertThrowsError(try store.take(id: request.id, control: control))
            XCTAssertEqual(store.open(threadID: thread)?.state, .open)
            XCTAssertFalse(control.isControlledByUser(bot, resourceID: resource))
        }
        XCTAssertEqual(try store.take(id: request.id, control: control)?.state, .taken)
        XCTAssertTrue(control.isControlledByUser(bot, resourceID: resource))
    }

    func test_deniedTakeDoesNotReopenRequestResolvedBeforeControlAcquisition() throws {
        for terminal in [ManualActionState.continued, .declined, .expired] {
            let dir = makeDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = ManualActionRequestStore(appSupportDirectory: dir)
            let bot = BotID(), resource = BotID(), thread = AgentThreadID()
            let request = ManualActionRequest(botID: bot, threadID: thread, kind: .login, reason: "Sign in")
            try store.upsert(request)
            let control = BotComputerControl()
            // Resource resolution occurs between the durable take and in-memory
            // control acquisition, reproducing a terminal arriving in that gap.
            control.configureResourceLookup { _, _ in
                _ = try? store.resolve(id: request.id, state: terminal, note: "Already answered")
                return resource
            }
            try control.withWorkspaceMaintenance(resourceIDs: [resource], botIDs: [bot]) {
                XCTAssertThrowsError(try store.take(id: request.id, control: control))
            }
            XCTAssertEqual(store.all(threadID: thread).first?.state, terminal)
            XCTAssertEqual(store.all(threadID: thread).first?.note, "Already answered")
        }
    }

    func test_deniedTakeDoesNotRewriteReplacedRequestGeneration() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManualActionRequestStore(appSupportDirectory: dir)
        let bot = BotID(), resource = BotID(), thread = AgentThreadID()
        let request = ManualActionRequest(botID: bot, threadID: thread, kind: .login, reason: "Original")
        try store.upsert(request)
        var replacement = request
        replacement.createdAt = request.createdAt.addingTimeInterval(1)
        replacement.reason = "Replacement"
        replacement.state = .taken
        let replaced = replacement
        let control = BotComputerControl()
        control.configureResourceLookup { _, _ in
            try? store.upsert(replaced)
            return resource
        }
        try control.withWorkspaceMaintenance(resourceIDs: [resource], botIDs: [bot]) {
            XCTAssertThrowsError(try store.take(id: request.id, control: control))
        }
        XCTAssertEqual(store.all(threadID: thread).first, replaced)
    }
}
