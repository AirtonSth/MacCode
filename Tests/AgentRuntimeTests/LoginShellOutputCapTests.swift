import XCTest
@testable import AgentRuntime

/// Login-shell env capture stdout ceiling (memory R6 residual).
///
/// WHY: `LoginShellEnvironment` captures `env -0` plus shell startup noise into
/// a single Data buffer. Prior 4 MiB ceiling could pin multi-MB strings on every
/// app launch path; 1 MiB still covers large profiles. Captures that exceed the
/// prefix cap are drained but rejected before parsing.
final class LoginShellOutputCapTests: XCTestCase {
    func test_outputCap_is1MiB() {
        XCTAssertEqual(LoginShellEnvironment.outputCap, 1 * 1024 * 1024)
    }

    func test_retentionEstimate_4MiBTo1MiB() {
        let prior = 4 * 1024 * 1024
        let limit = LoginShellEnvironment.outputCap
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertEqual(reduction, 0.75, accuracy: 0.001)
        XCTAssertEqual(limit, 1 * 1024 * 1024)
    }
}
