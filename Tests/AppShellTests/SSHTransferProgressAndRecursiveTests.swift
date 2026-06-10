import XCTest
@testable import AppShell
@testable import CoreModel

// P1: SSH transfer progress parsing, recursive (folder) scp argv building, the
// large-tree confirm policy, and the cooperative per-row cancel flow.
//
// The progress parser, recursive-command builder, and large-tree policy are pure
// (non-MainActor) so they are tested directly. The cancel/progress queue logic
// lives on the @MainActor surface and is tested via its testing accessors with a
// nil router (no network).

final class SSHTransferProgressParserTests: XCTestCase {
    // WHY: scp emits one rewritten stderr line per file like
    // "bigfile.iso  23%  118MB  5.8MB/s  01:23 ETA". The per-row progress bar is
    // only meaningful if we extract the percent (and ideally the byte count)
    // from that exact shape. A regression that stopped reading the percent token
    // would fail here.
    func testParsesTypicalScpProgressLine() {
        let sample = SSHTransferProgressParser.parse("bigfile.iso    23%  118MB   5.8MB/s   01:23 ETA")
        XCTAssertEqual(sample?.percent, 23)
        XCTAssertEqual(sample?.bytes, Int64(118 * 1_048_576))
    }

    // WHY: 100% completion must be representable so the bar can reach full;
    // off-by-one bounds (e.g. rejecting 100) would leave transfers visually stuck.
    func testParsesHundredPercent() {
        XCTAssertEqual(SSHTransferProgressParser.parse("f.dat 100% 4096KB 9.0MB/s 00:00")?.percent, 100)
    }

    // WHY: scp rewrites the line via carriage returns; a buffered read can hand us
    // several samples joined by \r. We must surface the freshest (last) one, not
    // the stale leading one, or the bar would lag/jump backward.
    func testTakesFreshestSampleFromCarriageReturnBuffer() {
        let buffered = "f 10%  10MB 1MB/s 00:09\rf 60%  60MB 1MB/s 00:04"
        XCTAssertEqual(SSHTransferProgressParser.parse(buffered)?.percent, 60)
    }

    // WHY: banners, host-key notices, and error text must NOT be misread as
    // progress, or the row would show garbage percentages. nil = "leave the row
    // untouched".
    func testNonProgressLinesReturnNil() {
        XCTAssertNil(SSHTransferProgressParser.parse("Warning: Permanently added 'host' to known hosts."))
        XCTAssertNil(SSHTransferProgressParser.parse("Permission denied (publickey,password)."))
        XCTAssertNil(SSHTransferProgressParser.parse(""))
    }

    // WHY: a stray token ending in '%' that isn't a real 0..100 percent (e.g. a
    // file literally named "50%off") must not be accepted as progress.
    func testRejectsOutOfRangeOrNonNumericPercent() {
        XCTAssertNil(SSHTransferProgressParser.parse("weird 250% token"))
        XCTAssertNil(SSHTransferProgressParser.parse("file abc% token"))
    }

    // WHY: scp size tokens come in several units; the byte conversion underlies
    // any future byte-accurate reporting, so each unit must convert correctly.
    func testByteCountUnitConversion() {
        XCTAssertEqual(SSHTransferProgressParser.parseByteCount("1024KB"), 1_048_576)
        XCTAssertEqual(SSHTransferProgressParser.parseByteCount("2MB"), 2_097_152)
        XCTAssertEqual(SSHTransferProgressParser.parseByteCount("1GB"), 1_073_741_824)
        XCTAssertEqual(SSHTransferProgressParser.parseByteCount("512"), 512)
        XCTAssertNil(SSHTransferProgressParser.parseByteCount("notasize"))
    }
}

final class SSHRecursiveTransferCommandTests: XCTestCase {
    private func profile(
        destination: String = "user@example.com",
        port: Int? = nil,
        identityFile: String? = nil,
        options: [String] = []
    ) -> SSHHostProfile {
        SSHHostProfile(label: "h", destination: destination, port: port, identityFile: identityFile, options: options)
    }

    // WHY: the shared scp helpers omit "-r", so folder transfers silently no-op.
    // The whole point of this builder is to inject "-r" and order source/dest for
    // an UPLOAD. If "-r" is dropped or the operands are swapped, recursive upload
    // breaks; this pins both.
    func testUploadArgvIsRecursiveAndOrderedLocalThenRemote() {
        let args = SSHRecursiveTransferCommand.scpRecursiveArguments(
            profile: profile(),
            upload: true,
            localPath: "/tmp/dir",
            remotePath: "/srv/app"
        )
        XCTAssertTrue(args.contains("-r"), "recursive flag missing => folder copy no-ops")
        XCTAssertEqual(args.suffix(2), ["/tmp/dir", "user@example.com:/srv/app"])
    }

    // WHY: download must reverse the operand order (remote source -> local dest);
    // a swap would upload an empty/nonexistent local path over the remote tree.
    func testDownloadArgvIsRecursiveAndOrderedRemoteThenLocal() {
        let args = SSHRecursiveTransferCommand.scpRecursiveArguments(
            profile: profile(),
            upload: false,
            localPath: "/tmp/dest",
            remotePath: "/srv/app"
        )
        XCTAssertTrue(args.contains("-r"))
        XCTAssertEqual(args.suffix(2), ["user@example.com:/srv/app", "/tmp/dest"])
    }

    // WHY: scp uses uppercase "-P" for port (ssh uses lowercase). Identity and
    // -o options must also be forwarded, or recursive transfers to non-default
    // ports / keyed hosts would fail where single-file transfers succeed.
    func testForwardsPortIdentityAndOptions() {
        let args = SSHRecursiveTransferCommand.scpRecursiveArguments(
            profile: profile(port: 2222, identityFile: "/home/k/id_ed25519", options: ["Compression=yes"]),
            upload: true,
            localPath: "/a",
            remotePath: "/b"
        )
        XCTAssertEqual(adjacent(args, flag: "-P"), "2222")
        XCTAssertEqual(adjacent(args, flag: "-i"), "/home/k/id_ed25519")
        XCTAssertEqual(adjacent(args, flag: "-o"), "ConnectTimeout=6")
        XCTAssertTrue(args.contains("Compression=yes"))
    }

    private func adjacent(_ args: [String], flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

final class SSHLargeTreeConfirmTests: XCTestCase {
    // WHY: the confirm exists so a user never kicks off a huge silent recursive
    // copy by accident. Small trees must NOT prompt (avoid nag fatigue); large
    // ones MUST. These pin both sides of each threshold so a loosened comparison
    // (>= vs >) or a wrong constant is caught.
    func testConfirmsOnlyForLargeTrees() {
        XCTAssertFalse(SSHLargeTreeConfirm.needsConfirm(fileCount: 5, totalBytes: 1024))
        XCTAssertFalse(SSHLargeTreeConfirm.needsConfirm(
            fileCount: SSHLargeTreeConfirm.fileCountThreshold,
            totalBytes: SSHLargeTreeConfirm.byteThreshold))
        XCTAssertTrue(SSHLargeTreeConfirm.needsConfirm(
            fileCount: SSHLargeTreeConfirm.fileCountThreshold + 1,
            totalBytes: 0))
        XCTAssertTrue(SSHLargeTreeConfirm.needsConfirm(
            fileCount: 0,
            totalBytes: SSHLargeTreeConfirm.byteThreshold + 1))
    }
}

@MainActor
final class SSHTransferCancelFlowTests: XCTestCase {
    private func makeSurface() throws -> SSHSurface {
        try SSHSurface(workspaceID: WorkspaceID(), cwd: "/tmp", title: "t", router: nil)
    }

    // WHY: the user's cancel must visibly move the active row out of "Queued" and
    // into "Cancelled". If markCancelled failed to flip the row, the cancel
    // control would be a no-op and the queue would lie about state.
    func testCancelMarksQueuedRowCancelled() throws {
        let surface = try makeSurface()
        surface.enqueueForTesting(upload: true, localPath: "/a/f.txt", remotePath: "/b/f.txt")
        XCTAssertEqual(surface.queuedCountForTesting, 1)

        let marked = surface.markCancelledForTesting(localPath: "/a/f.txt", remotePath: "/b/f.txt")
        XCTAssertTrue(marked)
        XCTAssertEqual(surface.cancelledCountForTesting, 1)
        XCTAssertEqual(surface.queuedCountForTesting, 0)
    }

    // WHY: progress updates must promote a queued row to "Transferring" and carry
    // the clamped percent so the per-row bar advances. A regression that left the
    // row "Queued" or dropped the percent would freeze the visible progress.
    func testProgressPromotesRowAndStoresClampedPercent() throws {
        let surface = try makeSurface()
        surface.enqueueForTesting(upload: false, localPath: "/dl/x", remotePath: "/srv/x")

        surface.updateProgressForTesting(localPath: "/dl/x", remotePath: "/srv/x", percent: 150)
        XCTAssertEqual(surface.transferringCountForTesting, 1)
        XCTAssertEqual(surface.queueProgressForTesting(localPath: "/dl/x", remotePath: "/srv/x"), 100)

        surface.updateProgressForTesting(localPath: "/dl/x", remotePath: "/srv/x", percent: 42)
        XCTAssertEqual(surface.queueProgressForTesting(localPath: "/dl/x", remotePath: "/srv/x"), 42)
    }

    // WHY: cancel must work mid-transfer, not just while queued. After progress
    // promotes the row to "Transferring", a cancel must still flip it to
    // "Cancelled" so a user can abort a slow large copy.
    func testCancelWorksWhileTransferring() throws {
        let surface = try makeSurface()
        surface.enqueueForTesting(upload: true, localPath: "/a/big", remotePath: "/b/big")
        surface.updateProgressForTesting(localPath: "/a/big", remotePath: "/b/big", percent: 30)
        XCTAssertEqual(surface.transferringCountForTesting, 1)

        XCTAssertTrue(surface.markCancelledForTesting(localPath: "/a/big", remotePath: "/b/big"))
        XCTAssertEqual(surface.cancelledCountForTesting, 1)
        XCTAssertEqual(surface.transferringCountForTesting, 0)
    }
}
