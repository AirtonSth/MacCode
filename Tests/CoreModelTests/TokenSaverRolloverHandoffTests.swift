import XCTest
@testable import CoreModel

final class TokenSaverRolloverHandoffTests: XCTestCase {
    func test_defaultOff() {
        XCTAssertFalse(TokenSaverRolloverHandoff.defaultEnabled)
        let rt = TokenSaverRolloverHandoffRuntime()
        XCTAssertNil(rt.fork(op: .init(parentHead: "h", kind: .manual), runAsUser: "u"))
        XCTAssertTrue(rt.parentAllowsNewTurns()) // fail-open when OFF
    }

    func test_twoManualForksDistinctAndReplay() {
        let rt = TokenSaverRolloverHandoffRuntime()
        rt.live = true
        let a = TokenSaverRolloverHandoffRuntime.ForkOperationID(parentHead: "head", kind: .manual)
        let b = TokenSaverRolloverHandoffRuntime.ForkOperationID(parentHead: "head", kind: .manual)
        let ba = rt.fork(op: a, runAsUser: "alice")!
        let bb = rt.fork(op: b, runAsUser: "alice")!
        XCTAssertNotEqual(ba.forkID.id, bb.forkID.id)
        XCTAssertNotEqual(ba.childHead, bb.childHead)
        let replay = rt.fork(op: a, runAsUser: "alice", replay: true)!
        XCTAssertEqual(replay.forkID.id, a.id)
        XCTAssertEqual(replay.childHead, ba.childHead)
        XCTAssertEqual(ba.runAsUser, "alice")
    }

    func test_rolloverFencesParent_manualDoesNot() {
        let rt = TokenSaverRolloverHandoffRuntime()
        rt.live = true
        _ = rt.fork(op: .init(parentHead: "h", kind: .manual), runAsUser: "u")
        XCTAssertTrue(rt.parentAllowsNewTurns())
        _ = rt.fork(op: .init(parentHead: "h", kind: .rollover), runAsUser: "u")
        XCTAssertFalse(rt.parentAllowsNewTurns())
        XCTAssertEqual(rt.parentStateValue(), .fenced)
    }

    func test_lossyHandoffVerbosityVisual() {
        let rt = TokenSaverRolloverHandoffRuntime()
        rt.live = true
        XCTAssertFalse(rt.admitLossy(corpusOK: true))
        rt.setLossyValidatorPresent(true)
        XCTAssertTrue(rt.admitLossy(corpusOK: true))
        XCTAssertFalse(rt.admitLossy(corpusOK: false))
        XCTAssertTrue(rt.rejectCriticalSuppression(bound: 10, candidate: 11))
        XCTAssertFalse(rt.admitHandoff())
        rt.setHandoff(consent: true, destinationBinding: "bind-b")
        XCTAssertTrue(rt.admitHandoff())
        XCTAssertEqual(rt.applyVerbosity(toGenerated: "done", level: "brief"), "done")
        XCTAssertTrue(rt.visualForcesOriginal(isOCR: true, isUI: false, isDebug: false))
    }
}
