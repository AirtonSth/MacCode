import XCTest
@testable import CoreModel

/// WHY: The run-as selector must never offer root/system accounts. A wrong
/// allowlist would let the privileged helper target a dangerous uid.
final class AgentRunAsUserEligibilityTests: XCTestCase {
    func test_rejectsRootAndSystemAccounts() {
        XCTAssertFalse(AgentRunAsUserEligibility.isEligible(
            shortName: "root", uid: 0, shell: "/bin/zsh", homePath: "/var/root", isHidden: false
        ))
        XCTAssertFalse(AgentRunAsUserEligibility.isEligible(
            shortName: "_www", uid: 70, shell: "/usr/bin/false", homePath: "/var/empty", isHidden: true
        ))
        XCTAssertFalse(AgentRunAsUserEligibility.isEligible(
            shortName: "daemon", uid: 1, shell: "/usr/bin/false", homePath: "/var/root", isHidden: false
        ))
    }

    func test_acceptsInteractiveUsersHome() {
        XCTAssertTrue(AgentRunAsUserEligibility.isEligible(
            shortName: "alice", uid: 501, shell: "/bin/zsh", homePath: "/Users/alice", isHidden: false
        ))
        XCTAssertTrue(AgentRunAsUserEligibility.isEligible(
            shortName: "work", uid: 502, shell: "/bin/bash", homePath: "/Users/work", isHidden: false
        ))
    }

    func test_rejectsNologinAndNonUsersHome() {
        XCTAssertFalse(AgentRunAsUserEligibility.isEligible(
            shortName: "alice", uid: 501, shell: "/usr/sbin/nologin", homePath: "/Users/alice", isHidden: false
        ))
        XCTAssertFalse(AgentRunAsUserEligibility.isEligible(
            shortName: "alice", uid: 501, shell: "/bin/zsh", homePath: "/var/alice", isHidden: false
        ))
    }
}
