import XCTest
@testable import DistillCore

/// I8.2 NLI gate + I8.4 NER booster, with stub scorers (no model download). The same
/// seams are driven by the REAL BERT models in MLXBertClassifierLiveTests.
final class NLIFaithfulnessGateTests: XCTestCase {
    // I8.2: reject on contradiction, reject on low entailment, accept on entailed.
    func test_nliGateRejectsContradictionAndLowEntailment() async {
        let gate = NLIFaithfulnessGate(minEntailment: 0.5, maxContradiction: 0.3) { _, hyp in
            if hyp.contains("nobody") { return (entail: 0.01, contradict: 0.98) }   // contradiction
            if hyp.contains("maybe")  { return (entail: 0.20, contradict: 0.10) }   // low entailment
            return (entail: 0.95, contradict: 0.01)                                  // entailed
        }
        let ok = await gate.validate(original: "A man is eating food.", compressed: "A man is eating something now.")
        XCTAssertTrue(ok.accepted)
        let contra = await gate.validate(original: "A man is eating food.", compressed: "So nobody is eating here at all.")
        XCTAssertFalse(contra.accepted)
        XCTAssertEqual(contra.reason?.contains("contradiction"), true)
        let weak = await gate.validate(original: "A man is eating food.", compressed: "There is maybe a person around.")
        XCTAssertFalse(weak.accepted)
    }

    func test_nliGateFailsOpenOnModelError() async {
        let gate = NLIFaithfulnessGate { _, _ in throw CancellationError() }
        let r = await gate.validate(original: "x y z disk error", compressed: "completely different claim here")
        XCTAssertTrue(r.accepted, "model error must fail open to the deterministic stack")
    }

    // I8.4: a fabricated entity in the output (absent from original) is flagged.
    func test_nerBoosterFlagsHallucinatedEntity() async {
        let booster = NERHallucinationBooster { text in
            // stub: pretend the NER finds these entities in whatever text it's given
            text.contains("Berlin") ? ["Berlin"] : (text.contains("Paris") ? ["Paris"] : [])
        }
        // "Paris" appears in output but not original → hallucination.
        let bad = await booster.hallucinatedEntity(original: "He lives in Berlin now.", compressed: "He lives in Paris now.")
        XCTAssertEqual(bad, "Paris")
        // entity present in original → no hallucination.
        let good = await booster.hallucinatedEntity(original: "He moved to Berlin in May.", compressed: "He moved to Berlin.")
        XCTAssertNil(good)
    }
}
