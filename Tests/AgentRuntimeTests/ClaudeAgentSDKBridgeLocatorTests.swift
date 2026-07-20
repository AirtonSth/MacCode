import XCTest
@testable import AgentRuntime

/// WHY: release builds used `#filePath` for the Claude SDK bridge, baking the
/// GitLab Runner absolute path into the binary. Customers then saw
/// "bridge script not found: …/.gitlab-runner/builds/…/ClaudeAgentSDKBridge.mjs".
final class ClaudeAgentSDKBridgeLocatorTests: XCTestCase {

    func test_resolvePath_prefersReadableOverride() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-bridge-locate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridge = tmp.appendingPathComponent("ClaudeAgentSDKBridge.mjs")
        try "export {}\n".write(to: bridge, atomically: true, encoding: .utf8)

        let resolved = ClaudeAgentSDKBridgeLocator.resolvePath(override: bridge.path)
        XCTAssertEqual(resolved, bridge.path)
    }

    func test_resolvePath_skipsUnreadableCIStylePathAndFallsThrough() {
        // Simulated baked-in CI path that does not exist on this machine.
        let ciPath = "/Users/nobody/.gitlab-runner/builds/fake-\(UUID().uuidString)/ClaudeAgentSDKBridge.mjs"
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: ciPath))
        let resolved = ClaudeAgentSDKBridgeLocator.resolvePath(override: ciPath, environment: [:])
        XCTAssertNotEqual(resolved, ciPath,
                          "unreadable CI absolute path must be skipped")
        // Fall through should still find the real checkout bridge for local tests.
        XCTAssertNotNil(resolved)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: resolved ?? ""))
    }

    func test_resolvePath_findsCheckoutSourceBridge() {
        // Developer / unit-test layout: Sources/AgentRuntime next to package root.
        let resolved = ClaudeAgentSDKBridgeLocator.resolvePath(override: nil)
        XCTAssertNotNil(resolved, "checkout must resolve the real ClaudeAgentSDKBridge.mjs")
        XCTAssertTrue(
            resolved?.hasSuffix("ClaudeAgentSDKBridge.mjs") == true,
            "resolved path must be the bridge script"
        )
        XCTAssertTrue(
            FileManager.default.isReadableFile(atPath: resolved ?? ""),
            "resolved bridge must be readable"
        )
        XCTAssertFalse(
            resolved?.contains(".gitlab-runner/builds/") == true,
            "must not resolve to a CI runner path"
        )
    }

    func test_notFoundMessage_listsSearchLocations() {
        let message = ClaudeAgentSDKBridgeLocator.notFoundMessage(override: "/nope/missing.mjs")
        XCTAssertTrue(message.contains("Claude Agent SDK bridge script not found"))
        XCTAssertTrue(message.contains("Tried:"))
        XCTAssertTrue(message.contains("/nope/missing.mjs"))
    }
}
