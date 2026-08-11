import XCTest
@testable import DistillCore
@testable import CoreModel

final class BashStdoutLineBudgetTests: XCTestCase {
    private final class DurableMemoryStore: TokenSaverTypedCrushers.BlobStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func store(id: String, plaintext: Data) throws {
            lock.lock()
            values[id] = plaintext
            lock.unlock()
        }

        func retrieve(id: String) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            guard let value = values[id] else {
                throw TokenSaverTypedCrushers.MemoryStore.StoreError.missing
            }
            return value
        }
    }

    func testDoesNotApplyWhenUnderBudget() {
        let text = (0..<20).map { "line \($0)" }.joined(separator: "\n")
        let r = BashStdoutLineBudget.apply(text, handle: "abc", maxLines: 80)
        XCTAssertFalse(r.applied)
        XCTAssertEqual(r.text, text)
    }

    func testAppliesHeadTailWithRecoveryMarker() {
        let text = (0..<200).map { "line \($0) build noise" }.joined(separator: "\n")
        let handle = "deadbeefcafebabe"
        let r = BashStdoutLineBudget.apply(text, handle: handle, maxLines: 80, keepLast: 16)
        XCTAssertTrue(r.applied)
        XCTAssertTrue(r.text.contains(SR2WirePolicy.recoveryMarker(for: handle)))
        XCTAssertTrue(r.text.contains("line 0 build noise"))
        XCTAssertTrue(r.text.contains("line 199 build noise"))
        XCTAssertFalse(r.text.contains("line 100 build noise"), "middle should be elided")
        XCTAssertLessThan(r.keptLineCount, 200)
        XCTAssertEqual(r.originalLineCount, 200)
    }

    /// WHY: The prepass must only emit a head/tail reduction after the original
    /// has been stored and read back through the injected durable store.
    func testPrepassBashBudgetStoresOriginalBeforeLoss() throws {
        TokenSaverWaveLiveRollout.activate(.waveBCrushers)
        TokenSaverWaveLosslessPrepass.setLossyCrushersOptInForTesting(true)
        defer {
            TokenSaverWaveLosslessPrepass.setLossyCrushersOptInForTesting(nil)
            TokenSaverWaveLiveRollout.resetForTesting()
        }

        let input = (0..<200)
            .map { "bash output line \($0) \(String(repeating: "x", count: 8))" }
            .joined(separator: "\n")
        let store = DurableMemoryStore()
        let result = try XCTUnwrap(
            TokenSaverWaveLosslessPrepass.apply(
                input: input,
                toolHint: "bash",
                durableStore: store
            )
        )
        XCTAssertEqual(result.trigger, "bash_line_budget")

        let marker = try XCTUnwrap(SR2WirePolicy.recoveryMarker(in: result.output))
        let handle = String(marker.dropFirst("[[rc:".count).dropLast("]]".count))
        let recovered = try store.retrieve(id: handle)
        XCTAssertEqual(String(data: recovered, encoding: .utf8), input)
    }
}
