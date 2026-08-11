import XCTest
@testable import Persistence

/// S3: oversized authoritative payload store-before-loss + byte-identical rehydrate.
final class AuthoritativePayloadRecoveryTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: ReversibleContentStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = ReversibleContentStore(db: db)
    }

    override func tearDownWithError() throws {
        store = nil
        db = nil
        try super.tearDownWithError()
    }

    func test_requiresRecovery_onlyAbove16MiB() {
        XCTAssertFalse(AuthoritativePayloadRecovery.requiresRecovery(byteCount: 16 * 1024 * 1024))
        XCTAssertTrue(AuthoritativePayloadRecovery.requiresRecovery(byteCount: 16 * 1024 * 1024 + 1))
    }

    func test_smallPayload_passesThroughWithoutStore() throws {
        let original = Data("hello exact".utf8)
        let result = try AuthoritativePayloadRecovery.prepareForPresentation(
            data: original,
            store: store,
            limit: 1024
        )
        XCTAssertFalse(result.storedOriginal)
        XCTAssertFalse(result.truncatedForPresentation)
        XCTAssertNil(result.handle)
        XCTAssertEqual(result.presentationText, "hello exact")
    }

    func test_oversizedPayload_storesOriginalAndRehydratesByteIdentical() throws {
        // Use a small limit so the test stays fast while exercising the shipped path.
        let limit = 64
        var bytes = Data(repeating: 0x61, count: limit + 32) // 'a' * 96
        bytes[0] = 0x42
        bytes[limit + 10] = 0x43

        let result = try AuthoritativePayloadRecovery.prepareForPresentation(
            data: bytes,
            store: store,
            limit: limit
        )
        XCTAssertTrue(result.storedOriginal)
        XCTAssertTrue(result.truncatedForPresentation)
        let handle = try XCTUnwrap(result.handle)
        XCTAssertTrue(result.presentationText.contains(handle))
        XCTAssertTrue(result.presentationText.contains("truncated"))
        XCTAssertTrue(result.presentationText.contains(ReversibleContentStore.marker(for: handle)))
        XCTAssertEqual(result.originalByteCount, bytes.count)

        let rehydrated = try AuthoritativePayloadRecovery.rehydrate(
            handle: handle,
            store: store,
            expected: bytes
        )
        XCTAssertEqual(rehydrated, bytes)
    }

    func test_stripUnresolvedHandles_fromFinalAssistantText() {
        let text = "prefix [[rc:deadbeefcafebabe]] mid [[rc:1111222233334444]] end"
        let stripped = AuthoritativePayloadRecovery.stripUnresolvedHandles(from: text) { handle in
            handle == "1111222233334444"
        }
        XCTAssertFalse(stripped.contains("deadbeefcafebabe"))
        XCTAssertTrue(stripped.contains("[[rc:1111222233334444]]"))
        XCTAssertTrue(stripped.contains("prefix"))
        XCTAssertTrue(stripped.contains("end"))
    }

    func test_rehydrateMissing_failsLoud() {
        XCTAssertThrowsError(
            try AuthoritativePayloadRecovery.rehydrate(handle: "00", store: store)
        ) { error in
            XCTAssertEqual(error as? AuthoritativePayloadRecovery.RecoveryError, .unresolvedHandle("00"))
        }
    }

    func test_authoritativeByteCount_usesOriginalFromOwnedTrailer() throws {
        let limit = 64
        let original = Data(repeating: 0x61, count: 500)
        let result = try AuthoritativePayloadRecovery.prepareForPresentation(
            data: original,
            store: store,
            limit: limit
        )
        XCTAssertTrue(result.truncatedForPresentation)
        let presentationBytes = result.presentationText.utf8.count
        XCTAssertLessThan(presentationBytes, original.count)
        // Admission must charge the original size, not the presentation size.
        XCTAssertEqual(
            AuthoritativePayloadRecovery.authoritativeByteCount(forStoredPayload: result.presentationText),
            original.count
        )
        XCTAssertEqual(
            AuthoritativePayloadRecovery.authoritativeByteCount(forStoredPayload: "small"),
            5
        )
    }
}
