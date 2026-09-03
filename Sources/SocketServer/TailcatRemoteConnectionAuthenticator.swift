import CryptoKit
import Darwin
import Foundation

public enum TailcatConnectionClassification: Sendable {
    case ordinary(initialBytes: Data)
    case remoteAuthenticated
    case rejected
}

/// Authenticates the fixed preamble emitted by the in-process Tailcat bridge.
/// The bridge, not HTTP or iOS, obtains the peer key from Tailcat's accepted
/// flow. A valid preamble therefore upgrades only that socket to remote trust;
/// the HTTP bearer gate remains independently mandatory.
public final class TailcatRemoteConnectionAuthenticator: @unchecked Sendable {
    public static let preambleSize = 144
    public static let preambleDeadline: TimeInterval = 2

    public struct Context: Sendable {
        public let serverID: String
        public let listenerID: Data
        public let secret: Data
        public let allowedPeerPublic: [String]

        public init(serverID: String, listenerID: Data, secret: Data, allowedPeerPublic: [String]) {
            self.serverID = serverID
            self.listenerID = listenerID
            self.secret = secret
            self.allowedPeerPublic = allowedPeerPublic
        }
    }

    private final class StoredContext {
        let serverDigest: Data
        let listenerID: Data
        let allowedPeers: Set<Data>
        var secret: [UInt8]
        var replay = ReplayWindow()

        init?(_ context: Context) {
            guard context.listenerID.count == 16,
                  context.secret.count == 32 else {
                return nil
            }
            let peers = context.allowedPeerPublic.compactMap(TailcatRemoteConnectionAuthenticator.nodePublicBytes)
            guard !peers.isEmpty, peers.count == context.allowedPeerPublic.count else { return nil }
            serverDigest = Data(SHA256.hash(data: Data(context.serverID.utf8)))
            listenerID = context.listenerID
            allowedPeers = Set(peers)
            secret = Array(context.secret)
        }

        func zeroize() {
            _ = secret.withUnsafeMutableBytes { bytes in
                bytes.initializeMemory(as: UInt8.self, repeating: 0)
            }
            replay.removeAll()
        }

        deinit { zeroize() }
    }

    /// Bounded replay state. Old counters remain rejected after eviction,
    /// while a window permits concurrently accepted flows to arrive out of order.
    private struct ReplayWindow {
        private static let width: UInt64 = 4_096
        private var highest: UInt64 = 0
        private var entries: [UInt64: Data] = [:]

        mutating func consume(counter: UInt64, nonce: Data) -> Bool {
            guard counter > 0, nonce.count == 16 else { return false }
            if highest >= Self.width, counter <= highest - Self.width { return false }
            guard entries[counter] == nil,
                  !entries.values.contains(nonce) else { return false }
            highest = max(highest, counter)
            entries[counter] = nonce
            if highest >= Self.width {
                let floor = highest - Self.width
                entries = entries.filter { $0.key > floor }
            }
            return true
        }

        mutating func removeAll() {
            highest = 0
            entries.removeAll(keepingCapacity: false)
        }
    }

    private let lock = NSLock()
    private var contexts: [StoredContext] = []

    public init() {}

    public func replaceContexts(_ contexts: [Context]) {
        let replacements = contexts.compactMap(StoredContext.init)
        lock.lock()
        let prior = self.contexts
        self.contexts = replacements
        lock.unlock()
        prior.forEach { $0.zeroize() }
    }

    public func removeAllContexts() {
        replaceContexts([])
    }

    public func classify(fd: Int32, ordinaryReadTimeout: TimeInterval) -> TailcatConnectionClassification {
        Self.setReadTimeout(fd: fd, seconds: ordinaryReadTimeout)
        guard let prefix = Self.readExactly(fd: fd, count: 4) else { return .rejected }
        guard prefix == Data("RCTC".utf8) else { return .ordinary(initialBytes: prefix) }

        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(Self.preambleDeadline * 1_000_000_000)
        guard let suffix = Self.readExactly(
            fd: fd,
            count: Self.preambleSize - prefix.count,
            deadlineUptimeNanoseconds: deadline
        ) else {
            return .rejected
        }
        return verify(prefix + suffix) ? .remoteAuthenticated : .rejected
    }

    public func verify(_ preamble: Data) -> Bool {
        guard preamble.count == Self.preambleSize,
              preamble.prefix(4) == Data("RCTC".utf8),
              preamble[4] == 1,
              preamble[5..<8].allSatisfy({ $0 == 0 }) else { return false }

        let listener = Data(preamble[8..<24])
        let server = Data(preamble[24..<56])
        let counter = preamble[56..<64].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let nonce = Data(preamble[64..<80])
        let peer = Data(preamble[80..<112])
        let code = Data(preamble[112..<144])
        let authenticatedBytes = Data(preamble[..<112])

        lock.lock()
        defer { lock.unlock() }
        guard let context = contexts.first(where: {
            $0.listenerID == listener && $0.serverDigest == server && $0.allowedPeers.contains(peer)
        }) else { return false }
        let key = SymmetricKey(data: context.secret)
        guard HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: authenticatedBytes, using: key) else {
            return false
        }
        return context.replay.consume(counter: counter, nonce: nonce)
    }

    private static func nodePublicBytes(_ value: String) -> Data? {
        // Bounded suffix take: only the 64 hex chars after the first ":" are
        // needed — no split array over the whole node public string.
        let hex: Substring
        if let colon = value.firstIndex(of: ":") {
            hex = value[value.index(after: colon)...]
        } else {
            hex = value[...]
        }
        guard hex.count == 64 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        for _ in 0..<32 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func readExactly(
        fd: Int32,
        count: Int,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            if let deadlineUptimeNanoseconds {
                let current = DispatchTime.now().uptimeNanoseconds
                guard current < deadlineUptimeNanoseconds else { return nil }
                setReadTimeout(
                    fd: fd,
                    seconds: TimeInterval(deadlineUptimeNanoseconds - current) / 1_000_000_000
                )
            }
            let readCount = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), count - offset)
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else { return nil }
            offset += readCount
        }
        return Data(bytes)
    }

    private static func setReadTimeout(fd: Int32, seconds: TimeInterval) {
        let clamped = max(0.001, seconds)
        var timeout = timeval(
            tv_sec: Int(clamped),
            tv_usec: Int32((clamped - floor(clamped)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}
