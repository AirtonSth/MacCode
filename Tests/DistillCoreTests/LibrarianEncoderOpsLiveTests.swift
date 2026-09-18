import XCTest
@testable import DistillCore

/// Real encoder inference for the ranking ops. Gated like the repo's other live
/// MLX tests (`REMOTE_CODE_TOKEN_SAVER_LIVE_ENCODER_TEST=1`) because it loads the
/// real BERT embedder; the deterministic path is covered by the lexical fallback
/// assertions in `LibrarianOpCoverageTests`.
final class LibrarianEncoderOpsLiveTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_LIVE_ENCODER_TEST"] == "1" else {
            throw XCTSkip("Set REMOTE_CODE_TOKEN_SAVER_LIVE_ENCODER_TEST=1 to run real MLX encoder inference.")
        }
    }

    func test_encoderRankAndWorkspaceSearchUseRealEmbeddings() async throws {
        try requireLive()
        let backend = try MLXEmbeddingBackend(manifest: TokenSaverApprovedEncoderManifests.bgeMicro)
        try await backend.warmup()
        let provider = LibrarianEmbeddingProvider(
            model: TokenSaverApprovedEncoderManifests.bgeMicro.id
        ) { texts in
            guard let vectors = try? await backend.embed(texts) else { return nil }
            return vectors.map { $0.map(Double.init) }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-encoder-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "func renderWidget(config: WidgetConfig) -> String { \"<widget/>\" }"
            .write(to: root.appendingPathComponent("Widget.swift"), atomically: true, encoding: .utf8)
        try "func bakeSourdough(flour: Int, water: Int) -> Bread { Bread() }"
            .write(to: root.appendingPathComponent("Bakery.swift"), atomically: true, encoding: .utf8)
        try "func rotateLogs(directory: String) { FileManager.default.temporaryDirectory }"
            .write(to: root.appendingPathComponent("Logs.swift"), atomically: true, encoding: .utf8)

        var environment = LibrarianOpEnvironment.live
        environment.embedder = provider
        environment.defaultRoot = root.path
        let dispatcher = LibrarianDispatcher(environment: environment)

        var rankRequest = LibrarianRequest(id: "encoder_rank", provider: "live-encoder")
        rankRequest.input = [
            "func renderWidget() { return \"widget\" }",
            "func bakeSourdough() { return Bread() }",
            "func rotateLogs() { }"
        ].joined(separator: "\n")
        rankRequest.question = "where is the widget rendered?"
        rankRequest.paths = ["Widget.swift"]
        let ranked = await dispatcher.dispatch(rankRequest)
        XCTAssertEqual(ranked.status, .ok, ranked.text)
        XCTAssertTrue(ranked.text.contains("mode=embedding"),
                      "the encoder lane must produce real embeddings for encoder_rank: \(ranked.text)")

        var searchRequest = LibrarianRequest(id: "workspace_semantic_search", provider: "live-encoder")
        searchRequest.question = "sourdough bread recipe"
        searchRequest.root = root.path
        let search = await dispatcher.dispatch(searchRequest)
        XCTAssertEqual(search.status, .ok, search.text)
        XCTAssertTrue(search.text.contains("mode=embedding"), search.text)
        XCTAssertTrue(search.text.contains("Bakery.swift"),
                      "embedding search must rank the semantically closest file first: \(search.text)")
        await backend.reclaimIdleMemory()
    }

    /// The embedding branch of the workspace index, driven hermetically: the
    /// encoder *service* is injected (the real MLX one cannot load its metallib in
    /// a SwiftPM test process), and the unit under test — ranking, mode disclosure
    /// and the vector path — is the shipped code.
    func test_embeddingProviderDrivesRankingAndDisclosesMode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-encoder-injected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "func renderWidget() { return \"widget\" }"
            .write(to: root.appendingPathComponent("Widget.swift"), atomically: true, encoding: .utf8)
        try "func bakeSourdough() { return bread }"
            .write(to: root.appendingPathComponent("Bakery.swift"), atomically: true, encoding: .utf8)

        // Deterministic stand-in for the encoder lane: token-hash bag of words.
        let provider = LibrarianEmbeddingProvider(model: "injected-test-embedder") { texts in
            texts.map { text in
                var vector = [Double](repeating: 0, count: 64)
                for token in LibrarianLexicalRanker.tokens(text) {
                    let index = abs(token.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 64
                    vector[index] += 1
                }
                return vector
            }
        }

        var environment = LibrarianOpEnvironment.live
        environment.embedder = provider
        environment.defaultRoot = root.path
        let dispatcher = LibrarianDispatcher(environment: environment)

        var searchRequest = LibrarianRequest(id: "workspace_semantic_search", provider: "injected-embedder")
        searchRequest.question = "sourdough bread"
        searchRequest.root = root.path
        let search = await dispatcher.dispatch(searchRequest)
        XCTAssertEqual(search.status, .ok, search.text)
        XCTAssertTrue(search.text.contains("mode=embedding"),
                      "an available embedding provider must be used for the search: \(search.text)")
        XCTAssertTrue(search.text.contains("Bakery.swift"), search.text)

        var rankRequest = LibrarianRequest(id: "encoder_rank", provider: "injected-embedder")
        rankRequest.input = "func renderWidget() {}\nfunc bakeSourdough() {}"
        rankRequest.question = "sourdough bread recipe"
        rankRequest.paths = ["Bakery.swift"]
        let ranked = await dispatcher.dispatch(rankRequest)
        XCTAssertEqual(ranked.status, .ok, ranked.text)
        XCTAssertTrue(ranked.text.contains("mode=embedding"), ranked.text)
    }
}
