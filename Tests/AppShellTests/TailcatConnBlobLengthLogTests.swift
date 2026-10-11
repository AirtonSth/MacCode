import XCTest
@testable import AppShell

/// The published ConnBlob's size decides whether a blob could ever ride a
/// push payload, so the host logs it. The blob itself is a credential: the
/// line may carry the endpoint count and byte lengths, and nothing else.
final class TailcatConnBlobLengthLogTests: XCTestCase {
    private let asciiBlob = "AAAA-primary-conn-blob-secret"
    private let multiByteBlob = "derp-ñ-鍵-🔑"

    func testLine_carriesUTF8ByteLengthPerPriority_andNeverTheBlob() {
        let line = TailcatRuntimeSupervisor.connBlobLengthLogLine(endpoints: [
            TailcatCatalogEndpoint(kind: .derp, priority: 0, connBlob: asciiBlob),
            TailcatCatalogEndpoint(kind: .derp, priority: 1, connBlob: multiByteBlob),
        ])

        XCTAssertNotEqual(
            multiByteBlob.count,
            multiByteBlob.utf8.count,
            "fixture must be multi-byte, or it cannot tell bytes from characters"
        )
        XCTAssertEqual(
            line,
            "tailcat_publish endpoints=2 conn_blob_len=0:29,1:16",
            "a push payload is budgeted in bytes: the length must be the UTF-8 byte count, not the character count"
        )
        XCTAssertFalse(line.contains(asciiBlob), "the ConnBlob is a credential and must not reach the log")
        XCTAssertFalse(line.contains(multiByteBlob), "the ConnBlob is a credential and must not reach the log")
        for fragment in ["AAAA", "secret", "derp", "🔑"] {
            XCTAssertFalse(line.contains(fragment), "no part of a ConnBlob may reach the log (\(fragment))")
        }
    }

    func testLine_forSingleEndpoint_keepsItsPriority() {
        let line = TailcatRuntimeSupervisor.connBlobLengthLogLine(endpoints: [
            TailcatCatalogEndpoint(kind: .derp, priority: 1, connBlob: multiByteBlob),
        ])

        XCTAssertEqual(
            line,
            "tailcat_publish endpoints=1 conn_blob_len=1:16",
            "when only the fallback relay started, the length must stay attributed to priority 1"
        )
        XCTAssertFalse(line.contains(multiByteBlob), "the ConnBlob is a credential and must not reach the log")
    }
}
