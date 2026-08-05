import XCTest
@testable import CoreModel

final class ProviderControlTokenSanitizerTests: XCTestCase {
    func test_stripRemovesGrokEosToken() {
        XCTAssertEqual(
            ProviderControlTokenSanitizer.strip("Repos8<|eos|>"),
            "Repos8"
        )
    }

    func test_stripRemovesMultipleControlTokensAndTrims() {
        XCTAssertEqual(
            ProviderControlTokenSanitizer.strip("  hello <|eos|> world <|end|>  "),
            "hello  world"
        )
    }

    func test_stripLeavesOrdinaryProseUntouched() {
        let prose = "Use path a < b and pipe | or |> in docs."
        XCTAssertEqual(ProviderControlTokenSanitizer.strip(prose), prose)
        XCTAssertFalse(ProviderControlTokenSanitizer.containsControlToken(prose))
    }

    func test_stripStreamingChunkDropsTokenOnlyDelta() {
        XCTAssertEqual(ProviderControlTokenSanitizer.stripStreamingChunk("<|eos|>"), "")
        XCTAssertEqual(ProviderControlTokenSanitizer.stripStreamingChunk("Repos"), "Repos")
        XCTAssertEqual(ProviderControlTokenSanitizer.stripStreamingChunk("8"), "8")
    }

    func test_stripPreservingWhitespaceKeepsInterChunkSpaces() {
        XCTAssertEqual(
            ProviderControlTokenSanitizer.stripPreservingWhitespace(" world<|eos|>"),
            " world"
        )
        XCTAssertEqual(
            ProviderControlTokenSanitizer.stripStreamingChunk(" world<|eos|>"),
            " world"
        )
    }

    func test_containsControlTokenDetectsKnownForms() {
        XCTAssertTrue(ProviderControlTokenSanitizer.containsControlToken("x<|eos|>"))
        XCTAssertTrue(ProviderControlTokenSanitizer.containsControlToken("<|im_end|>"))
        XCTAssertFalse(ProviderControlTokenSanitizer.containsControlToken("normal answer"))
    }
}
