import XCTest
@testable import CoreModel

final class TokenSaverApprovedModelsTests: XCTestCase {
    func test_selectsHighestFloorModelTheMachineCanHold() {
        let gb: UInt64 = 1_024 * 1_024 * 1_024
        // E4B (gemma4) needs 16 GB; below that the selector must fall back to the qwen3 1.7B
        // model so Token Saver never picks a model the machine cannot hold. At/above 16 GB it
        // must prefer E4B — the higher-quality distill model — over the fallback.
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 8 * gb), TokenSaverApprovedModels.distill17B)
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 15 * gb), TokenSaverApprovedModels.distill17B)
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 16 * gb), TokenSaverApprovedModels.distillE4B)
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
}
