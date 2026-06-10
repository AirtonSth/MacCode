import XCTest
@testable import SocketServer

/// P2 - Per-route auth scopes (capabilities).
///
/// DeviceTrust.capabilities is a persisted string ("*" = all) that verify()
/// surfaces but the dispatch gate never enforces: it only checks the token is
/// valid, so a device cannot be granted read-only or file-only access. These
/// tests pin the PURE authorization seam - `(method, grantedCapabilities) ->
/// allowed` - that maps each RPC method to a required capability and checks the
/// caller's granted set before the request is dispatched.
///
/// WHY each assertion encodes intent (Rule 8):
///   - "*" must allow EVERYTHING (back-compat: existing paired devices stored
///     "*" and must keep full access; a regression here silently locks out
///     every already-paired phone).
///   - a read-only scope must allow reads but DENY writes and file ops (the
///     whole point of the feature: granting a device read-only access must
///     actually stop it from mutating state or touching the filesystem).
///   - an unknown method must be denied by default for a scoped device
///     (fail-closed: a method the classifier doesn't recognize must not slip
///     through as if it were a read).
final class RPCCapabilityAuthorizationTests: XCTestCase {

    private func authorized(_ method: String, _ caps: String) -> Bool {
        JSONRPCDispatcher.isAuthorized(method: method, grantedCapabilities: caps)
    }

    // MARK: "*" allows everything (back-compat)

    func test_star_allowsReadsWritesFileOpsAndUnknown() {
        // WHY: every already-paired device stored "*"; if "*" stopped meaning
        // "all", every existing phone would lose access on upgrade.
        for method in ["workspace.list", "workspace.create", "git.commit",
                       "fs.workspace.read", "fs.workspace.delete",
                       "files.edit.save", "some.future.method"] {
            XCTAssertTrue(authorized(method, "*"),
                          "\"*\" must authorize \(method)")
        }
    }

    // MARK: read-only scope

    func test_readScope_allowsReads() {
        // WHY: a read-only grant must still let the device observe state,
        // otherwise the scope is useless.
        for method in ["workspace.list", "workspace.current", "events.recent",
                       "settings.get", "agent.thread.list", "git.status",
                       "agent.message.get", "system.ping"] {
            XCTAssertTrue(authorized(method, "read"),
                          "read scope must authorize read method \(method)")
        }
    }

    func test_readScope_deniesWrites() {
        // WHY: the entire purpose of a read-only device is that it CANNOT
        // mutate; if a write slipped through, the scope would be cosmetic.
        for method in ["workspace.create", "workspace.rename", "git.commit",
                       "git.push", "surface.send_text", "settings.set",
                       "agent.message.send"] {
            XCTAssertFalse(authorized(method, "read"),
                           "read scope must DENY write method \(method)")
        }
    }

    func test_readScope_deniesFileOps() {
        // WHY: filesystem reads/writes are a distinct, more sensitive surface;
        // a read-only device must not read or mutate the filesystem unless the
        // operator also grants the "file" capability.
        for method in ["fs.workspace.read", "fs.workspace.list",
                       "fs.workspace.delete", "fs.workspace.create_file",
                       "files.edit.open", "files.edit.save"] {
            XCTAssertFalse(authorized(method, "read"),
                           "read scope must DENY file op \(method)")
        }
    }

    // MARK: file scope

    func test_fileScope_allowsFileOpsButNotWrites() {
        // WHY: a file-only grant (e.g. a file-sync helper) must reach the
        // filesystem surface but must NOT be able to drive git/agent/terminal
        // mutations it was never granted.
        XCTAssertTrue(authorized("fs.workspace.read", "file"),
                      "file scope must authorize fs.workspace.read")
        XCTAssertTrue(authorized("files.edit.save", "file"),
                      "file scope must authorize files.edit.save")
        XCTAssertFalse(authorized("git.commit", "file"),
                       "file scope must DENY a non-file write (git.commit)")
    }

    // MARK: multiple granted capabilities

    func test_multipleScopes_unionOfGrants() {
        // WHY: granting "read,file" must yield reads AND file ops but still
        // deny writes - the grants compose as a union, not collapse to one.
        let caps = "read,file"
        XCTAssertTrue(authorized("workspace.list", caps), "read+file must allow reads")
        XCTAssertTrue(authorized("fs.workspace.read", caps), "read+file must allow file ops")
        XCTAssertFalse(authorized("git.commit", caps), "read+file must still deny writes")
    }

    // MARK: unknown method fail-closed

    func test_unknownMethod_deniedForScopedDevice() {
        // WHY: a method the classifier doesn't recognize must fail closed for a
        // scoped device; otherwise an unmapped/new method would default to
        // "allowed" and bypass the scope entirely.
        XCTAssertFalse(authorized("totally.unknown.method", "read"),
                       "unknown method must be denied for a read-scoped device")
        XCTAssertFalse(authorized("totally.unknown.method", "write"),
                       "unknown method must be denied for a write-scoped device")
        XCTAssertFalse(authorized("totally.unknown.method", "read,write,file"),
                       "unknown method must be denied even with all named scopes")
    }

    // MARK: write scope

    func test_writeScope_allowsWritesButNotFileOps() {
        // WHY: "write" governs state mutation (workspaces/git/agent/surfaces);
        // it must not implicitly grant the distinct filesystem surface.
        XCTAssertTrue(authorized("git.commit", "write"),
                      "write scope must authorize git.commit")
        XCTAssertTrue(authorized("workspace.create", "write"),
                      "write scope must authorize workspace.create")
        XCTAssertFalse(authorized("fs.workspace.delete", "write"),
                       "write scope must DENY file op fs.workspace.delete")
    }
}
