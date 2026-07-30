import XCTest
@testable import SocketServer
import CoreModel

/// Pure unit tests for the plan-notes v1 byte-page projection and compact
/// update event.
///
/// WHY: multi-MiB notes on a weak cellular link must page under a fixed raw
/// ceiling without corrupting UTF-8 reassembly, without silently mixing
/// revisions mid-pagination, and without letting the final JSON-RPC frame
/// exceed the 512 KiB host budget even when the text is JSON-escape-heavy.
/// Persistence remains full; only the wire projection is bounded.
final class PlanNotesProjectionV1Tests: XCTestCase {

    // MARK: Legacy opt-in

    /// WHY: old clients omit protocol_version and must keep receiving the
    /// full-string get shape — max_bytes alone must not change the contract.
    func testParseCaps_absentProtocolVersionIsLegacy() throws {
        let caps = try PlanNotesProjectionV1.parseCaps([
            "max_bytes": .number(1024),
            "offset_bytes": .number(0),
        ])
        XCTAssertNil(caps)
    }

    /// WHY: a v1 client must never be silently served the unbounded legacy
    /// payload when it asked for paging.
    func testParseCaps_rejectsUnknownOrInvalidVersion() {
        let invalid: [[String: JSONValue]] = [
            ["protocol_version": .number(2), "offset_bytes": .number(0), "max_bytes": .number(1024)],
            ["protocol_version": .number(0), "offset_bytes": .number(0), "max_bytes": .number(1024)],
            ["protocol_version": .number(1.5), "offset_bytes": .number(0), "max_bytes": .number(1024)],
            ["protocol_version": .string("1"), "offset_bytes": .number(0), "max_bytes": .number(1024)],
            ["protocol_version": .bool(true)],
        ]
        for params in invalid {
            XCTAssertThrowsError(try PlanNotesProjectionV1.parseCaps(params)) { error in
                XCTAssertEqual((error as? JSONRPCError)?.code, -32602, "\(params)")
            }
        }
    }

    /// WHY: fractional / non-finite / negative cursors and limits would either
    /// trap Int conversion or produce dishonest pages.
    func testParseCaps_rejectsNonIntegralCursorAndLimits() {
        let invalid: [[String: JSONValue]] = [
            ["protocol_version": .number(1), "offset_bytes": .number(-1), "max_bytes": .number(64)],
            ["protocol_version": .number(1), "offset_bytes": .number(1.5), "max_bytes": .number(64)],
            ["protocol_version": .number(1), "offset_bytes": .number(0), "max_bytes": .number(0)],
            ["protocol_version": .number(1), "offset_bytes": .number(0), "max_bytes": .number(-4)],
            ["protocol_version": .number(1), "offset_bytes": .number(0), "max_bytes": .number(1.25)],
            ["protocol_version": .number(1), "offset_bytes": .number(0),
             "max_bytes": .number(Double(PlanNotesProjectionV1.maxBytesCeiling + 1))],
            ["protocol_version": .number(1), "offset_bytes": .number(.nan), "max_bytes": .number(64)],
            ["protocol_version": .number(1), "offset_bytes": .number(.infinity), "max_bytes": .number(64)],
            ["protocol_version": .number(1), "offset_bytes": .number(0), "max_bytes": .number(.nan)],
            ["protocol_version": .number(1), "content_digest": .string("not-a-digest")],
            ["protocol_version": .number(1), "content_digest": .string(String(repeating: "g", count: 64))],
        ]
        for params in invalid {
            XCTAssertThrowsError(try PlanNotesProjectionV1.parseCaps(params)) { error in
                XCTAssertEqual((error as? JSONRPCError)?.code, -32602, "\(params)")
            }
        }
    }

    func testParseCaps_acceptsValidV1WithDefaults() throws {
        let caps = try XCTUnwrap(try PlanNotesProjectionV1.parseCaps([
            "protocol_version": .number(1),
        ]))
        XCTAssertEqual(caps.offsetBytes, 0)
        XCTAssertEqual(caps.maxBytes, PlanNotesProjectionV1.maxBytesCeiling)
        XCTAssertNil(caps.expectedContentDigest)
    }

    // MARK: Save v1 digest CAS

    /// WHY: old clients omit protocol_version and must keep the full-body
    /// `expected_notes` CAS path — a bare digest key must not opt them in.
    func testParseSaveCaps_absentProtocolVersionIsLegacy() throws {
        let caps = try PlanNotesProjectionV1.parseSaveCaps([
            "expected_content_digest": .string(String(repeating: "a", count: 64)),
            "expected_notes": .string("prior body"),
        ])
        XCTAssertNil(caps)
    }

    /// WHY: a v1 client that still ships the full prior body would double
    /// bytes on 3G; reject dual-body so modern clients cannot pay both.
    func testParseSaveCaps_rejectsExpectedNotesOnV1Path() {
        let digest = PlanNotesProjectionV1.contentDigest(of: "old")
        let invalid: [[String: JSONValue]] = [
            [
                "protocol_version": .number(1),
                "expected_content_digest": .string(digest),
                "expected_notes": .string("old"),
            ],
            [
                "protocol_version": .number(1),
                "expected_content_digest": .string(digest),
                "expected_notes": .null,
            ],
            [
                "protocol_version": .number(1),
                "expected_content_digest": .string(digest),
                "expected_notes": .string(""),
            ],
        ]
        for params in invalid {
            XCTAssertThrowsError(try PlanNotesProjectionV1.parseSaveCaps(params)) { error in
                XCTAssertEqual((error as? JSONRPCError)?.code, -32602, "\(params)")
            }
        }
    }

    /// WHY: present-but-invalid v1 must fail closed (no silent legacy CAS).
    func testParseSaveCaps_rejectsUnknownOrMalformedV1() {
        let validDigest = PlanNotesProjectionV1.contentDigest(of: "x")
        let invalid: [[String: JSONValue]] = [
            ["protocol_version": .number(2), "expected_content_digest": .string(validDigest)],
            ["protocol_version": .number(0), "expected_content_digest": .string(validDigest)],
            ["protocol_version": .number(1.5), "expected_content_digest": .string(validDigest)],
            ["protocol_version": .string("1"), "expected_content_digest": .string(validDigest)],
            ["protocol_version": .number(.nan)],
            ["protocol_version": .number(.infinity)],
            ["protocol_version": .bool(true)],
            ["protocol_version": .number(1)], // missing digest
            ["protocol_version": .number(1), "expected_content_digest": .string("not-a-digest")],
            ["protocol_version": .number(1), "expected_content_digest": .string(String(repeating: "g", count: 64))],
            ["protocol_version": .number(1), "expected_content_digest": .string(String(repeating: "A", count: 64))],
            ["protocol_version": .number(1), "expected_content_digest": .number(1)],
            ["protocol_version": .number(1), "expected_content_digest": .null],
        ]
        for params in invalid {
            XCTAssertThrowsError(try PlanNotesProjectionV1.parseSaveCaps(params)) { error in
                XCTAssertEqual((error as? JSONRPCError)?.code, -32602, "\(params)")
            }
        }
    }

    func testParseSaveCaps_acceptsValidDigest() throws {
        let digest = PlanNotesProjectionV1.contentDigest(of: "prior notes")
        let caps = try XCTUnwrap(try PlanNotesProjectionV1.parseSaveCaps([
            "protocol_version": .number(1),
            "expected_content_digest": .string(digest),
        ]))
        XCTAssertEqual(caps.expectedContentDigest, digest)
    }

    /// WHY: success metadata must stay compact (no notes body) and identity
    /// revision with the new content digest so clients can CAS the next save.
    func testSaveResult_isCompactAndMatchesNewDigest() {
        let notes = String(repeating: "new-notes-", count: 10_000)
        let result = PlanNotesProjectionV1.saveResult(notes: notes)
        guard case .object(let body) = result else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(body["ok"], .bool(true))
        XCTAssertNil(body["notes"], "save result must not re-emit the notes body")
        XCTAssertNil(body["expected_notes"])
        let digest = PlanNotesProjectionV1.contentDigest(of: notes)
        XCTAssertEqual(body["content_digest"]?.stringValue, digest)
        XCTAssertEqual(body["revision"]?.stringValue, digest)
        XCTAssertEqual(body["total_bytes"], .number(Double(notes.utf8.count)))
    }

    /// WHY: mismatch must surface current revision so the client rehydrates
    /// instead of blindly overwriting a concurrent edit.
    func testSaveDigestMismatchError_carriesCurrentRevision() {
        let current = "server-wins"
        let expected = PlanNotesProjectionV1.contentDigest(of: "stale-client")
        let error = PlanNotesProjectionV1.saveDigestMismatchError(
            currentNotes: current,
            expectedDigest: expected
        )
        XCTAssertEqual(error.code, -32009)
        XCTAssertEqual(error.message, "Plan notes changed on another device.")
        let data = error.data?.objectValue
        let currentDigest = PlanNotesProjectionV1.contentDigest(of: current)
        XCTAssertEqual(data?["content_digest"]?.stringValue, currentDigest)
        XCTAssertEqual(data?["revision"]?.stringValue, currentDigest)
        XCTAssertEqual(data?["expected_content_digest"]?.stringValue, expected)
        XCTAssertNil(data?["notes"], "error payload must not ship the full current body")
    }

    // MARK: UTF-8 reassembly

    /// WHY: multibyte scalars must never be split, or reassembly yields
    /// replacement characters / invalid UTF-8 on the client.
    func testPage_neverSplitsMultiByteScalarAndReassemblesExactly() throws {
        // Each snowman is 3 UTF-8 bytes. Budget 4 would naively split the second.
        let notes = "☃☃☃" // 9 bytes
        let first = try PlanNotesProjectionV1.page(
            notes: notes,
            caps: .init(offsetBytes: 0, maxBytes: 4, expectedContentDigest: nil)
        )
        XCTAssertEqual(first.notes, "☃")
        XCTAssertEqual(first.returnedBytes, 3)
        XCTAssertTrue(first.hasMore)
        XCTAssertTrue(first.truncated)
        XCTAssertEqual(first.nextOffsetBytes, 3)

        let second = try PlanNotesProjectionV1.page(
            notes: notes,
            caps: .init(
                offsetBytes: first.nextOffsetBytes,
                maxBytes: 4,
                expectedContentDigest: first.contentDigest
            )
        )
        XCTAssertEqual(second.notes, "☃")
        XCTAssertEqual(second.nextOffsetBytes, 6)

        let third = try PlanNotesProjectionV1.page(
            notes: notes,
            caps: .init(
                offsetBytes: second.nextOffsetBytes,
                maxBytes: 4,
                expectedContentDigest: first.contentDigest
            )
        )
        XCTAssertEqual(third.notes, "☃")
        XCTAssertFalse(third.hasMore)
        XCTAssertEqual(first.notes + second.notes + third.notes, notes)
        XCTAssertEqual(
            first.notes.utf8.count + second.notes.utf8.count + third.notes.utf8.count,
            notes.utf8.count
        )
    }

    /// WHY: a client that fabricates an offset mid-scalar must fail closed
    /// rather than receive a corrupt continuation.
    func testPage_rejectsOffsetInsideUTF8Scalar() {
        let notes = "a☃b" // bytes: 61 E2 98 83 62
        XCTAssertThrowsError(
            try PlanNotesProjectionV1.page(
                notes: notes,
                caps: .init(offsetBytes: 2, maxBytes: 8, expectedContentDigest: nil)
            )
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32602)
        }
    }

    /// WHY: multi-MiB notes must reassemble byte-identical across pages under
    /// the fixed 64 KiB ceiling — the entire point of the v1 projection.
    func testPage_multiMiBNotesReassembleExactlyUnderCeiling() throws {
        // Mix ASCII + multibyte so any boundary bug shows up.
        let unit = "plan-notes-v1-✅-"
        let targetBytes = 2 * 1024 * 1024 + 123
        var notes = ""
        notes.reserveCapacity(targetBytes)
        while notes.utf8.count < targetBytes {
            notes += unit
        }
        // Trim to exact target on a UTF-8 boundary.
        let data = Data(notes.utf8)
        let trimEnd = PlanNotesProjectionV1.utf8Prefix(
            String(data: data, encoding: .utf8) ?? notes,
            maxBytes: targetBytes
        )
        notes = trimEnd
        XCTAssertGreaterThan(notes.utf8.count, 2 * 1024 * 1024)

        var offset = 0
        var assembled = ""
        var pages = 0
        let digest = PlanNotesProjectionV1.contentDigest(of: notes)
        while true {
            let page = try PlanNotesProjectionV1.page(
                notes: notes,
                caps: .init(
                    offsetBytes: offset,
                    maxBytes: PlanNotesProjectionV1.maxBytesCeiling,
                    expectedContentDigest: pages == 0 ? nil : digest
                )
            )
            XCTAssertEqual(page.contentDigest, digest)
            XCTAssertEqual(page.revision, digest)
            XCTAssertLessThanOrEqual(page.returnedBytes, PlanNotesProjectionV1.maxBytesCeiling + 3,
                                     "UTF-8 progress may overshoot max_bytes by at most 3")
            XCTAssertLessThanOrEqual(page.notes.utf8.count, PlanNotesProjectionV1.maxBytesCeiling + 3)
            let encoded = try PlanNotesProjectionV1.encodedJSONRPCResponseBytes(
                id: .number(pages + 1),
                page: page
            )
            XCTAssertLessThan(
                encoded,
                PlanNotesProjectionV1.maxEncodedResponseBytes,
                "page \(pages) encoded \(encoded) bytes — weak-link budget is 512 KiB"
            )
            assembled += page.notes
            pages += 1
            if !page.hasMore {
                XCTAssertEqual(page.nextOffsetBytes, page.totalBytes)
                break
            }
            offset = page.nextOffsetBytes
            XCTAssertLessThan(pages, 1000, "pagination must terminate")
        }
        XCTAssertEqual(assembled, notes, "paged reassembly must be byte-identical to authoritative notes")
        XCTAssertEqual(Data(assembled.utf8), Data(notes.utf8))
        XCTAssertGreaterThan(pages, 1, "2 MiB must need more than one 64 KiB page")
    }

    /// WHY: JSON-escape-heavy text inflates the wire frame far beyond raw
    /// UTF-8; the 64 KiB raw ceiling must still keep the final RPC under 512 KiB.
    func testPage_escapeHeavyChunkEncodedResponseStaysUnder512KiB() throws {
        // Each unit forces multiple escapes: quote, backslash, control chars.
        let unit = "\\\"\n\t\u{0001}\u{0007}"
        var notes = ""
        while notes.utf8.count < PlanNotesProjectionV1.maxBytesCeiling * 2 {
            notes += unit
        }
        let page = try PlanNotesProjectionV1.page(
            notes: notes,
            caps: .init(
                offsetBytes: 0,
                maxBytes: PlanNotesProjectionV1.maxBytesCeiling,
                expectedContentDigest: nil
            )
        )
        XCTAssertTrue(page.hasMore)
        XCTAssertLessThanOrEqual(page.returnedBytes, PlanNotesProjectionV1.maxBytesCeiling + 3)
        let encoded = try PlanNotesProjectionV1.encodedJSONRPCResponseBytes(id: .number(1), page: page)
        XCTAssertLessThan(
            encoded,
            PlanNotesProjectionV1.maxEncodedResponseBytes,
            "escape-heavy page encoded \(encoded) bytes"
        )
        // Sanity: escaping did inflate beyond raw returned_bytes.
        XCTAssertGreaterThan(encoded, page.returnedBytes)
    }

    // MARK: Mid-pagination mutation

    /// WHY: assembling page 0 of revision A with page 1 of revision B would
    /// corrupt the client's notes with a franken-document that was never saved.
    func testPage_midPaginationMutationFailsHonestly() throws {
        let original = String(repeating: "A", count: 200)
        let first = try PlanNotesProjectionV1.page(
            notes: original,
            caps: .init(offsetBytes: 0, maxBytes: 64, expectedContentDigest: nil)
        )
        XCTAssertTrue(first.hasMore)

        let mutated = String(repeating: "B", count: 200)
        XCTAssertNotEqual(
            PlanNotesProjectionV1.contentDigest(of: original),
            PlanNotesProjectionV1.contentDigest(of: mutated)
        )
        XCTAssertThrowsError(
            try PlanNotesProjectionV1.page(
                notes: mutated,
                caps: .init(
                    offsetBytes: first.nextOffsetBytes,
                    maxBytes: 64,
                    expectedContentDigest: first.contentDigest
                )
            )
        ) { error in
            let rpc = error as? JSONRPCError
            XCTAssertEqual(rpc?.code, -32009)
            XCTAssertEqual(rpc?.message, "Plan notes changed during pagination.")
            XCTAssertEqual(
                rpc?.data?.objectValue?["expected_content_digest"]?.stringValue,
                first.contentDigest
            )
        }
    }

    // MARK: Compact update event

    /// WHY: the previous event embedded full notes and could stall the WS
    /// queue; compact metadata must stay tiny and force lazy rehydration.
    func testCompactUpdateEvent_hasNoFullNotesAndStaysSmall() throws {
        let huge = String(repeating: "N", count: 512 * 1024)
        let thread = AgentThreadID()
        let event = PlanNotesProjectionV1.compactUpdateEvent(threadId: thread, notes: huge)
        guard case .object(let body) = event else {
            return XCTFail("expected object")
        }
        XCTAssertNil(body["notes"], "full notes must not ride the update event")
        XCTAssertEqual(body["rehydrate_required"], .bool(true))
        XCTAssertEqual(body["thread_id"]?.stringValue, thread.value.uuidString)
        XCTAssertEqual(body["protocol_version"], .number(1))
        XCTAssertEqual(body["total_bytes"], .number(Double(huge.utf8.count)))
        XCTAssertEqual(body["content_digest"]?.stringValue, PlanNotesProjectionV1.contentDigest(of: huge))
        XCTAssertEqual(body["revision"]?.stringValue, body["content_digest"]?.stringValue)
        let preview = try XCTUnwrap(body["preview"]?.stringValue)
        XCTAssertLessThanOrEqual(preview.utf8.count, PlanNotesProjectionV1.eventPreviewMaxBytes + 3)
        XCTAssertEqual(body["preview_truncated"], .bool(true))

        let envelope = JSONRPCResponse(
            id: .number(1),
            result: event
        )
        // Event itself (as a stand-in frame body) must be tiny vs 512 KiB notes.
        let encoded = try JSONEncoder().encode(envelope)
        XCTAssertLessThan(encoded.count, 4 * 1024,
                          "compact event encoded \(encoded.count) — must not carry the note body")
    }

    /// WHY: empty notes still need a stable digest so clients can detect a
    /// clear-vs-absent transition while paging.
    func testPage_emptyNotes() throws {
        let page = try PlanNotesProjectionV1.page(
            notes: "",
            caps: .init(offsetBytes: 0, maxBytes: 1024, expectedContentDigest: nil)
        )
        XCTAssertEqual(page.notes, "")
        XCTAssertEqual(page.totalBytes, 0)
        XCTAssertEqual(page.returnedBytes, 0)
        XCTAssertFalse(page.hasMore)
        XCTAssertFalse(page.truncated)
        XCTAssertEqual(page.contentDigest, PlanNotesProjectionV1.contentDigest(of: ""))
    }

    /// WHY: offset past end must fail explicitly so a buggy client does not
    /// treat "empty page" as "end of notes" when the cursor is simply wrong.
    func testPage_rejectsOffsetPastEnd() {
        XCTAssertThrowsError(
            try PlanNotesProjectionV1.page(
                notes: "abc",
                caps: .init(offsetBytes: 10, maxBytes: 8, expectedContentDigest: nil)
            )
        ) { error in
            XCTAssertEqual((error as? JSONRPCError)?.code, -32602)
        }
    }
}
