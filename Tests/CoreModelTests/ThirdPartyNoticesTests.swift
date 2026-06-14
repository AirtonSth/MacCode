import XCTest
@testable import CoreModel

final class ThirdPartyNoticesTests: XCTestCase {
    func test_tokenSaverApprovedModelsAreListedInThirdPartyNotices() throws {
        let noticesURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("THIRD_PARTY_NOTICES.md")
        let notices = try String(contentsOf: noticesURL)

        for model in TokenSaverApprovedModels.all {
            XCTAssertTrue(notices.contains(model.id), "\(model.id) must be listed in THIRD_PARTY_NOTICES.md")
            XCTAssertTrue(notices.contains(model.url), "\(model.id) source URL must be listed")
        }
        XCTAssertTrue(notices.contains("Apache-2.0"), "license metadata must be recorded")
    }
}
