import XCTest
import CoreModel
@testable import AgentRuntime

/// Regression tests for the machine-agnostic runtime provisioning of the Claude
/// Agent SDK bridge. The shipped bug was "Claude Agent SDK bridge exited with
/// status 1" on a fresh install because the SDK's real runtime dependencies —
/// its peerDependencies AND a platform-gated native optionalDependency (the
/// ~205MB `claude` engine) — were not installed deterministically, and a
/// version-only completeness gate cached the broken tree as usable.
final class ClaudeAgentSDKBridgeProvisioningTests: XCTestCase {

    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePackage(_ modules: URL, _ name: String, version: String) throws {
        let dir = modules.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"name":"\#(name)","version":"\#(version)"}"#
            .write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    }

    private func plan(cacheDir: URL, native: String, specs: [String]) -> ClaudeAgentSDKBridgeAdapter.RuntimeProvisionPlan {
        ClaudeAgentSDKBridgeAdapter.RuntimeProvisionPlan(
            cacheDir: cacheDir,
            cachedBridgePath: cacheDir.appendingPathComponent("ClaudeAgentSDKBridge.mjs").path,
            sdkSpec: "@anthropic-ai/claude-agent-sdk@0.3.157",
            sdkVersion: "0.3.157",
            nativePackageName: native,
            specs: specs
        )
    }

    // WHY: the completeness gate must verify the FULL runtime closure — every
    // pinned JS dep AND the platform-matched native binary present & executable.
    // A tree that is missing the native binary (npm silently skips a failed/omit
    // optional dependency and still exits 0) must NOT be reported complete, or the
    // exact shipped bug recurs: the bridge launches and dies at query time.
    func test_runtimeTreeComplete_requiresPinnedDepsAndExecutableNativeBinary() throws {
        let cache = try makeTempDir("rc-provision-complete")
        defer { try? FileManager.default.removeItem(at: cache) }
        let modules = cache.appendingPathComponent("node_modules", isDirectory: true)
        let native = "@anthropic-ai/claude-agent-sdk-darwin-arm64"
        let specs = [
            "@anthropic-ai/claude-agent-sdk@0.3.157",
            "\(native)@0.3.157",
            "zod@4.4.3",
            "@anthropic-ai/sdk@0.98.0",
            "@modelcontextprotocol/sdk@1.29.0",
        ]
        let p = plan(cacheDir: cache, native: native, specs: specs)

        // Empty tree -> not complete.
        XCTAssertFalse(ClaudeAgentSDKBridgeAdapter.runtimeTreeComplete(p))

        // All JS deps present at the pinned versions, but native binary absent.
        try writePackage(modules, "@anthropic-ai/claude-agent-sdk", version: "0.3.157")
        try writePackage(modules, native, version: "0.3.157")
        try writePackage(modules, "zod", version: "4.4.3")
        try writePackage(modules, "@anthropic-ai/sdk", version: "0.98.0")
        try writePackage(modules, "@modelcontextprotocol/sdk", version: "1.29.0")
        XCTAssertFalse(ClaudeAgentSDKBridgeAdapter.runtimeTreeComplete(p),
                       "a tree missing the platform-native binary must NOT be treated as complete")

        // Add a NON-executable binary file -> still not complete.
        let binary = modules.appendingPathComponent(native).appendingPathComponent("claude")
        try Data([0x00]).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)
        XCTAssertFalse(ClaudeAgentSDKBridgeAdapter.runtimeTreeComplete(p),
                       "a present-but-non-executable native binary must NOT be treated as complete")

        // Make it executable -> complete.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertTrue(ClaudeAgentSDKBridgeAdapter.runtimeTreeComplete(p),
                      "SDK + pinned peers + executable native binary is a complete tree")

        // A peer at the WRONG version -> not complete (drives re-provision).
        try writePackage(modules, "zod", version: "3.0.0")
        XCTAssertFalse(ClaudeAgentSDKBridgeAdapter.runtimeTreeComplete(p),
                       "an under/over-version peer must invalidate completeness so the pin is reconciled")
    }

    // WHY: scoped npm names contain '@' inside the name, so a naive first-'@'
    // split corrupts the version; completeness would then always fail.
    func test_parseSpec_handlesScopedNames() {
        XCTAssertEqual(ClaudeAgentSDKBridgeAdapter.parseSpec("zod@4.4.3")?.name, "zod")
        XCTAssertEqual(ClaudeAgentSDKBridgeAdapter.parseSpec("zod@4.4.3")?.version, "4.4.3")
        let scoped = ClaudeAgentSDKBridgeAdapter.parseSpec("@anthropic-ai/sdk@0.98.0")
        XCTAssertEqual(scoped?.name, "@anthropic-ai/sdk")
        XCTAssertEqual(scoped?.version, "0.98.0")
        let platform = ClaudeAgentSDKBridgeAdapter.parseSpec("@anthropic-ai/claude-agent-sdk-darwin-arm64@0.3.157")
        XCTAssertEqual(platform?.name, "@anthropic-ai/claude-agent-sdk-darwin-arm64")
        XCTAssertEqual(platform?.version, "0.3.157")
    }

    // WHY: the default install spec set is what fixes the shipped bug — it must
    // name the exact pinned peers, deterministically, on every machine.
    func test_defaultRuntimePeerSpecs_areExactPinned() {
        XCTAssertEqual(
            ClaudeAgentSDKBridgeAdapter.runtimePeerSpecs(sdkSpec: ClaudeAgentSDKBridgeAdapter.defaultSDKPackageSpec, npmPath: "/usr/bin/false"),
            ["zod@4.4.3", "@anthropic-ai/sdk@0.98.0", "@modelcontextprotocol/sdk@1.29.0"],
            "the default SDK must resolve to its exact pinned peers without any registry call")
    }

    /// WHY: two RemoteCode builds can run concurrently. A shared fixed bridge
    /// filename lets the older app overwrite the newer PostToolUse interceptor
    /// while its Node process is starting.
    func test_cachedBridgeFileName_isContentAddressed() {
        let older = ClaudeAgentSDKBridgeAdapter.cachedBridgeFileName(
            source: "return { updatedMCPToolOutput: output };"
        )
        let current = ClaudeAgentSDKBridgeAdapter.cachedBridgeFileName(
            source: "return { updatedToolOutput: output, updatedMCPToolOutput: output };"
        )

        XCTAssertNotEqual(older, current)
        XCTAssertEqual(
            current,
            ClaudeAgentSDKBridgeAdapter.cachedBridgeFileName(
                source: "return { updatedToolOutput: output, updatedMCPToolOutput: output };"
            ),
            "identical bridge bytes must resolve to one stable cache path"
        )
        XCTAssertTrue(current.hasPrefix("ClaudeAgentSDKBridge-"))
        XCTAssertTrue(current.hasSuffix(".mjs"))
    }

    // WHY: the platform-native package must track the running platform/arch, never
    // a hardcoded value, so Apple Silicon / Intel / Rosetta each get the right
    // binary. The host fallback must still produce a well-formed platform-arch.
    func test_hostPlatformArch_isWellFormed() {
        let value = ClaudeAgentSDKBridgeAdapter.hostPlatformArch()
        XCTAssertTrue(value.contains("-"), "platform-arch must be '<platform>-<arch>', got \(value)")
        #if arch(arm64)
        XCTAssertTrue(value.hasSuffix("-arm64"))
        #elseif arch(x86_64)
        XCTAssertTrue(value.hasSuffix("-x64"), "Node reports x86_64 as 'x64'")
        #endif
    }

    // WHY: GUI-launched apps whose PATH omits nvm/volta/fnm must still pick the
    // HIGHEST installed Node, numerically (not lexically — 'v9' must lose to 'v18').
    func test_versionKey_ordersNumericallyNotLexically() {
        let v9 = ClaudeAgentSDKBridgeAdapter.versionKey("v9.0.0")
        let v18 = ClaudeAgentSDKBridgeAdapter.versionKey("v18.20.4")
        XCTAssertTrue(v9.lexicographicallyPrecedes(v18),
                      "v18 must sort ABOVE v9 by numeric components, not string order")
        XCTAssertEqual(ClaudeAgentSDKBridgeAdapter.versionKey("20.11.1"), [20, 11, 1])
    }

    // WHY: merging the raw Node stderr tail into the terminal diagnostic must not
    // leak CI/build absolute paths (the Airton-class gitlab-runner symptom the
    // locator redaction guards) or the user's home directory.
    func test_scrubPathsForDisplay_removesBuildAndHomePaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let raw = "Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'zod' imported from /Users/ci/.gitlab-runner/builds/abc123/proj/Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs and \(home)/Library/App/x.mjs"
        let scrubbed = ClaudeAgentSDKBridgeAdapter.scrubPathsForDisplay(raw)
        XCTAssertFalse(scrubbed.contains(".gitlab-runner/builds/"),
                       "CI/build absolute paths must never reach the user diagnostic; got: \(scrubbed)")
        XCTAssertTrue(scrubbed.contains("<build>"))
        XCTAssertFalse(scrubbed.contains(home), "the user's home dir must be collapsed to ~; got: \(scrubbed)")
        XCTAssertTrue(scrubbed.contains("ERR_MODULE_NOT_FOUND"),
                      "the real reason must be preserved after scrubbing")
    }
}
