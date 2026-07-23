import XCTest
@testable import CoreModel

final class TokenSaverRolloverHandoffTests: XCTestCase {
    func test_defaultOff() {
        XCTAssertFalse(TokenSaverRolloverHandoff.defaultEnabled)
        let rt = TokenSaverRolloverHandoffRuntime(boundUserID: "u")
        XCTAssertNil(rt.fork(op: .init(parentHead: "h", kind: .manual), requestingUserID: "u"))
        XCTAssertTrue(rt.parentAllowsNewTurns()) // fail-open when OFF
    }

    func test_twoManualForksDistinctAndReplay() {
        let rt = TokenSaverRolloverHandoffRuntime(boundUserID: "alice")
        rt.live = true
        let a = TokenSaverRolloverHandoffRuntime.ForkOperationID(parentHead: "head", kind: .manual)
        let b = TokenSaverRolloverHandoffRuntime.ForkOperationID(parentHead: "head", kind: .manual)
        let ba = rt.fork(op: a, requestingUserID: "alice")!
        let bb = rt.fork(op: b, requestingUserID: "alice")!
        XCTAssertNotEqual(ba.forkID.id, bb.forkID.id)
        XCTAssertNotEqual(ba.childHead, bb.childHead)
        let replay = rt.fork(op: a, requestingUserID: "alice", replay: true)!
        XCTAssertEqual(replay.forkID.id, a.id)
        XCTAssertEqual(replay.childHead, ba.childHead)
        XCTAssertEqual(ba.runAsUser, "alice")
    }

    func test_sameUser_rejectsCrossUserForkAndHandoff() {
        let rt = TokenSaverRolloverHandoffRuntime(boundUserID: "alice")
        rt.live = true
        XCTAssertNil(rt.fork(op: .init(parentHead: "h", kind: .manual), requestingUserID: "bob"))
        rt.setHandoff(consent: true, destinationBinding: "bind")
        XCTAssertFalse(rt.admitHandoff(requestingUserID: "bob"))
        XCTAssertTrue(rt.admitHandoff(requestingUserID: "alice"))
    }

    func test_rolloverFencesParent_manualDoesNot() {
        let rt = TokenSaverRolloverHandoffRuntime(boundUserID: "u")
        rt.live = true
        _ = rt.fork(op: .init(parentHead: "h", kind: .manual), requestingUserID: "u")
        XCTAssertTrue(rt.parentAllowsNewTurns())
        _ = rt.fork(op: .init(parentHead: "h", kind: .rollover), requestingUserID: "u")
        XCTAssertFalse(rt.parentAllowsNewTurns())
        XCTAssertEqual(rt.parentStateValue(), .fenced)
    }

    func test_crashRelaunch_recoversFenceAndBranches() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ts-r19-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TokenSaverRolloverHandoffRuntime.FileDurabilityStore(directory: dir)
        let rt = TokenSaverRolloverHandoffRuntime(boundUserID: "u", store: store)
        rt.live = true
        let op = TokenSaverRolloverHandoffRuntime.ForkOperationID(parentHead: "h", kind: .rollover)
        let branch = rt.fork(op: op, requestingUserID: "u")!
        XCTAssertEqual(rt.parentStateValue(), .fenced)

        let store2 = try TokenSaverRolloverHandoffRuntime.FileDurabilityStore(directory: dir)
        let rt2 = TokenSaverRolloverHandoffRuntime(boundUserID: "u", store: store2)
        rt2.live = true
        XCTAssertEqual(rt2.parentStateValue(), TokenSaverRolloverHandoffRuntime.ParentState.fenced)
        XCTAssertFalse(rt2.parentAllowsNewTurns())
        XCTAssertEqual(rt2.branch(forkID: op.id)?.childHead, branch.childHead)
        // Wrong bound user cannot load another user's snapshot as own
        let store3 = try TokenSaverRolloverHandoffRuntime.FileDurabilityStore(directory: dir)
        let other = TokenSaverRolloverHandoffRuntime(boundUserID: "other", store: store3)
        XCTAssertEqual(other.parentStateValue(), TokenSaverRolloverHandoffRuntime.ParentState.parentActive)
        XCTAssertNil(other.branch(forkID: op.id))
    }

    func test_lossyRequiresStoreBeforeLoss() {
        let rt = TokenSaverRolloverHandoffRuntime(boundUserID: "u")
        rt.live = true
        rt.setLossyValidatorPresent(true)
        // Missing durable original / readback / handle → deny
        XCTAssertFalse(rt.admitLossy(corpusOK: true, originalStored: false, verifiedReadback: true, recoveryHandle: "h"))
        XCTAssertFalse(rt.admitLossy(corpusOK: true, originalStored: true, verifiedReadback: false, recoveryHandle: "h"))
        XCTAssertFalse(rt.admitLossy(corpusOK: true, originalStored: true, verifiedReadback: true, recoveryHandle: "  "))
        XCTAssertTrue(rt.admitLossy(corpusOK: true, originalStored: true, verifiedReadback: true, recoveryHandle: "h1"))
        XCTAssertFalse(rt.admitLossy(corpusOK: false, originalStored: true, verifiedReadback: true, recoveryHandle: "h1"))
        XCTAssertTrue(rt.rejectCriticalSuppression(bound: 10, candidate: 11))
        XCTAssertEqual(rt.applyVerbosity(toGenerated: "done", level: "brief"), "done")
        XCTAssertTrue(rt.visualForcesOriginal(isOCR: true, isUI: false, isDebug: false))
    }
}
