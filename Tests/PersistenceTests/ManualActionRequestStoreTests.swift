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

    func test_roundTrip_returnsOpenRequestForThread() {
        let store = ManualActionRequestStore(appSupportDirectory: makeDir())
        let thread = AgentThreadID()
        let request = ManualActionRequest(botID: BotID(), threadID: thread, kind: .login, reason: "Entre na conta")
        store.upsert(request)
        XCTAssertEqual(store.open(threadID: thread), request)
        XCTAssertEqual(store.all(threadID: thread), [request])
        XCTAssertNil(store.open(threadID: AgentThreadID()))
    }

    func test_resolve_isIdempotent() {
        let store = ManualActionRequestStore(appSupportDirectory: makeDir())
        let thread = AgentThreadID()
        let request = ManualActionRequest(botID: BotID(), threadID: thread, kind: .captcha, reason: "x")
        store.upsert(request)
        let first = store.resolve(id: request.id, state: .continued, note: "ok")
        XCTAssertEqual(first?.state, .continued)
        XCTAssertEqual(first?.note, "ok")
        XCTAssertNil(store.resolve(id: request.id, state: .declined))
        XCTAssertNil(store.open(threadID: thread))
        XCTAssertEqual(store.all(threadID: thread).first?.state, .continued)
    }

    func test_expireStaleID_leavesNewerRequestOpen() {
        let store = ManualActionRequestStore(appSupportDirectory: makeDir())
        let bot = BotID()
        let thread = AgentThreadID()
        let old = ManualActionRequest(botID: bot, threadID: thread, kind: .login, reason: "old")
        store.upsert(old)
        store.resolve(id: old.id, state: .continued)
        let newer = ManualActionRequest(botID: bot, threadID: thread, kind: .login, reason: "new")
        store.upsert(newer)
        XCTAssertNil(store.expire(id: old.id))
        XCTAssertEqual(store.open(threadID: thread)?.id, newer.id)
        XCTAssertEqual(store.expire(id: newer.id)?.state, .expired)
    }

    func test_newStoreInstanceOverSameDirectory_stillReturnsOpenRequest() {
        let dir = makeDir()
        let thread = AgentThreadID()
        let request = ManualActionRequest(botID: BotID(), threadID: thread, kind: .twoFactor, reason: "codigo")
        ManualActionRequestStore(appSupportDirectory: dir).upsert(request)
        XCTAssertEqual(ManualActionRequestStore(appSupportDirectory: dir).open(threadID: thread)?.id, request.id)
    }

    func test_closeAll_expiresOnlyThatBot() {
        let store = ManualActionRequestStore(appSupportDirectory: makeDir())
        let botA = BotID()
        let botB = BotID()
        let threadA = AgentThreadID()
        let threadB = AgentThreadID()
        store.upsert(ManualActionRequest(botID: botA, threadID: threadA, kind: .other, reason: "a"))
        store.upsert(ManualActionRequest(botID: botB, threadID: threadB, kind: .other, reason: "b"))
        store.closeAll(botID: botA)
        XCTAssertNil(store.open(threadID: threadA))
        XCTAssertEqual(store.all(threadID: threadA).first?.state, .expired)
        XCTAssertNotNil(store.open(threadID: threadB))
    }
}
