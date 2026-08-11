import XCTest
@testable import AgentRuntime

/// Regression coverage for the bounded pipe-drain API.
///
/// The default path must preserve provider bytes so an exit-time drain cannot
/// silently remove a terminal NDJSON frame. An explicit cap is only for callers
/// that deliberately choose lossy diagnostic retention; it still drains the
/// descriptor, and the runtime keeps the absolute deadline on every read loop.
final class BoundedPipeDrainCapTests: XCTestCase {

    func test_defaultDrainPreservesAllProviderBytes() throws {
        let pipe = Pipe()
        let payload = Data(repeating: 0x41, count: 64) + Data(repeating: 0x42, count: 64)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(
            BoundedPipeDrain.readRemaining(from: pipe.fileHandleForReading, timeout: 0.1),
            payload,
            "the default provider drain must not silently drop a terminal frame"
        )
    }

    func test_explicitCapRetainsPrefixWhileDraining() throws {
        let pipe = Pipe()
        let payload = Data(repeating: 0x41, count: 64) + Data(repeating: 0x42, count: 64)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        let retained = BoundedPipeDrain.readRemaining(
            from: pipe.fileHandleForReading,
            timeout: 0.1,
            maxBytes: 32
        )
        XCTAssertEqual(
            retained,
            Data(repeating: 0x41, count: 32),
            "an explicit diagnostic cap retains the first bytes while the drain consumes the rest"
        )
    }

    func test_underCapPreservesFullPayload() throws {
        let pipe = Pipe()
        let payload = Data("hello-ndjson\n".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(
            BoundedPipeDrain.readRemaining(
                from: pipe.fileHandleForReading,
                timeout: 0.1,
                maxBytes: 1_024
            ),
            payload
        )
    }
}
