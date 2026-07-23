import XCTest
@testable import CoreModel

final class TokenSaverWaveDFamiliesTests: XCTestCase {
    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ts-wd-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_defaultOff() {
        XCTAssertFalse(TokenSaverWaveDFamilies.defaultEnabled)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rt = TokenSaverWaveDRuntime(boundUserID: "u", bindingDigest: "b", durableDirectory: dir)
        XCTAssertEqual(rt.admitCommand(.test, requestingUserID: "u", bindingDigest: "b"), .notLive)
        XCTAssertTrue(rt.taskDoneAllowed())
        XCTAssertFalse(TokenSaverWaveDRuntime.packageManagerAutoWrapEnabled)
    }

    func test_commandsUserBindingAndNoPackageWrap() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rt = TokenSaverWaveDRuntime(boundUserID: "alice", bindingDigest: "bind-1", durableDirectory: dir)
        rt.live = true
        XCTAssertEqual(rt.admitCommand(.test, requestingUserID: "alice", bindingDigest: "bind-1"), .admitted)
        XCTAssertEqual(rt.admitCommand(.test, requestingUserID: "bob", bindingDigest: "bind-1"), .userMismatch)
        XCTAssertEqual(rt.admitCommand(.test, requestingUserID: "alice", bindingDigest: "other"), .bindingMismatch)
        XCTAssertEqual(rt.admitRawSubcommand("npm", requestingUserID: "alice", bindingDigest: "bind-1"), .packageManagerAutoWrapAbsent)
        XCTAssertEqual(rt.admitRawSubcommand("rm", requestingUserID: "alice", bindingDigest: "bind-1"), .unknownSubcommand)
        XCTAssertFalse(rt.mayBufferLiveTerminal())
    }

    func test_structureDurableAuthAndGraphProvenance() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rt = TokenSaverWaveDRuntime(boundUserID: "u", bindingDigest: "b", durableDirectory: dir)
        rt.live = true
        // Memory-only (no durable dir) fails
        let mem = TokenSaverWaveDRuntime(boundUserID: "u", bindingDigest: "b")
        mem.live = true
        if case .failure(let a) = mem.codeStructureView(
            original: Data("x".utf8), language: "swift", lineMapDigest: "m",
            isLatestRead: false, isPatchTarget: false, requestingUserID: "u", bindingDigest: "b"
        ) {
            XCTAssertEqual(a, .durableRequired)
        } else { XCTFail("expected durableRequired") }

        let original = Data("func f() {}".utf8)
        guard case .success(let view) = rt.codeStructureView(
            original: original, language: "swift", lineMapDigest: "map-abc",
            isLatestRead: false, isPatchTarget: false, requestingUserID: "u", bindingDigest: "b"
        ) else {
            return XCTFail("structure store failed")
        }
        XCTAssertEqual(view.marker, "[[rc:\(view.handle)]]")
        XCTAssertEqual(rt.retrieveStructureOriginal(handle: view.handle, requestingUserID: "u", bindingDigest: "b"), original)
        XCTAssertNil(rt.retrieveStructureOriginal(handle: view.handle, requestingUserID: "other", bindingDigest: "b"))
        // Relaunch
        let rt2 = TokenSaverWaveDRuntime(boundUserID: "u", bindingDigest: "b", durableDirectory: dir)
        XCTAssertEqual(rt2.retrieveStructureOriginal(handle: view.handle, requestingUserID: "u", bindingDigest: "b"), original)
        // Cross-user same dir cannot read
        let other = TokenSaverWaveDRuntime(boundUserID: "other", bindingDigest: "b", durableDirectory: dir)
        XCTAssertNil(other.retrieveStructureOriginal(handle: view.handle, requestingUserID: "other", bindingDigest: "b"))

        if case .failure(let a) = rt.codeStructureView(
            original: original, language: "swift", lineMapDigest: "m",
            isLatestRead: true, isPatchTarget: false, requestingUserID: "u", bindingDigest: "b"
        ) {
            XCTAssertEqual(a, .latestReadOrPatchForcesRaw)
        } else { XCTFail("expected latest raw") }

        XCTAssertEqual(
            rt.evidenceGraph(provenance: nil, lspStale: false, requestingUserID: "u", bindingDigest: "b"),
            .missingProvenance
        )
        let bad = TokenSaverWaveDRuntime.GraphProvenance(
            sourceDigest: "s", coverageDigest: "c", path: "p.swift",
            startLine: 1, endLine: 2, lspGeneration: 0
        )
        XCTAssertEqual(
            rt.evidenceGraph(provenance: bad, lspStale: false, requestingUserID: "u", bindingDigest: "b"),
            .missingProvenance
        )
        let ok = TokenSaverWaveDRuntime.GraphProvenance(
            sourceDigest: "s", coverageDigest: "c", path: "p.swift",
            startLine: 1, endLine: 10, lspGeneration: 3
        )
        XCTAssertEqual(
            rt.evidenceGraph(provenance: ok, lspStale: false, requestingUserID: "u", bindingDigest: "b"),
            .admitted
        )
        XCTAssertFalse(rt.mlxMayInventShell())
        rt.recordValidationFailure()
        XCTAssertFalse(rt.taskDoneAllowed())
    }
}
