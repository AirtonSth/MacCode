import XCTest
@testable import CoreModel

final class TokenSaverWaveDFamiliesTests: XCTestCase {
    func test_defaultOff() {
        XCTAssertFalse(TokenSaverWaveDFamilies.defaultEnabled)
        let rt = TokenSaverWaveDRuntime(boundUserID: "u", bindingDigest: "b")
        XCTAssertEqual(
            rt.admitCommand(.test, requestingUserID: "u", bindingDigest: "b"),
            .notLive
        )
        XCTAssertTrue(rt.taskDoneAllowed())
        XCTAssertFalse(TokenSaverWaveDRuntime.packageManagerAutoWrapEnabled)
    }

    func test_commandsUserBindingAndNoPackageWrap() {
        let rt = TokenSaverWaveDRuntime(boundUserID: "alice", bindingDigest: "bind-1")
        rt.live = true
        XCTAssertEqual(rt.admitCommand(.test, requestingUserID: "alice", bindingDigest: "bind-1"), .admitted)
        XCTAssertEqual(rt.admitCommand(.test, requestingUserID: "bob", bindingDigest: "bind-1"), .userMismatch)
        XCTAssertEqual(rt.admitCommand(.test, requestingUserID: "alice", bindingDigest: "other"), .bindingMismatch)
        XCTAssertEqual(rt.admitRawSubcommand("npm", requestingUserID: "alice", bindingDigest: "bind-1"), .packageManagerAutoWrapAbsent)
        XCTAssertEqual(rt.admitRawSubcommand("rm", requestingUserID: "alice", bindingDigest: "bind-1"), .unknownSubcommand)
        XCTAssertFalse(rt.mayBufferLiveTerminal())
    }

    func test_structureStoreBeforeLossAndGraphProvenance() {
        let rt = TokenSaverWaveDRuntime(boundUserID: "u", bindingDigest: "b")
        rt.live = true
        let original = Data("func f() {}".utf8)
        switch rt.codeStructureView(
            original: original,
            language: "swift",
            lineMapDigest: "map-abc",
            isLatestRead: false,
            isPatchTarget: false,
            requestingUserID: "u",
            bindingDigest: "b"
        ) {
        case .success(let view):
            XCTAssertEqual(view.marker, "[[rc:\(view.handle)]]")
            XCTAssertEqual(rt.retrieveStructureOriginal(handle: view.handle), original)
        case .failure(let admit):
            XCTFail("expected success, got \(admit)")
        }
        if case .failure(let a) = rt.codeStructureView(
            original: original, language: "swift", lineMapDigest: "m",
            isLatestRead: true, isPatchTarget: false,
            requestingUserID: "u", bindingDigest: "b"
        ) {
            XCTAssertEqual(a, .latestReadOrPatchForcesRaw)
        } else {
            XCTFail("expected latest read force raw")
        }

        XCTAssertEqual(
            rt.evidenceGraph(provenance: nil, lspStale: false, requestingUserID: "u", bindingDigest: "b"),
            .missingProvenance
        )
        let prov = TokenSaverWaveDRuntime.GraphProvenance(
            sourceDigest: "src", coverageDigest: "cov", lspGeneration: 1
        )
        XCTAssertEqual(
            rt.evidenceGraph(provenance: prov, lspStale: true, requestingUserID: "u", bindingDigest: "b"),
            .graphDegraded
        )
        XCTAssertEqual(
            rt.evidenceGraph(provenance: prov, lspStale: false, requestingUserID: "u", bindingDigest: "b"),
            .admitted
        )
        XCTAssertEqual(
            rt.validationRecipe(networked: true, mappingAmbiguous: false, requestingUserID: "u", bindingDigest: "b"),
            .networkedRecipe
        )
        XCTAssertFalse(rt.mlxMayInventShell())
        rt.recordValidationFailure()
        XCTAssertFalse(rt.taskDoneAllowed())
    }
}
