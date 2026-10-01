import XCTest
@testable import Surfaces
import AgentRuntime

final class DistillAccountsPanelTests: XCTestCase {
    func test_presentationCarriesAccountIdentityBusyURLAndError() {
        let statuses = DistillAccountProvider.allCases.map {
            DistillAccountStatus(provider: $0, connected: $0 == .grok, email: $0 == .grok ? "user@example.com" : nil)
        }
        let url = URL(string: "https://example.com/login")!
        let presentation = DistillAccountsPanelPresentation(
            statuses: statuses,
            busyProvider: .claude,
            signInURL: url,
            lastError: "Could not sign in"
        )
        XCTAssertEqual(presentation.statuses.first { $0.provider == .grok }?.email, "user@example.com")
        XCTAssertEqual(presentation.busyProvider, .claude)
        XCTAssertEqual(presentation.signInURL, url)
        XCTAssertEqual(presentation.lastError, "Could not sign in")
    }
}
