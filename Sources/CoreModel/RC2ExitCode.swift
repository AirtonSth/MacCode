import Foundation

/// Exit codes for the rc2 CLI tool.
///
/// Rules (POSIX / sysexits conventions kept simple):
///   64 — usage error (bad arguments, unknown command)
///    2 — connect failure (socket unreachable; app not running)
///    1 — RPC error returned by the daemon
///    0 — success
///
/// Keeping this in CoreModel makes it importable by unit tests
/// without pulling in the executable target.
public enum RC2ExitCode {
    public static let success:        Int32 = 0
    public static let rpcError:       Int32 = 1
    public static let connectFailure: Int32 = 2
    public static let usageError:     Int32 = 64

    /// Map a JSON-RPC response dict to the appropriate exit code.
    ///
    /// - Parameters:
    ///   - response:  The `[String: Any]` dict returned by `RPC.call(_:params:)`.
    ///   - isConnect: `true` when the error originated from a failed connect(2)
    ///                syscall (as opposed to a daemon-level RPC error).
    /// - Returns: `0` when the response contains a `"result"` key,
    ///            `2` for connect failures, `1` for all other RPC errors.
    public static func exitCode(for response: [String: Any], isConnect: Bool) -> Int32 {
        guard response["error"] != nil else { return success }
        return isConnect ? connectFailure : rpcError
    }
}
