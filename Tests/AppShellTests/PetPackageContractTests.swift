import XCTest
@testable import AppShell

final class PetPackageContractTests: XCTestCase {
    func test_bundleValidatorTracksAtlasV3AndEveryPackagedPetResource() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/check-app-bundle.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("remote-code-black-cat-atlas-v3.json"),
            "the CI package gate must validate the manifest that PetAtlas.bundled() loads")
        XCTAssertTrue(script.contains("1536x7072"),
            "the CI package gate must reject an atlas with the pre-v3 dimensions")
        XCTAssertTrue(script.contains("PET_EXPECTED_RESOURCE_COUNT=40"),
            "the package gate must detect a missing state, micro-action row, atlas, or manifest")
        for state in PetAnimationState.allCases {
            XCTAssertTrue(script.contains(state.rawValue),
                "the package gate must require the \(state.rawValue) runtime row")
        }
        for action in ["blink", "tail", "ears"] {
            XCTAssertTrue(script.contains("idle-\(action)"),
                "the package gate must require the \(action) micro-action row")
        }
        XCTAssertFalse(script.contains("remote-code-black-cat-atlas-v1.json"),
            "a stale v1 check would fail every valid v3 package without testing current behavior")
        XCTAssertFalse(script.contains("1536x3328"),
            "the validator must not accept the obsolete 16-row atlas height")
    }
}
