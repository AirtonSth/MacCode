import XCTest
@testable import DistillCore

/// REAL BERT classification inference (I8.2 NLI, I8.4 NER) — downloads the checkpoints
/// and runs actual MLX inference. License NOT vetted; LOCAL validation only. Gated:
///
///   REMOTE_CODE_TOKEN_SAVER_LIVE_ENCODER_TEST=1 \
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     swift test --filter MLXBertClassifierLiveTests
final class MLXBertClassifierLiveTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_LIVE_ENCODER_TEST"] == "1" else {
            throw XCTSkip("Set REMOTE_CODE_TOKEN_SAVER_LIVE_ENCODER_TEST=1 to download + run the real BERT NLI/NER models.")
        }
    }

    func test_realNLIEntailmentVsContradiction() async throws {
        try requireLive()
        let nli = MLXBertClassifierBackend(model: .mnli)
        try await nli.warmup()

        let entail = try await nli.entailment(
            premise: "A man is eating a plate of food.",
            hypothesis: "A man is eating.")
        let contradict = try await nli.entailment(
            premise: "A man is eating a plate of food.",
            hypothesis: "Nobody is eating anything.")
        print("REAL-NLI entail=\(entail)  contradict=\(contradict)")

        // The entailing pair scores entailment above contradiction; the contradicting
        // pair flips it. (If this fails, the LABEL_0/1/2 order in .mnli is wrong.)
        XCTAssertGreaterThan(entail.entailment, entail.contradiction, "entailing pair: entailment should win")
        XCTAssertGreaterThan(contradict.contradiction, contradict.entailment, "contradicting pair: contradiction should win")
    }

    func test_realLLMLingua2PrunesStopwordsBelowContent() async throws {
        try requireLive()
        let pruner = MLXBertClassifierBackend(model: .llmlingua2)
        try await pruner.warmup()
        let scores = try await pruner.tokenKeepScores(
            "The quick brown fox jumps over the lazy dog and then it ran away very quickly today")
        print("REAL-LLMLINGUA2 scores=\(scores.map { "\($0.token):\(String(format: "%.2f", $0.keep))" }.joined(separator: " "))")
        func score(_ t: String) -> Float { scores.first { $0.token.lowercased() == t }?.keep ?? -1 }
        let content = max(score("fox"), score("dog"), score("jumps"), score("ran"))
        let stop = min(score("the"), score("and"), score("it"))
        XCTAssertGreaterThan(content, stop, "content words should score higher to keep than stopwords")
    }

    func test_realNERFindsPersonAndLocation() async throws {
        try requireLive()
        let ner = MLXBertClassifierBackend(model: .ner)
        try await ner.warmup()
        let tagged = try await ner.classifyTokens("My name is Wolfgang and I live in Berlin")
        print("REAL-NER tags=\(tagged)")
        let labels = Set(tagged.map { $0.label })
        XCTAssertTrue(labels.contains { $0.contains("PER") }, "should tag a person")
        XCTAssertTrue(labels.contains { $0.contains("LOC") }, "should tag a location")
        let ents = try await ner.entities(in: "My name is Wolfgang and I live in Berlin")
        XCTAssertFalse(ents.isEmpty, "should extract at least one entity surface")
    }
}
