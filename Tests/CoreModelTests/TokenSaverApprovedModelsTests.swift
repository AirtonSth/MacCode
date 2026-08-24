import XCTest
@testable import CoreModel

final class TokenSaverApprovedModelsTests: XCTestCase {
    func test_selectsHighestFloorModelTheMachineCanHold() {
        let gb: UInt64 = 1_024 * 1_024 * 1_024
        // RAM default: ≤16 GiB → 1.7B, >16 GiB → E4B.
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 8 * gb), TokenSaverApprovedModels.distill17B)
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 15 * gb), TokenSaverApprovedModels.distill17B)
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 16 * gb), TokenSaverApprovedModels.distill17B)
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 16 * gb + 1), TokenSaverApprovedModels.distillE4B)
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 128 * gb), TokenSaverApprovedModels.distillE4B)
    }

    func test_e4bIsApprovedAndSelectableNowThatTheRuntimeLoadsIt() {
        // The patched RCGemma4ModelOverride loads this checkpoint, so E4B is now in `all`,
        // validates as approved, and is the selected model on a machine that can hold it. An
        // installed E4B must therefore NOT be forced to migrate away.
        XCTAssertTrue(TokenSaverApprovedModels.all.contains(TokenSaverApprovedModels.distillE4B),
                      "E4B must be in `all` so it can be selected and validated as approved")
        XCTAssertEqual(TokenSaverApprovedModels.approved(
            id: TokenSaverApprovedModels.distillE4B.id,
            url: TokenSaverApprovedModels.distillE4B.url,
            runtime: TokenSaverApprovedModels.distillE4B.runtime
        ), TokenSaverApprovedModels.distillE4B,
        "an installed E4B must validate as approved → no forced migration")
    }

    func test_approvedLookupRequiresExactTriple() {
        XCTAssertEqual(
            TokenSaverApprovedModels.approved(
                id: TokenSaverApprovedModels.distill17B.id,
                url: TokenSaverApprovedModels.distill17B.url,
                runtime: TokenSaverApprovedModels.distill17B.runtime
            ),
            TokenSaverApprovedModels.distill17B
        )
        XCTAssertNil(TokenSaverApprovedModels.approved(
            id: TokenSaverApprovedModels.distill17B.id,
            url: "https://example.invalid/model",
            runtime: TokenSaverApprovedModels.distill17B.runtime
        ))
    }

    func test_resolveLocalHonorsExplicitSource() {
        let gb: UInt64 = 1_024 * 1_024 * 1_024
        XCTAssertEqual(
            TokenSaverApprovedModels.resolveLocal(source: .distill17b, totalMemoryBytes: 32 * gb),
            TokenSaverApprovedModels.distill17B
        )
        XCTAssertEqual(
            TokenSaverApprovedModels.resolveLocal(source: .distillE4B, totalMemoryBytes: 8 * gb),
            TokenSaverApprovedModels.distillE4B
        )
    }

    func test_generateTargetParsesOpenAICompatURL() {
        let target = TokenSaverGenerateTarget.resolve(
            source: .openaiCompat,
            apiBaseURL: "http://127.0.0.1:8000/v1",
            apiModel: "samuelfaj--distill-1.7B-4bit-MLX",
            apiToken: ""
        )
        guard case let .openaiCompatible(url, model, _) = target else {
            return XCTFail("expected openai compatible target")
        }
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(model, "samuelfaj--distill-1.7B-4bit-MLX")
        XCTAssertNil(TokenSaverGenerateTarget.parseAPIBaseURL("not a url"))
    }

    // WHY: a blank model is incomplete API configuration. The shared owner must
    // block it before any controller or helper can publish a mixed/false-ready target.
    func test_generateTargetRejectsEmptyOpenAICompatModelAtOwner() {
        let target = TokenSaverGenerateTarget.resolve(
            source: .openaiCompat,
            apiBaseURL: "http://127.0.0.1:8000/v1",
            apiModel: "  \n ",
            apiToken: ""
        )
        guard case let .invalidOpenAICompatible(reason) = target else {
            return XCTFail("blank API model must remain invalid API configuration")
        }
        XCTAssertEqual(reason, "Enter the API model id used by your OpenAI-compatible server")
    }

    // WHY: an explicitly selected API with an invalid URL is invalid API
    // configuration, not permission to silently load a local model.
    func test_generateTargetInvalidOpenAICompatURLNeverFallsBackToLocal() {
        let target = TokenSaverGenerateTarget.resolve(
            source: .openaiCompat,
            apiBaseURL: "not a url",
            apiModel: "fixture-api-model",
            apiToken: ""
        )

        guard case let .invalidOpenAICompatible(reason) = target else {
            return XCTFail("invalid API configuration must remain invalid instead of resolving local")
        }
        XCTAssertEqual(reason, "Enter a valid OpenAI-compatible API URL")
        XCTAssertFalse(target.usesExternalGenerate)
        XCTAssertEqual(target.configurationError, reason)
    }

    func test_generateTargetRejectsRemotePlaintextHTTPButAllowsLoopbackHTTPAndRemoteHTTPS() {
        XCTAssertNil(TokenSaverGenerateTarget.parseAPIBaseURL("http://api.example.com/v1"))
        XCTAssertNotNil(TokenSaverGenerateTarget.parseAPIBaseURL("http://127.0.0.1:8000/v1"))
        XCTAssertNotNil(TokenSaverGenerateTarget.parseAPIBaseURL("http://localhost:8000/v1"))
        XCTAssertNotNil(TokenSaverGenerateTarget.parseAPIBaseURL("http://[::1]:8000/v1"))
        XCTAssertNotNil(TokenSaverGenerateTarget.parseAPIBaseURL("https://api.example.com/v1"))
    }

    func test_generateTargetRejectsEmbeddedURLCredentialsButPreservesSupportedURLComponents() {
        // WHY: the base URL is passed to the helper argv, so URL userinfo would
        // expose a second credential channel outside the stdin-only token seam.
        XCTAssertNil(TokenSaverGenerateTarget.parseAPIBaseURL("https://user:password@api.example.com/v1"))
        XCTAssertNil(TokenSaverGenerateTarget.parseAPIBaseURL("https://user@api.example.com/v1"))

        let parsed = TokenSaverGenerateTarget.parseAPIBaseURL(
            "https://api.example.com/v1?deployment=blue#compat"
        )
        XCTAssertEqual(parsed?.absoluteString, "https://api.example.com/v1?deployment=blue#compat")

        let target = TokenSaverGenerateTarget.resolve(
            source: .openaiCompat,
            apiBaseURL: "https://user:password@api.example.com/v1",
            apiModel: "fixture-api-model",
            apiToken: ""
        )
        guard case .invalidOpenAICompatible = target else {
            return XCTFail("embedded URL credentials must remain invalid API configuration")
        }
    }
}
