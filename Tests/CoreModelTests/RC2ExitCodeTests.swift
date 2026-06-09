import XCTest
@testable import CoreModel

/// Tests RC2ExitCode — the single-source exit-code mapping for the rc2 CLI.
///
/// WHY: consistent machine-readable exit codes matter for scripting; callers
/// must be able to distinguish "app not running" (exit 2) from a daemon RPC
/// error (exit 1) and bad usage (exit 64) without parsing stderr text.
final class RC2ExitCodeTests: XCTestCase {

    // MARK: - success path

    func test_successResponse_returnsZero() {
        // A response with "result" key → no error → exit 0
        let response: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": ["ok": true]]
        XCTAssertEqual(RC2ExitCode.exitCode(for: response, isConnect: false), 0,
                       "Successful RPC response must exit 0")
    }

    func test_emptyResultResponse_returnsZero() {
        // Minimal success: result present (even if empty dict)
        let response: [String: Any] = ["result": [String: Any]()]
        XCTAssertEqual(RC2ExitCode.exitCode(for: response, isConnect: false), 0)
    }

    // MARK: - connect failure

    func test_connectFailure_returnsTwo() {
        // When the socket connect(2) syscall fails the caller sets isConnect=true.
        // Callers (e.g. shell scripts) use exit 2 to detect "app not running".
        let response: [String: Any] = ["error": ["code": -1, "message": "connect failed"]]
        XCTAssertEqual(RC2ExitCode.exitCode(for: response, isConnect: true), 2,
                       "Connect failure must exit 2 so scripts can detect app-not-running")
    }

    func test_connectFailure_isDistinctFromRPCError() {
        let connectResp: [String: Any] = ["error": ["code": -1, "message": "x"]]
        let rpcResp:     [String: Any] = ["error": ["code": -32600, "message": "x"]]
        XCTAssertNotEqual(
            RC2ExitCode.exitCode(for: connectResp, isConnect: true),
            RC2ExitCode.exitCode(for: rpcResp,     isConnect: false),
            "Connect failure (2) must differ from RPC error (1)"
        )
    }

    // MARK: - RPC error

    func test_rpcError_returnsOne() {
        // Daemon returned a JSON-RPC error object but the socket connected fine.
        let response: [String: Any] = ["error": ["code": -32600, "message": "Invalid Request"]]
        XCTAssertEqual(RC2ExitCode.exitCode(for: response, isConnect: false), 1,
                       "Daemon RPC error must exit 1")
    }

    func test_decodeFailure_isRPCError() {
        // The RPC struct returns an "error" dict for decode failures too.
        let response: [String: Any] = ["error": ["code": -1, "message": "decode failed"]]
        XCTAssertEqual(RC2ExitCode.exitCode(for: response, isConnect: false), 1)
    }

    // MARK: - constants

    func test_constants_haveExpectedValues() {
        XCTAssertEqual(RC2ExitCode.success,        0)
        XCTAssertEqual(RC2ExitCode.rpcError,       1)
        XCTAssertEqual(RC2ExitCode.connectFailure, 2)
        XCTAssertEqual(RC2ExitCode.usageError,     64)
    }
}
