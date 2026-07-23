import XCTest
@testable import AgentRuntime
import CoreModel

final class TokenSaverCensusSeamTests: XCTestCase {
    override func tearDown() {
        // Restore production default after tests that clear/replace the store.
        TokenSaverCensusSeam.sharedStore = TokenSaverCensusStore()
        super.tearDown()
    }

    func test_claudeProviderVisibleLine_unchangedWithCensusStoreInstalled() {
        let store = TokenSaverCensusStore()
        TokenSaverCensusSeam.sharedStore = store
        let payload = Data(#"{"type":"assistant","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#.utf8)
        let binding = TokenSaverCensusSeam.defaultBinding(
            trigger: "provider_stream_line",
            provider: "claude",
            providerAdapterVersion: "cli-stream-json",
            toolShape: "stream_json_line"
        )
        let out = TokenSaverCensusSeam.observeProviderVisiblePayload(
            payload,
            binding: binding,
            isSameUser: true
        )
        XCTAssertEqual(out, payload)
        XCTAssertEqual(store.snapshot().count, 1)
        XCTAssertEqual(store.snapshot()[0].bindingDigestHex, binding.digestHex)
    }

    func test_nilStore_isIdentity() {
        TokenSaverCensusSeam.sharedStore = nil
        let payload = Data("provider-bytes".utf8)
        let binding = TokenSaverCensusSeam.defaultBinding(
            trigger: "x",
            provider: "codex",
            providerAdapterVersion: "1",
            toolShape: "y"
        )
        XCTAssertEqual(
            TokenSaverCensusSeam.observeProviderVisiblePayload(payload, binding: binding, isSameUser: true),
            payload
        )
    }

    func test_defaultSharedStore_isInstalledAndRecordsOutboundBytesUnchanged() {
        // Do not reinstall: production default must already be non-nil.
        XCTAssertNotNil(TokenSaverCensusSeam.sharedStore, "production default store must be installed")
        let store = TokenSaverCensusSeam.sharedStore!
        store.reset()
        let outbound = Data(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#.utf8) + Data([0x0A])
        let binding = TokenSaverCensusSeam.defaultBinding(
            trigger: "provider_outbound_user",
            provider: "claude",
            providerAdapterVersion: "cli-stream-json",
            toolShape: "user_json_line"
        )
        let written = TokenSaverCensusSeam.observeProviderVisiblePayload(
            outbound,
            binding: binding,
            streamKind: .completedTranscript,
            isSameUser: true
        )
        XCTAssertEqual(written, outbound)
        XCTAssertEqual(store.snapshot().count, 1)
        XCTAssertGreaterThan(store.snapshot()[0].eligibleTokens, 0)
    }

    func test_crossUser_isNotRecorded() {
        let store = TokenSaverCensusStore()
        TokenSaverCensusSeam.sharedStore = store
        let payload = Data("x".utf8)
        let binding = TokenSaverCensusSeam.defaultBinding(
            trigger: "t",
            provider: "claude",
            providerAdapterVersion: "1",
            toolShape: "s"
        )
        _ = TokenSaverCensusSeam.observeProviderVisiblePayload(
            payload,
            binding: binding,
            isSameUser: false
        )
        XCTAssertEqual(store.snapshot().count, 0)
    }
}
