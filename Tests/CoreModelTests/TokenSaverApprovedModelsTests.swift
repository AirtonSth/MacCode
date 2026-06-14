import XCTest
@testable import CoreModel

final class TokenSaverApprovedModelsTests: XCTestCase {
    func test_selectsModelByPhysicalMemory() {
        let gb: UInt64 = 1_024 * 1_024 * 1_024

        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 8 * gb), TokenSaverApprovedModels.distill17B)
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 16 * gb), TokenSaverApprovedModels.distillE4B)
        XCTAssertEqual(TokenSaverApprovedModels.selected(totalMemoryBytes: 32 * gb), TokenSaverApprovedModels.distillE4B)
    }

    func test_e4bApprovedModelUsesExplicitMLXRepoFromPlan() {
        XCTAssertEqual(TokenSaverApprovedModels.distillE4B.id, "samuelfaj/distill-E4B-it-4-bit-MLX")
        XCTAssertEqual(TokenSaverApprovedModels.distillE4B.url, "https://huggingface.co/samuelfaj/distill-E4B-it-4-bit-MLX")
        XCTAssertEqual(TokenSaverApprovedModels.distillE4B.runtime, "mlx")
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
