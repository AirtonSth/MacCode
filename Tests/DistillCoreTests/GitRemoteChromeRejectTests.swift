import XCTest
@testable import DistillCore

/// Fire 8: leftover wrap-eligible harvest noise is GitLab `remote:` advertisement
/// around a load-bearing MR URL. Eliding empty `remote:` + visit headers keeps
/// URLs/ranges/errors but never clears the 10% lossy-router gate (max ~5%).
final class GitRemoteChromeRejectTests: XCTestCase {
    /// Best-case harvest compound (`git push && checkout && push`, 1986 chars,
    /// measured gain 5.1% after dropping 5 advertisement lines).
    private func harvestBestCasePush() -> String {
        var lines = [
            "Push production, create and push bots, switch to it",
            "remote:",
            "remote: To create a merge request for production, visit:",
            "remote:   https://gitlab.com/desenvolvimento-ninja/remodecode/remotecode/-/merge_requests/new?merge_request%5Bsource_branch%5D=production",
            "remote:",
            "To https://gitlab.com/desenvolvimento-ninja/remodecode/remotecode.git",
            "   b2b25a7b..b23ad094  HEAD -> production",
            "Switched to a new branch 'bots'",
            "remote:",
            "remote: To create a merge request for bots, visit:",
            "remote:   https://gitlab.com/desenvolvimento-ninja/remodecode/remotecode/-/merge_requests/new?merge_request%5Bsource_branch%5D=bots",
            "remote:",
            "To https://gitlab.com/desenvolvimento-ninja/remodecode/remotecode.git",
            " * [new branch]        bots -> bots",
            "branch 'bots' set up to track 'origin/bots'.",
        ]
        for i in 1...35 {
            lines.append("?? Sources/Module/ExtraFile\(i).swift")
        }
        return lines.joined(separator: "\n")
    }

    func test_remoteAdvertisementChromeMissesTenPercentAndMustKeepURLs() {
        for original in [harvestBestCasePush()] {
            let crushed = elideRemoteAdvertisementHeaders(original)
            XCTAssertTrue(crushed.contains("https://gitlab.com/"))
            XCTAssertTrue(crushed.contains(" -> "))
            XCTAssertFalse(crushed.contains("To create a merge request"))
            XCTAssertFalse(crushed.contains("View merge request"))
            let gain = 1.0 - Double(crushed.utf8.count) / Double(original.utf8.count)
            XCTAssertLessThan(
                gain,
                0.10,
                "harvest git remote: chrome max gain must stay below the lossy router gate"
            )
            XCTAssertNil(
                CommandOutputLossyRouter.routeIfBeneficial(input: original, handle: "h"),
                "do not ship a crusher that cannot clear 10% without dropping URLs or ?? paths"
            )
        }
    }

    /// Same elision a GitRemoteAdvertisement crusher would apply. Kept in the
    /// test so a later fire cannot claim this family was unmeasured.
    private func elideRemoteAdvertisementHeaders(_ input: String) -> String {
        input
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "remote:" || trimmed == "remote:" { return false }
                if trimmed.hasPrefix("remote: To create a merge request") { return false }
                if trimmed.hasPrefix("remote: View merge request") { return false }
                return true
            }
            .joined(separator: "\n")
    }
}
