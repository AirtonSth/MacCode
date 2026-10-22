import XCTest
@testable import AppShell

final class ManagedToolInstallerTests: XCTestCase {
    func test_releaseParsing_keepsOnlyHttpsAssets_andRejectsBadTags() throws {
        // WHY: the tag becomes a path component and the assets are downloaded;
        // a tag with "/" or a non-https asset must never be used.
        let json = #"{"tag_name":"v1.5.3","assets":[{"name":"SHA256SUMS","browser_download_url":"https://github.com/x/SHA256SUMS"},{"name":"evil","browser_download_url":"http://x/evil"}]}"#
        let release = try ManagedToolInstaller.parseRelease(Data(json.utf8))
        XCTAssertEqual(release.tag, "v1.5.3")
        XCTAssertEqual(Array(release.assets.keys), ["SHA256SUMS"])
        XCTAssertThrowsError(try ManagedToolInstaller.parseRelease(Data(#"{"tag_name":"../x","assets":[]}"#.utf8)))
    }

    func test_expectedDigest_matchesOnlyTheExactAsset() {
        // WHY: an asset installs only when SHA256SUMS lists that exact file.
        let sums = "aa  mac-use-mcp-v1.5.3-macos-arm64.tar.gz\nbb  mac-use-skill-v1.5.3.tar.gz\n"
        XCTAssertEqual(ManagedToolInstaller.expectedDigest(sums: sums, asset: "mac-use-skill-v1.5.3.tar.gz"), "bb")
        XCTAssertNil(ManagedToolInstaller.expectedDigest(sums: sums, asset: "mac-use-mcp"))
    }
}
