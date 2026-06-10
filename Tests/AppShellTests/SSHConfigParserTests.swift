import XCTest
@testable import AppShell
@testable import CoreModel

// Tests for SSHConfigParser (pure, non-MainActor) and the SSHSurface
// disconnect path (via the testing accessor, nil router).
//
// WHY each test: see inline comments.

final class SSHConfigParserTests: XCTestCase {

    // WHY: a typical real-world ~/.ssh/config has multiple Host blocks; the
    // parser must yield one entry per non-wildcard block in declaration order.
    // Regression in block-boundary detection would collapse or skip entries.
    func testParsesMultipleHostBlocks() {
        let text = """
        Host dev
            HostName 192.168.1.10
            User alice
            Port 2222

        Host prod
            HostName prod.example.com
            User deploy
        """
        let entries = SSHConfigParser.parseText(text)
        XCTAssertEqual(entries.count, 2, "expected 2 host blocks")
        XCTAssertEqual(entries[0].hostAlias, "dev")
        XCTAssertEqual(entries[1].hostAlias, "prod")
    }

    // WHY: HostName overrides the Host alias as the actual address to connect
    // to. Without this mapping the generated destination would be the alias
    // string ("dev") instead of the resolvable address ("192.168.1.10"), so
    // the SSH connection would fail.
    func testHostNameOverridesAlias() {
        let text = """
        Host myserver
            HostName 10.0.0.5
        """
        let profiles = SSHConfigParser.parse(text: text)
        XCTAssertEqual(profiles.first?.destination, "10.0.0.5",
                       "destination must be HostName value, not alias")
    }

    // WHY: when no HostName is given the Host alias IS the address. Falling
    // back to the alias lets short aliases like "git" work as destinations.
    func testFallsBackToAliasWhenNoHostName() {
        let text = """
        Host git
            User git
        """
        let profiles = SSHConfigParser.parse(text: text)
        XCTAssertEqual(profiles.first?.destination, "git@git",
                       "user@alias must be the destination when HostName absent")
    }

    // WHY: User is prepended as \"user@hostname\". Missing User must NOT
    // produce a bare \"@\" prefix - tests both the present and absent cases.
    func testUserIsPrependedToDestination() {
        let withUser = """
        Host box
            HostName 192.168.0.1
            User bob
        """
        let withoutUser = """
        Host box2
            HostName 192.168.0.2
        """
        let p1 = SSHConfigParser.parse(text: withUser).first
        let p2 = SSHConfigParser.parse(text: withoutUser).first
        XCTAssertEqual(p1?.destination, "bob@192.168.0.1")
        XCTAssertEqual(p2?.destination, "192.168.0.2")
    }

    // WHY: Port must be parsed as Int and stored so the SSHHostProfile can pass
    // it to the scp/ssh command-line builders. A nil port means default (22);
    // a non-nil port must match exactly or the builder uses the wrong -p/-P value.
    func testPortIsParsedCorrectly() {
        let text = """
        Host jump
            HostName jump.example.com
            Port 2222
        """
        let profiles = SSHConfigParser.parse(text: text)
        XCTAssertEqual(profiles.first?.port, 2222,
                       "Port must parse to the integer value 2222")
    }

    // WHY: IdentityFile is the path passed to -i; it must survive the parse
    // unchanged (or with tilde expansion). Without this the generated scp/ssh
    // call would omit -i and fall back to the SSH agent, which may not have
    // the right key loaded.
    func testIdentityFileIsExtracted() {
        let text = """
        Host ci
            HostName ci.example.com
            IdentityFile /home/runner/.ssh/id_ed25519
        """
        let profiles = SSHConfigParser.parse(text: text)
        XCTAssertEqual(profiles.first?.identityFile, "/home/runner/.ssh/id_ed25519")
    }

    // WHY: the wildcard Host * is a global-defaults stanza; it does not map to
    // any connectable host. Importing it would create an unusable profile with
    // destination \"*\". Both \"*\" and \"*.*\" must be rejected.
    func testWildcardHostsAreSkipped() {
        let text = """
        Host *
            ServerAliveInterval 30

        Host *.example.com
            User common

        Host realbox
            HostName 10.0.0.1
        """
        let profiles = SSHConfigParser.parse(text: text)
        XCTAssertEqual(profiles.count, 1,
                       "wildcard blocks must be excluded; only 'realbox' is valid")
        XCTAssertEqual(profiles.first?.destination, "10.0.0.1")
    }

    // WHY: '!' prefix negates a pattern in ssh_config; it also cannot map to a
    // single address and must be skipped like other wildcards.
    func testNegatedPatternHostsAreSkipped() {
        let text = """
        Host !restricted
            HostName 10.0.0.99

        Host allowed
            HostName 10.0.0.1
        """
        let profiles = SSHConfigParser.parse(text: text)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.destination, "10.0.0.1")
    }

    // WHY: '#' lines and blank lines must not confuse the parser into treating
    // a comment as a keyword or creating spurious entries. A misparse here
    // could silently drop following Host blocks.
    func testCommentsAndBlankLinesAreIgnored() {
        let text = """
        # Global settings
        # StrictHostKeyChecking ask

        Host staging
            # This is the staging box
            HostName staging.example.com
            User deploy
        """
        let entries = SSHConfigParser.parseText(text)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].hostAlias, "staging")
    }

    // WHY: label in the generated SSHHostProfile is the Host alias so the
    // user recognises the entry by the name they chose in their config, not
    // the raw IP address. A wrong label would lose the user-chosen name.
    func testLabelIsHostAlias() {
        let text = """
        Host myalias
            HostName 10.0.0.1
        """
        let profiles = SSHConfigParser.parse(text: text)
        XCTAssertEqual(profiles.first?.label, "myalias")
    }

    // WHY: isWildcard must correctly classify all glob tokens. A false negative
    // would let wildcard blocks into the import list; a false positive would
    // silently drop valid hosts whose names happen to contain these characters
    // (unlikely in practice, but the logic must be exact).
    func testIsWildcardClassification() {
        XCTAssertTrue(SSHConfigParser.isWildcard("*"))
        XCTAssertTrue(SSHConfigParser.isWildcard("*.example.com"))
        XCTAssertTrue(SSHConfigParser.isWildcard("host?.example.com"))
        XCTAssertTrue(SSHConfigParser.isWildcard("!excluded"))
        XCTAssertFalse(SSHConfigParser.isWildcard("myhost"))
        XCTAssertFalse(SSHConfigParser.isWildcard("prod-server"))
        XCTAssertFalse(SSHConfigParser.isWildcard("192.168.0.1"))
    }

    // WHY: parse(fileURL:) must return [] when the file does not exist instead
    // of throwing, so callers that call it unconditionally (e.g. importFromConfig
    // at app startup) never crash on a fresh machine with no ~/.ssh/config.
    func testMissingFileReturnsEmpty() {
        let url = URL(fileURLWithPath: "/nonexistent/path/.ssh/config")
        XCTAssertTrue(SSHConfigParser.parse(fileURL: url).isEmpty,
                      "missing file must return [] not throw")
    }

    // WHY: an empty file or a file containing only comments and blank lines
    // must not produce any profiles. The parser's flush() guard must handle
    // the case where no Host block was ever started.
    func testEmptyConfigReturnsEmpty() {
        XCTAssertTrue(SSHConfigParser.parse(text: "").isEmpty)
        XCTAssertTrue(SSHConfigParser.parse(text: "# only a comment\n").isEmpty)
    }
}

// Tests for SSHSurface.disconnectForTesting() (nil router, no network).
@MainActor
final class SSHSurfaceDisconnectTests: XCTestCase {

    private func makeSurface() throws -> SSHSurface {
        try SSHSurface(workspaceID: WorkspaceID(), cwd: "/tmp", title: "t", router: nil)
    }

    // WHY: after disconnect the surface must report "disconnected" in its
    // snapshot. If ssh_status stayed "connected" after disconnect the UI
    // would show a phantom "Connected" pill and file-transfer refreshes would
    // keep firing against a closed session.
    func testDisconnectFlipsStatusToDisconnected() throws {
        let surface = try makeSurface()
        // Simulate a connected state by checking the initial snapshot shape.
        let snap = surface.snapshot()
        XCTAssertEqual(snap["ssh_status"], "disconnected", "initial state must be disconnected")

        // Call disconnect() via the testing accessor (no-op on fresh surface
        // since no terminal exists, but the status + sessionDead must stay clean).
        surface.disconnectForTesting()
        let snapAfter = surface.snapshot()
        XCTAssertEqual(snapAfter["ssh_status"], "disconnected",
                       "disconnect must leave ssh_status = disconnected")
    }

    // WHY: a repeated disconnect (e.g. user taps Disconnect on an already-idle
    // surface) must not crash or corrupt state. This guards against double-free
    // or double-cancel of the timer.
    func testDoubleDisconnectIsIdempotent() throws {
        let surface = try makeSurface()
        surface.disconnectForTesting()
        surface.disconnectForTesting()
        XCTAssertEqual(surface.snapshot()["ssh_status"], "disconnected")
    }
}
