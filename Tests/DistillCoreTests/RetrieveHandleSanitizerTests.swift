import XCTest
@testable import DistillCore

final class RetrieveHandleSanitizerTests: XCTestCase {
    func test_stripsHandleMarker() {
        let text = "Build passed. Full log: [[rc:2cf24dba5fb0a30e]]"
        let out = RetrieveHandleSanitizer.strip(text)
        XCTAssertEqual(out, "Build passed. Full log:")
        XCTAssertFalse(RetrieveHandleSanitizer.containsHandle(out))
    }

    func test_stripsMultipleAndTidiesWhitespace() {
        let text = "line one [[rc:aaaa]]\nline two\n\n\n[[rc:bbbb]]\nline three"
        let out = RetrieveHandleSanitizer.strip(text)
        XCTAssertFalse(out.contains("[[rc:"))
        XCTAssertFalse(out.contains("\n\n\n"), "3+ blank lines collapsed")
        XCTAssertTrue(out.contains("line one"))
        XCTAssertTrue(out.contains("line three"))
    }

    func test_leavesCleanTextUnchanged() {
        let text = "An ordinary final answer with no markers."
        XCTAssertEqual(RetrieveHandleSanitizer.strip(text), text)
        XCTAssertFalse(RetrieveHandleSanitizer.containsHandle(text))
    }

    func test_detectsHandlePresence() {
        XCTAssertTrue(RetrieveHandleSanitizer.containsHandle("x [[rc:deadbeef]] y"))
        XCTAssertFalse(RetrieveHandleSanitizer.containsHandle("no handle here"))
    }

    func test_stripsScopedCapabilityMarker() {
        let capability = "rcv1.90a43e12-9e4b-49a4-99de-ab3cb929fa2d.2f1df7dc-ca87-474a-80d2-4cf886a1855d59c9c425-5f72-4455-b6e1-d196a2b84f40"
        let text = "Compressed output [[rc:\(capability)]]"

        XCTAssertEqual(RetrieveHandleSanitizer.strip(text), "Compressed output")
        XCTAssertTrue(RetrieveHandleSanitizer.containsHandle(text))
    }

    func test_leavesMalformedCapabilityLiteralUnchanged() {
        let text = "User text [[rc:rcv1.not-a-uuid.not-a-secret]]"

        XCTAssertEqual(RetrieveHandleSanitizer.strip(text), text)
        XCTAssertFalse(RetrieveHandleSanitizer.containsHandle(text))
    }
}
