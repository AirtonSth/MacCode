import XCTest
@testable import AgentRuntime

/// Process-spawning provider tests run without AppDelegate, so they explicitly
/// install the same durable ownership prerequisite that production installs
/// before AppContext can begin launch reconciliation.
class ProviderProcessTestCase: XCTestCase {
    private static let ownershipLedger = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-process-tests-\(UUID().uuidString).json")

    override func setUp() {
        super.setUp()
        ProviderProcessOwnership.shared.configure(fileURL: Self.ownershipLedger)
    }
}
