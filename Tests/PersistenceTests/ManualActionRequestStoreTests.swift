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
}
