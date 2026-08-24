import XCTest
@testable import DistillCore

/// Eligible Distill miss/no-shrink must reach the local LLM through EncoderFirstRuntime.
/// Crushers/BERT still win first; this fixture is prose so those lanes miss.
final class TokenSaverMaxLocalLLMStagingTests: XCTestCase {
    func test_eligibleMissInvokesLocalLLM() async throws {
        let fixture = eligibleProseFixture
        let llm = RecordingLocalLLMRuntime()
        let runtime = EncoderFirstRuntime(wrapping: llm, encoderLane: nil)

        for mode in [DistillMode.commandOutput, .longText] {
            await llm.reset()
            let request = DistillRequest(mode: mode, input: fixture)
            XCTAssertNotEqual(tokenSaverLane(for: request.mode), .followUpPrompt)
            XCTAssertTrue(
                TokenSaverRoutingPolicy.stages(for: tokenSaverLane(for: request.mode)).contains(.llmMLX)
            )

            let staged = try await runtime.distillStaged(request)
            let generateCalls = await llm.generateCallCount
            let stagedCalls = await llm.distillStagedCallCount

            XCTAssertGreaterThan(
                stagedCalls,
                0,
                "WHY: EncoderFirstRuntime must invoke wrapped distillStaged on eligible miss (\(mode))"
            )
            XCTAssertGreaterThan(
                generateCalls,
                0,
                "WHY: the local LLM generate path must run after deterministic/BERT miss (\(mode))"
            )
            XCTAssertTrue(
                staged.output.utf8.count < fixture.utf8.count || staged.output == fixture,
                "WHY: LLM-on-miss is smaller or fail-open original, never inflated"
            )
            if staged.output.utf8.count < fixture.utf8.count {
                XCTAssertTrue(staged.output.contains(eligibleFileLinePin), "lossy shrink must keep pinned file:line")
                XCTAssertTrue(containsSalientNegation(staged.output), "lossy shrink must keep not/never/must")
                XCTAssertTrue(staged.output.contains("[[rc:"), "lossy shrink must carry a recoverable handle")
            }
        }
    }

    func test_eligibleCorpusLLMSmallerThanSkipLLMBaseline() async throws {
        let fixture = eligibleProseFixture
        let baselineBytes = fixture.utf8.count
        let llm = RecordingLocalLLMRuntime()
        let runtime = EncoderFirstRuntime(wrapping: llm, encoderLane: nil)
        let request = DistillRequest(mode: .commandOutput, input: fixture)
        let staged = try await runtime.distillStaged(request)
        let generateCalls = await llm.generateCallCount

        XCTAssertGreaterThan(generateCalls, 0)
        XCTAssertLessThan(
            staged.output.utf8.count,
            baselineBytes,
            "WHY: delivered EncoderFirst envelope must be strictly smaller than verbatim skip-LLM original bytes; TokenEstimator is not billing"
        )
        XCTAssertTrue(staged.output.contains(eligibleFileLinePin))
        XCTAssertTrue(containsSalientNegation(staged.output))
        XCTAssertTrue(staged.output.contains(eligibleRecoveryHandle))
    }
}

/// MLX stand-in only. Tests must wrap this in EncoderFirstRuntime (encoderLane nil = BERT miss).
private actor RecordingLocalLLMRuntime: DistillRuntime {
    private(set) var distillStagedCallCount = 0
    private(set) var generateCallCount = 0

    func reset() {
        distillStagedCallCount = 0
        generateCallCount = 0
    }

    func distill(_ request: DistillRequest) async throws -> String {
        try await distillStaged(request).output
    }

    func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
        distillStagedCallCount += 1
        generateCallCount += 1
        return DistillStageResult(output: lossyCompressed(from: request.input), stage: .llmMLX)
    }

    func rawGenerate(system: String, user: String, maxTokens: Int) async -> String? {
        generateCallCount += 1
        return lossyCompressed(from: user)
    }

    private func lossyCompressed(from input: String) -> String {
        let output = "Session retry must never skip \(eligibleFileLinePin) because the cache is not valid. \(eligibleRecoveryHandle)"
        return output.utf8.count < input.utf8.count ? output : input
    }
}

private let eligibleFileLinePin = "Sources/Auth/Session.swift:88"
private let eligibleRecoveryHandle = "[[rc:tsllm-standin]]"

/// Unique prose so JSON/log crushers miss. BERT misses because encoderLane is nil.
private let eligibleProseFixture: String = [
    "The operator review of \(eligibleFileLinePin) concluded the retry must never skip the refresh because the cache is not valid after expiry.",
    "A nearby lake walk after lunch stayed in the planner as a reminder to rest before the next session.",
    "The committee asked for a short written account of the session token lifetime and rotation window.",
    "Gardeners planted extra tulips along the south fence before the rain arrived later that afternoon.",
    "The librarian catalog still listed the original hardcover beside a paperback reprint of the same title.",
    "Kitchen staff plated the remaining tarts onto smaller dishes so nothing sat out overnight.",
    "A handwritten note on the desk said the calendar invite should move to Thursday after the briefing.",
    "The ferry schedule listed an extra crossing at dusk because the evening concert ran late.",
    "Paint samples on the wall included a muted sage that looked calmer under the north window light.",
    "The bicycle mechanic replaced the rear cable housing and then checked the shifter throw by hand.",
    "Someone left a stack of postcards from the coastal town next to the unread mail on the sideboard.",
    "The choir rehearsal paused while the accompanist retuned the lower register of the upright piano.",
    "A crate of pears arrived slightly early so they stayed in the cool pantry until the weekend market.",
    "The map on the corkboard marked three walking loops that stay on the ridge instead of the valley road.",
    "Children counted the stepping stones across the shallow creek and then raced back to the picnic blanket.",
    "The workshop outline kept a quiet section for questions about the retry contract and the expiry clock.",
    "Clouds thinned enough that the late sun reached the brick path beside the greenhouse benches.",
    "A spare umbrella leaned by the door in case the forecast flipped during the walk home.",
    "The reading list mixed travel essays with a short novel set in a harbor town during winter.",
    "Neighbors swapped extra basil cuttings over the fence and promised to share tomatoes in August.",
    "The clock on the mantel lost a minute each week so someone planned to take it in for service.",
    "A folded timetable for the Saturday market listed honey, bread, and the first early apples.",
    "The porch swing creaked once and then settled while the dog watched squirrels in the maple.",
    "Tea steeped a little longer than usual because the conversation about the retry plan kept going.",
    "The attic still held a box of sheet music from the years when the house had a standing quartet.",
    "Street lamps came on one by one as the last of the daylight left the upper windows.",
    "A pencil sketch of the garden gate sat under a magnet on the fridge next to a grocery list.",
    "The last paragraph of the memo asked readers to keep the original wording of the retry clause.",
    "Windows stayed open to the courtyard so the rooms cooled before the evening gathering started.",
    "The binder on the shelf still had the field notes from the first week of the orchard survey."
].joined(separator: "\n")

private func containsSalientNegation(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("not") || lower.contains("never") || lower.contains("must")
}
