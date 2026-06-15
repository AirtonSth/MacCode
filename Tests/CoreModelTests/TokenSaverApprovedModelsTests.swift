import XCTest
@testable import CoreModel

final class TokenSaverApprovedModelsTests: XCTestCase {
    func test_selectsOnlyRunnableModelRegardlessOfMemory() {
        let gb: UInt64 = 1_024 * 1_024 * 1_024
        // The E4B (gemma4) model cannot be loaded by the vendored mlx-swift-lm, so it is
        // excluded from `all`. The selector must therefore return the one runnable model
        // (1.7B / qwen3) at EVERY memory tier — never a model that fails to load and
        // silently degrades Token Saver to the deterministic fallback.
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 8 * gb), TokenSaverApprovedModels.distill17B)
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 16 * gb), TokenSaverApprovedModels.distill17B)
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 128 * gb), TokenSaverApprovedModels.distill17B)
    }

    func test_e4bExcludedFromApprovedSetUntilRuntimeSupportsIt() {
        // The constant stays defined (for cleanup/future re-enable) but must NOT be in the
        // approved set, so it is never auto-selected and an installed copy reports
        // "not approved" → the app migrates to the runnable model.
        XCTAssertFalse(TokenSaverApprovedModels.all.contains(TokenSaverApprovedModels.distillE4B),
                       "E4B must stay out of `all` until mlx-swift-lm can load gemma4")
        XCTAssertNil(TokenSaverApprovedModels.approved(
            id: TokenSaverApprovedModels.distillE4B.id,
            url: TokenSaverApprovedModels.distillE4B.url,
            runtime: TokenSaverApprovedModels.distillE4B.runtime
        ), "an installed E4B must no longer validate as approved → forces migration to 1.7B")
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
}
