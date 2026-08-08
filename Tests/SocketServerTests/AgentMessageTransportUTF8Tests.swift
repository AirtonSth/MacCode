import XCTest
import CryptoKit
@testable import SocketServer

/// Pins utf8Prefix / bodySHA256Hex wire-contract semantics after the O(1) UTF-8
/// jump + contiguous-hash perf rewrite (must match Character-boundary truncation
/// and lowercase SHA-256 hex).
final class AgentMessageTransportUTF8Tests: XCTestCase {
    func test_utf8Prefix_emptyAndNonPositive() {
        XCTAssertEqual(AgentMessageTransport.utf8Prefix("hello", maxBytes: 0), "")
        XCTAssertEqual(AgentMessageTransport.utf8Prefix("hello", maxBytes: -1), "")
        XCTAssertEqual(AgentMessageTransport.utf8Prefix("", maxBytes: 8), "")
    }

    func test_utf8Prefix_underBudgetReturnsIdentity() {
        let text = "short"
        XCTAssertEqual(AgentMessageTransport.utf8Prefix(text, maxBytes: 64), text)
        XCTAssertEqual(AgentMessageTransport.utf8Prefix(text, maxBytes: text.utf8.count), text)
    }

    func test_utf8Prefix_matchesLegacyCharacterForwardScan() {
        let cases: [(String, Int)] = [
            ("hello world", 5),
            ("café ☕️", 6),
            ("flag 🇯🇵 end", 8),
            (String(repeating: "α", count: 200), 50),
            (String(repeating: "😀", count: 64), 20),
            ("a" + String(repeating: "👨‍👩‍👧‍👦", count: 8) + "z", 40),
            (String(repeating: "x", count: 50_000), 2_048),
        ]
        for (text, maxBytes) in cases {
            let got = AgentMessageTransport.utf8Prefix(text, maxBytes: maxBytes)
            let expected = legacyCharacterForwardUTF8Prefix(text, maxBytes: maxBytes)
            XCTAssertEqual(
                got, expected,
                "utf8Prefix mismatch for maxBytes=\(maxBytes) textBytes=\(text.utf8.count)"
            )
            XCTAssertLessThanOrEqual(got.utf8.count, max(0, maxBytes))
        }
    }

    func test_bodySHA256Hex_matchesCryptoKitDataPath() {
        let samples = [
            "",
            "tiny",
            "café",
            String(repeating: "stream-token-", count: 4_096),
        ]
        for sample in samples {
            let expected = SHA256.hash(data: Data(sample.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(AgentMessageTransport.bodySHA256Hex(sample), expected)
        }
    }

    func test_bodySHA256Hex_emptyIsKnownVector() {
        // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        XCTAssertEqual(
            AgentMessageTransport.bodySHA256Hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func test_microbench_utf8Prefix_largeEnvelope() {
        // Qualitative pin: large body → 2 KiB event preview must stay well under
        // Character-forward cost on the same machine. Not a gate; documents intent.
        let body = String(repeating: "token-delta-payload-", count: 100_000) // ~2 MiB
        let limit = AgentMessageTransport.eventContentMaxBytes
        var samples: [Double] = []
        for _ in 0..<3 {
            _ = AgentMessageTransport.utf8Prefix(body, maxBytes: limit) // warm
        }
        for _ in 0..<5 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let prefix = AgentMessageTransport.utf8Prefix(body, maxBytes: limit)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1_000
            samples.append(ms)
            XCTAssertLessThanOrEqual(prefix.utf8.count, limit)
        }
        let median = samples.sorted()[samples.count / 2]
        // Loose ceiling: 2 MiB → 2 KiB prefix should be sub-5ms on any modern Mac.
        XCTAssertLessThan(median, 5.0, "utf8Prefix median \(median)ms samples=\(samples)")
    }

    // MARK: - Legacy reference (must stay Character-forward)

    private func legacyCharacterForwardUTF8Prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var end = text.startIndex
        var used = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let scalarBytes = text[end..<next].utf8.count
            guard used + scalarBytes <= maxBytes else { break }
            used += scalarBytes
            end = next
        }
        return String(text[..<end])
    }
}
