import XCTest
@testable import DistillCore

final class ReadLifecycleMaskerTests: XCTestCase {
    func test_masksOlderReadWhenNewerReadCoversSamePathHashAndRange() {
        let old = observation(id: "old", range: 10...20, turn: 1, handle: "oldhandle")
        let newer = observation(id: "new", range: 1...40, turn: 5, handle: "newhandle")

        let results = ReadLifecycleMasker.maskSupersededReads([old, newer], keepLastTurns: 2, enabled: true)
        let oldResult = results[0]

        XCTAssertTrue(oldResult.masked)
        XCTAssertTrue(oldResult.output.contains("stale read masked"))
        XCTAssertTrue(oldResult.output.contains("Sources/App.swift:10-20"))
        XCTAssertTrue(oldResult.output.contains("rc_retrieve(oldhandle)"))
        XCTAssertTrue(oldResult.output.contains("first: first line"))
        XCTAssertTrue(oldResult.output.contains("last: last line"))
    }

    func test_doesNotMaskPartialNonOverlappingOrChangedContentReads() {
        let old = observation(id: "old", range: 10...20, turn: 1, hash: "h1", handle: "oldhandle")
        let partial = observation(id: "partial", range: 15...30, turn: 5, hash: "h1", handle: "partialhandle")
        let changed = observation(id: "changed", range: 1...40, turn: 6, hash: "h2", handle: "changedhandle")

        let results = ReadLifecycleMasker.maskSupersededReads([old, partial, changed], keepLastTurns: 2, enabled: true)

        XCTAssertFalse(results[0].masked)
        XCTAssertEqual(results[0].reason, "not_superseded")
    }

    func test_doesNotMaskErrorsRecentTurnsOrMissingHandles() {
        let oldMissingHandle = observation(id: "missing", range: 1...20, turn: 1, handle: nil)
        let oldError = observation(id: "error", range: 1...20, turn: 1, handle: "err", hasError: true)
        let recent = observation(id: "recent", range: 1...20, turn: 4, handle: "recent")
        let newer = observation(id: "new", range: 1...20, turn: 5, handle: "new")

        let results = ReadLifecycleMasker.maskSupersededReads([oldMissingHandle, oldError, recent, newer], keepLastTurns: 2, enabled: true)

        XCTAssertEqual(results[0].reason, "missing_handle")
        XCTAssertEqual(results[1].reason, "error_output")
        XCTAssertEqual(results[2].reason, "recent_turn")
    }

    // I5.1: default OFF — masks nothing unless explicitly enabled (byte-stable off state).
    func test_maskingDefaultOffMasksNothing() {
        let old = observation(id: "old", range: 10...20, turn: 1, handle: "oldhandle")
        let newer = observation(id: "new", range: 1...40, turn: 5, handle: "newhandle")
        let results = ReadLifecycleMasker.maskSupersededReads([old, newer], keepLastTurns: 2)
        XCTAssertFalse(results.contains { $0.masked })
        XCTAssertEqual(results[0].reason, "masking_disabled")
        XCTAssertEqual(results[0].output, old.text, "off state is byte-identical to the original")
    }

    // I5.9/K8: no live MCP rc_retrieve → mask nothing (can't recover masked content).
    func test_masksNothingWhenMcpRetrieveUnavailable() {
        let old = observation(id: "old", range: 10...20, turn: 1, handle: "oldhandle")
        let newer = observation(id: "new", range: 1...40, turn: 5, handle: "newhandle")
        let results = ReadLifecycleMasker.maskSupersededReads([old, newer], keepLastTurns: 2, enabled: true, mcpRetrieveAvailable: false)
        XCTAssertFalse(results.contains { $0.masked })
        XCTAssertEqual(results[0].reason, "mcp_retrieve_unavailable")
    }

    // I5.6: masked handles are reported for pinning (ref_count>0, exempt from prune).
    func test_pinnedHandlesReturnsMaskedObservationHandles() {
        let old = observation(id: "old", range: 10...20, turn: 1, handle: "oldhandle")
        let newer = observation(id: "new", range: 1...40, turn: 5, handle: "newhandle")
        let results = ReadLifecycleMasker.maskSupersededReads([old, newer], keepLastTurns: 2, enabled: true)
        XCTAssertEqual(ReadLifecycleMasker.pinnedHandles(of: results), ["oldhandle"])
    }

    // I5.7: --resume parity — masking is a pure function of the observations.
    func test_resumeParityMaskingIsDeterministic() {
        let obs = [
            observation(id: "old", range: 10...20, turn: 1, handle: "oldhandle"),
            observation(id: "new", range: 1...40, turn: 5, handle: "newhandle"),
        ]
        let a = ReadLifecycleMasker.maskSupersededReads(obs, keepLastTurns: 2, enabled: true)
        let b = ReadLifecycleMasker.maskSupersededReads(obs, keepLastTurns: 2, enabled: true)
        XCTAssertEqual(a, b, "masked state must be byte-identical across a resume")
    }

    private func observation(
        id: String,
        range: ClosedRange<Int>,
        turn: Int,
        path: String = "Sources/App.swift",
        hash: String = "abc123",
        handle: String?,
        hasError: Bool = false
    ) -> ReadLifecycleObservation {
        ReadLifecycleObservation(
            id: id,
            realpath: path,
            startLine: range.lowerBound,
            endLine: range.upperBound,
            contentHash: hash,
            byteCount: 128,
            text: "first line\nmiddle\nlast line",
            retrieveHandle: handle,
            turnIndex: turn,
            hasError: hasError
        )
    }
}
