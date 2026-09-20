import XCTest
import CoreModel
@testable import AgentRuntime

final class ClaudeHarnessModelDiscoveryTests: XCTestCase {
    func test_initializeProbePreservesHarnessIDsAndEffortMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-harness-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("claude")
        try #"""
        #!/bin/sh
        IFS= read -r request
        printf '%s\n' '{"type":"control_response","response":{"subtype":"success","response":{"models":[{"value":"default","displayName":"Default","description":"Account default","supportsEffort":false,"supportedEffortLevels":[]},{"value":"opus[1m]","displayName":"Opus","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max","ultracode"]},{"value":"claude-fable-5-1[1m]","displayName":"Claude Fable 5.1","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max","ultracode"]},{"value":"sonnet","displayName":"Sonnet","supportsEffort":true,"supportedEffortLevels":["medium"]},{"value":"haiku","displayName":"Haiku","supportsEffort":false,"supportedEffortLevels":[]}]}}}'
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let models = await ClaudeHarnessModelDiscovery.listModels(
            binary: script.path,
            cwd: root.path,
            timeout: 2
        )

        XCTAssertEqual(models.map(\.id), ["default", "opus[1m]", "claude-fable-5-1[1m]", "sonnet", "haiku"])
        let fable = try XCTUnwrap(models.first { $0.id == "claude-fable-5-1[1m]" })
        XCTAssertEqual(fable.label, "Claude Fable 5.1")
        XCTAssertEqual(fable.supportedReasoningEfforts, [.low, .medium, .high, .xhigh, .max, .ultracode])
        XCTAssertTrue(fable.supportsReasoning)
        XCTAssertTrue(fable.supportsCustomModel)
        // WHY: ClaudeRunner prefers this harness catalog over static aliases
        // whenever `claude` answers initialize. Nil windows hid the ctx pill
        // for live Claude models that AnthropicModelDiscovery already labels.
        XCTAssertNil(models.first { $0.id == "default" }?.contextWindowTokens)
        XCTAssertEqual(models.first { $0.id == "opus[1m]" }?.contextWindowTokens, 1_000_000)
        XCTAssertEqual(fable.contextWindowTokens, 1_000_000)
        XCTAssertEqual(models.first { $0.id == "sonnet" }?.contextWindowTokens, 1_000_000)
        XCTAssertEqual(models.first { $0.id == "haiku" }?.contextWindowTokens, 200_000)
    }

    func test_claudeRunnerUsesHarnessBeforeApiFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runner-harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("claude")
        try #"""
        #!/bin/sh
        IFS= read -r request
        printf '%s\n' '{"type":"control_response","response":{"subtype":"success","response":{"models":[{"value":"claude-fable-5-1[1m]","displayName":"Claude Fable 5.1","supportsEffort":true,"supportedEffortLevels":["high"]}]}}}'
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let result = await ClaudeRunner(binaryNameOverride: script.path).listModelsResult(
            environment: ["HOME": root.path],
            cwd: root.path
        )

        XCTAssertFalse(result.isFallback)
        XCTAssertEqual(result.models.map(\.id), ["claude-fable-5-1[1m]"])
    }
}
