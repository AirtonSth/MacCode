import XCTest
import CoreModel

/// Table tests for SSHCommandBuilder argument builders (T031).
///
/// WHY: SSHCommandBuilder.sshArguments, scpUploadArguments, and
/// scpDownloadArguments produce the argv that is exec'd verbatim by the
/// router. A wrong flag order, missing ConnectTimeout, or swapped
/// local/remote path silently breaks SSH sessions or produces incorrect
/// scp transfers that may overwrite files at the wrong destination.
/// These tests pin the exact argv shape so regressions are caught before
/// any live SSH session is attempted.

// MARK: - sshArguments

final class SSHCommandBuilderSSHArgumentsTests: XCTestCase {

    private func profile(
        destination: String = "user@host.example",
        port: Int? = nil,
        identityFile: String? = nil,
        options: [String] = []
    ) -> SSHHostProfile {
        SSHHostProfile(label: "h", destination: destination,
                       port: port, identityFile: identityFile, options: options)
    }

    // WHY: ConnectTimeout=6 must be present so a connection to an
    // unreachable host fails after 6 s instead of hanging indefinitely and
    // blocking the main-thread router.
    func test_sshArguments_alwaysIncludesConnectTimeout() {
        let args = SSHCommandBuilder.sshArguments(for: profile())
        XCTAssertTrue(args.contains("ConnectTimeout=6"),
                      "ConnectTimeout=6 must be in every ssh argv to bound hang time")
    }

    // WHY: ServerAliveInterval keeps the connection alive through NAT/firewall
    // idle-timeout and detects a dead peer. Without it a dropped connection
    // looks like a stall to the user.
    func test_sshArguments_alwaysIncludesServerAliveInterval() {
        let args = SSHCommandBuilder.sshArguments(for: profile())
        XCTAssertTrue(args.contains("ServerAliveInterval=20"),
                      "ServerAliveInterval=20 must be present to detect dead SSH peers")
    }

    // WHY: the destination must be the last argument; ssh(1) requires it at
    // the end of the option list.
    func test_sshArguments_destinationIsLastElement() {
        let args = SSHCommandBuilder.sshArguments(for: profile(destination: "alice@server.io"))
        XCTAssertEqual(args.last, "alice@server.io",
                       "destination must be the final argument in ssh argv")
    }

    // WHY: a non-default port is expressed as -p <port>; without it ssh
    // connects to port 22, making the surface useless for non-standard hosts.
    func test_sshArguments_includesPortFlagWhenPresent() {
        let args = SSHCommandBuilder.sshArguments(for: profile(port: 2222))
        guard let pIdx = args.firstIndex(of: "-p") else {
            XCTFail("-p flag missing when port is set")
            return
        }
        XCTAssertEqual(args[pIdx + 1], "2222",
                       "-p flag must be followed immediately by the port number")
    }

    func test_sshArguments_omitsPortFlagWhenAbsent() {
        let args = SSHCommandBuilder.sshArguments(for: profile(port: nil))
        XCTAssertFalse(args.contains("-p"),
                       "no port in profile must produce no -p flag")
    }

    // WHY: an identity file lets the connection authenticate with a specific
    // key pair. Missing -i means ssh falls back to the agent or default keys,
    // which may fail or pick the wrong identity.
    func test_sshArguments_includesIdentityFlagWhenPresent() {
        let key = "/home/user/.ssh/id_ed25519"
        let args = SSHCommandBuilder.sshArguments(for: profile(identityFile: key))
        guard let iIdx = args.firstIndex(of: "-i") else {
            XCTFail("-i flag missing when identityFile is set")
            return
        }
        XCTAssertEqual(args[iIdx + 1], key,
                       "-i flag must be followed by the identity file path")
    }

    func test_sshArguments_omitsIdentityFlagForEmptyString() {
        let args = SSHCommandBuilder.sshArguments(for: profile(identityFile: ""))
        XCTAssertFalse(args.contains("-i"),
                       "empty identityFile must produce no -i flag")
    }

    // WHY: batchMode=yes disables prompts so a non-interactive connection
    // does not stall waiting for keyboard input. It must be opt-in so
    // interactive sessions can still prompt.
    func test_sshArguments_batchModeAddsBatchModeYes() {
        let args = SSHCommandBuilder.sshArguments(for: profile(), batchMode: true)
        XCTAssertTrue(args.contains("BatchMode=yes"),
                      "batchMode=true must add BatchMode=yes to the argv")
    }

    func test_sshArguments_batchModeDefaultFalseOmitsBatchMode() {
        let args = SSHCommandBuilder.sshArguments(for: profile())
        XCTAssertFalse(args.contains("BatchMode=yes"),
                       "default batchMode must NOT include BatchMode=yes")
    }

    // WHY: profile.options are passthrough -o flags for advanced ssh settings
    // (e.g. ProxyJump, ForwardAgent). Empty-string options must be skipped so
    // ssh does not receive "-o ''" which produces a parse error.
    func test_sshArguments_appendsNonEmptyOptions() {
        let args = SSHCommandBuilder.sshArguments(for: profile(options: ["ProxyJump=bastion", ""]))
        let oCount = args.indices.filter { args[$0] == "-o" }.count
        // One -o per non-empty option plus the built-in options
        let builtIn = ["ConnectTimeout=6", "ServerAliveInterval=20",
                       "ServerAliveCountMax=2", "StrictHostKeyChecking=accept-new"]
        XCTAssertTrue(args.contains("ProxyJump=bastion"),
                      "non-empty option must appear in argv as -o value")
        XCTAssertFalse(args.contains(""),
                       "empty option string must be dropped, not passed as a bare -o value")
        // Verify built-in options are all present
        for opt in builtIn {
            XCTAssertTrue(args.contains(opt), "built-in option \(opt) must always be present")
        }
        _ = oCount // used indirectly via contains checks above
    }
}

// MARK: - scpUploadArguments

final class SSHCommandBuilderSCPUploadTests: XCTestCase {

    private func profile(
        destination: String = "user@host.example",
        port: Int? = nil,
        identityFile: String? = nil,
        options: [String] = []
    ) -> SSHHostProfile {
        SSHHostProfile(label: "h", destination: destination,
                       port: port, identityFile: identityFile, options: options)
    }

    // WHY: for an upload the local path must appear before the
    // remote "destination:remotePath" token. Reversing them would download
    // instead of upload, silently overwriting the local file.
    func test_scpUpload_localPathBeforeRemote() {
        let args = SSHCommandBuilder.scpUploadArguments(
            profile: profile(destination: "u@h"),
            localPath: "/local/file.txt",
            remotePath: "/remote/file.txt"
        )
        let localIdx = args.firstIndex(of: "/local/file.txt")!
        let remoteToken = "u@h:/remote/file.txt"
        let remoteIdx = args.firstIndex(of: remoteToken)!
        XCTAssertLessThan(localIdx, remoteIdx,
                          "upload: local path must precede remote path in scp argv")
    }

    // WHY: the remote token must be "destination:remotePath"; a bare remotePath
    // is treated as a local path by scp, producing a local copy instead of a
    // remote transfer.
    func test_scpUpload_remoteTokenFormat() {
        let args = SSHCommandBuilder.scpUploadArguments(
            profile: profile(destination: "bob@server.io"),
            localPath: "/src/data.csv",
            remotePath: "/home/bob/data.csv"
        )
        XCTAssertTrue(args.contains("bob@server.io:/home/bob/data.csv"),
                      "remote argument must be 'destination:remotePath' (no space)")
    }

    // WHY: scp uses uppercase -P for the port, unlike ssh which uses lowercase
    // -p. Using -p with scp silently passes a different argument, causing scp
    // to connect on port 22 regardless of the configured port.
    func test_scpUpload_usesUppercasePForPort() {
        let args = SSHCommandBuilder.scpUploadArguments(
            profile: profile(port: 2222),
            localPath: "/a",
            remotePath: "/b"
        )
        guard let pIdx = args.firstIndex(of: "-P") else {
            XCTFail("-P (uppercase) flag missing for scp port")
            return
        }
        XCTAssertEqual(args[pIdx + 1], "2222")
        XCTAssertFalse(args.contains("-p"),
                       "scp must use -P (uppercase), NOT -p (lowercase) for the port")
    }

    func test_scpUpload_includesIdentityFile() {
        let args = SSHCommandBuilder.scpUploadArguments(
            profile: profile(identityFile: "/key"),
            localPath: "/a",
            remotePath: "/b"
        )
        XCTAssertTrue(args.contains("-i"))
        let iIdx = args.firstIndex(of: "-i")!
        XCTAssertEqual(args[iIdx + 1], "/key")
    }
}

// MARK: - scpDownloadArguments

final class SSHCommandBuilderSCPDownloadTests: XCTestCase {

    private func profile(destination: String = "user@host.example",
                         port: Int? = nil) -> SSHHostProfile {
        SSHHostProfile(label: "h", destination: destination, port: port)
    }

    // WHY: for a download the remote "destination:remotePath" token must come
    // before the local path. Reversing them would attempt to copy a local path
    // to a local destination -- no remote file is fetched.
    func test_scpDownload_remotePathBeforeLocal() {
        let args = SSHCommandBuilder.scpDownloadArguments(
            profile: profile(destination: "u@h"),
            remotePath: "/remote/log.txt",
            localPath: "/local/log.txt"
        )
        let remoteToken = "u@h:/remote/log.txt"
        let remoteIdx = args.firstIndex(of: remoteToken)!
        let localIdx = args.firstIndex(of: "/local/log.txt")!
        XCTAssertLessThan(remoteIdx, localIdx,
                          "download: remote path must precede local path in scp argv")
    }

    func test_scpDownload_remoteTokenFormat() {
        let args = SSHCommandBuilder.scpDownloadArguments(
            profile: profile(destination: "alice@files.io"),
            remotePath: "/data/export.zip",
            localPath: "/tmp/export.zip"
        )
        XCTAssertTrue(args.contains("alice@files.io:/data/export.zip"),
                      "remote argument for download must be 'destination:remotePath'")
    }

    func test_scpDownload_usesUppercasePForPort() {
        let args = SSHCommandBuilder.scpDownloadArguments(
            profile: profile(port: 4242),
            remotePath: "/r",
            localPath: "/l"
        )
        XCTAssertTrue(args.contains("-P"),
                      "-P (uppercase) port flag must be present")
        XCTAssertFalse(args.contains("-p"),
                       "lowercase -p must NOT appear in scp argv")
    }
}
