import XCTest
import CoreModel
@testable import AgentRuntime

// Tests for ModelDiscoveryCacheEntry (TTL gate) and AnthropicDiscoveryRequestBuilder.
// No @MainActor needed: all helpers are plain structs/enums.
final class AnthropicModelDiscoveryCacheTests: XCTestCase {

    // MARK: - ModelDiscoveryCacheEntry TTL

    func test_cacheEntry_isValid_withinTTL() {
        // WHY: a freshly-stored entry must be served from cache until TTL elapses
        let entry = ModelDiscoveryCacheEntry(models: [], fetchedAt: Date())
        XCTAssertTrue(entry.isValid(ttl: 3_600, now: Date()))
    }

    func test_cacheEntry_isInvalid_afterTTL() {
        // WHY: after TTL expires the caller must re-fetch; stale data must not be returned
        let past = Date(timeIntervalSinceNow: -3_601)
        let entry = ModelDiscoveryCacheEntry(models: [], fetchedAt: past)
        XCTAssertFalse(entry.isValid(ttl: 3_600, now: Date()))
    }

    func test_cacheEntry_isValid_exactlyAtTTLBoundary() {
        // WHY: boundary at exactly TTL seconds is still stale (strictly less-than check)
        let past = Date(timeIntervalSinceNow: -3_600)
        let entry = ModelDiscoveryCacheEntry(models: [], fetchedAt: past)
        // interval == ttl => NOT valid (< is strict)
        XCTAssertFalse(entry.isValid(ttl: 3_600, now: Date()))
    }

    func test_cacheEntry_isValid_oneSecondBeforeTTL() {
        // WHY: one second before expiry must still be a cache hit
        let fetchedAt = Date()
        let nowPlusMostOfTTL = fetchedAt.addingTimeInterval(3_599)
        let entry = ModelDiscoveryCacheEntry(models: [], fetchedAt: fetchedAt)
        XCTAssertTrue(entry.isValid(ttl: 3_600, now: nowPlusMostOfTTL))
    }

    func test_cacheEntry_preservesModels() {
        // WHY: models stored in cache must be returned verbatim; a mismatch would silently serve wrong data
        let descriptor = AgentModelDescriptor(
            id: "claude-test-1",
            label: "Test Model",
            provider: .claude,
            supportsReasoning: false,
            supportedReasoningEfforts: [],
            supportsCustomModel: true,
            contextWindowTokens: 200_000
        )
        let entry = ModelDiscoveryCacheEntry(models: [descriptor], fetchedAt: Date())
        XCTAssertEqual(entry.models.count, 1)
        XCTAssertEqual(entry.models.first?.id, "claude-test-1")
    }

    // MARK: - AnthropicDiscoveryRequestBuilder

    func test_requestBuilder_usesApiKey_whenNoOAuth() {
        // WHY: existing callers rely on x-api-key auth; regression here breaks production discovery
        let env = ["ANTHROPIC_API_KEY": "sk-ant-test"]
        let req = AnthropicDiscoveryRequestBuilder.build(environment: env)
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertNil(req?.value(forHTTPHeaderField: "Authorization"))
    }

    func test_requestBuilder_prefersOAuthOverApiKey() {
        // WHY: OAuth token must take priority; mixing both would send two auth headers, which Anthropic rejects
        let env = [
            "ANTHROPIC_API_KEY": "sk-ant-test",
            "ANTHROPIC_OAUTH_TOKEN": "oauth-bearer-xyz"
        ]
        let req = AnthropicDiscoveryRequestBuilder.build(environment: env)
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-bearer-xyz")
        XCTAssertNil(req?.value(forHTTPHeaderField: "x-api-key"))
    }

    func test_requestBuilder_setsExplicitTimeout() {
        // WHY: without an explicit short timeout a slow DNS/network can stall model-list forever
        let env = ["ANTHROPIC_API_KEY": "sk-ant-test"]
        let req = AnthropicDiscoveryRequestBuilder.build(environment: env, timeoutSeconds: 10)
        XCTAssertEqual(req?.timeoutInterval, 10)
    }

    func test_requestBuilder_returnsNil_whenNoCredentials() {
        // WHY: without credentials the request would always 401; returning nil lets the caller skip the fetch
        let req = AnthropicDiscoveryRequestBuilder.build(environment: [:])
        XCTAssertNil(req)
    }

    func test_requestBuilder_returnsNil_whenApiKeyIsEmpty() {
        // WHY: an empty key after trimming must be treated the same as absent
        let req = AnthropicDiscoveryRequestBuilder.build(environment: ["ANTHROPIC_API_KEY": "   "])
        XCTAssertNil(req)
    }

    func test_requestBuilder_setsAnthropicVersionHeader() {
        // WHY: missing version header causes a 400 from the Anthropic API
        let env = ["ANTHROPIC_API_KEY": "sk-ant-test"]
        let req = AnthropicDiscoveryRequestBuilder.build(environment: env)
        XCTAssertEqual(req?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func test_requestBuilder_setsVersionHeaderForOAuth() {
        // WHY: OAuth path also needs the version header
        let env = ["ANTHROPIC_OAUTH_TOKEN": "tok"]
        let req = AnthropicDiscoveryRequestBuilder.build(environment: env)
        XCTAssertEqual(req?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func test_requestBuilder_defaultTimeoutIs10Seconds() {
        // WHY: documents and guards the contract that default timeout is short (10 s),
        // not the URLSession default (60 s), preventing hung UI on slow networks
        let env = ["ANTHROPIC_API_KEY": "sk-ant-test"]
        let req = AnthropicDiscoveryRequestBuilder.build(environment: env)
        XCTAssertEqual(req?.timeoutInterval, AnthropicDiscoveryRequestBuilder.defaultTimeoutSeconds)
        XCTAssertEqual(AnthropicDiscoveryRequestBuilder.defaultTimeoutSeconds, 10)
    }
}
