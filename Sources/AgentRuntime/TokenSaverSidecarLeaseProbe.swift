import Foundation
import Darwin

/// Pure probe for the Distill sidecar lease written to `DistillCLIState.json`.
///
/// Host controllers may lag (status still `.starting` / `.notStarted` while the
/// sidecar is already serving). Nested provider proxies have no controller —
/// they only have the state file path. Both paths use this seam so admission
/// can re-enable distill / managed_path when the lease is live.
public enum TokenSaverSidecarLeaseProbe {
    public struct Lease: Sendable, Equatable {
        public let baseURL: String
        public let authToken: String
        public let pid: Int32

        public init(baseURL: String, authToken: String, pid: Int32) {
            self.baseURL = baseURL
            self.authToken = authToken
            self.pid = pid
        }
    }

    private struct StateFile: Decodable {
        let baseURL: String
        let authToken: String
        let pid: Int32

        enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
            case authToken = "auth_token"
            case pid
        }
    }

    // PERF: admission / isHealthy paths allocated JSONDecoder per lease read.
    // Nested proxies and host controllers probe frequently — reuse one decoder
    // under a short lock (JSONDecoder is not thread-safe).
    private static let decodeLock = NSLock()
    private static let decoder = JSONDecoder()

    /// Decode a lease from raw DistillCLIState.json bytes. Returns nil when the
    /// payload is missing, malformed, or lacks a usable pid / URL / token.
    public static func readLease(from data: Data) -> Lease? {
        decodeLock.lock()
        let decoded = try? decoder.decode(StateFile.self, from: data)
        decodeLock.unlock()
        guard let decoded else { return nil }
        let base = decoded.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = decoded.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty,
              URL(string: base) != nil,
              !token.isEmpty,
              decoded.pid > 1 else {
            return nil
        }
        return Lease(baseURL: base, authToken: token, pid: decoded.pid)
    }

    public static func readLease(at url: URL) -> Lease? {
        guard let data = try? Data(contentsOf: url, options: [.uncached]) else { return nil }
        return readLease(from: data)
    }

    /// Healthy when the lease decodes and the recorded pid is still alive.
    public static func isHealthy(
        lease: Lease?,
        processIsAlive: (Int32) -> Bool = defaultProcessIsAlive
    ) -> Bool {
        guard let lease else { return false }
        return processIsAlive(lease.pid)
    }

    public static func isHealthy(
        stateFileURL: URL?,
        processIsAlive: (Int32) -> Bool = defaultProcessIsAlive
    ) -> Bool {
        guard let stateFileURL else { return false }
        return isHealthy(lease: readLease(at: stateFileURL), processIsAlive: processIsAlive)
    }

    public static func isHealthy(
        stateFileData: Data?,
        processIsAlive: (Int32) -> Bool = defaultProcessIsAlive
    ) -> Bool {
        guard let stateFileData else { return false }
        return isHealthy(lease: readLease(from: stateFileData), processIsAlive: processIsAlive)
    }

    public static func defaultProcessIsAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
