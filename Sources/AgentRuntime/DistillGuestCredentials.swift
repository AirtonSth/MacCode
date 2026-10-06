import Foundation
import os

private let guestCredentialLog = Logger(subsystem: "io.remotecode.agent", category: "distill.guest.credentials")

public enum DistillGuestCredentialError: LocalizedError, Equatable {
    case notSignedIn(DistillAccountProvider)
    case unreadable(DistillAccountProvider)
    case lockTimeout(DistillAccountProvider)
    case refreshTokenMissing(DistillAccountProvider)
    /// The provider refused this refresh token (it is spent or revoked).
    case refreshRejected(DistillAccountProvider, status: Int, code: String?)
    /// A transient failure (network, 429, 5xx): the same token may work later.
    case refreshFailed(DistillAccountProvider, status: Int, code: String?)
    case refreshResponseInvalid(DistillAccountProvider)
    case accountChanged(DistillAccountProvider)
    case grokLoginExpiring(expiresAt: Date)
    case unsafeDirectory(path: String)
    case writeFailed(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn(let provider):
            return "\(provider.displayName) is not signed in on this Mac. Sign in under Settings › Accounts (or run `\(Self.loginCommand(provider))`), then send again."
        case .unreadable(let provider):
            return "The \(provider.displayName) sign-in file on this Mac (\(provider.credentialFileName)) cannot be read. Sign in to \(provider.displayName) again under Settings › Accounts, then send again."
        case .lockTimeout(let provider):
            return "Another Distill process on this Mac is still refreshing the \(provider.displayName) sign-in. Send again in a moment."
        case .refreshTokenMissing(let provider):
            return "The \(provider.displayName) sign-in on this Mac has expired and cannot be renewed. Sign in again under Settings › Accounts (or run `\(Self.loginCommand(provider))`), then send again."
        case .refreshRejected(let provider, let status, let code):
            return "\(provider.displayName) rejected the sign-in renewal on this Mac (HTTP \(status)\(code.map { ", \($0)" } ?? "")). Sign in to \(provider.displayName) again under Settings › Accounts (or run `\(Self.loginCommand(provider))`), then send again."
        case .refreshFailed(let provider, let status, let code):
            let cause = status == 0 ? "the sign-in server could not be reached" : "HTTP \(status)\(code.map { ", \($0)" } ?? "")"
            return "Could not renew the \(provider.displayName) sign-in on this Mac (\(cause)). The Linux agent was not started; send again in a moment."
        case .refreshResponseInvalid(let provider):
            return "\(provider.displayName) answered the sign-in renewal with something this app does not understand. The sign-in on this Mac was left unchanged; send again, or sign in again under Settings › Accounts."
        case .accountChanged(let provider):
            return "\(provider.displayName) renewed the sign-in for a different account. The sign-in on this Mac was left unchanged; sign in again under Settings › Accounts."
        case .grokLoginExpiring(let expiresAt):
            let when = expiresAt.timeIntervalSinceNow <= 0
                ? "has expired"
                : "expires at \(DateFormatter.localizedString(from: expiresAt, dateStyle: .none, timeStyle: .short))"
            return "The Grok login on this Mac \(when). Open a Distill thread on the Mac to refresh it, or run `distill login`, then send again."
        case .unsafeDirectory(let path):
            return "\(path) is not a plain directory, so the Linux agent's sign-in copies were not written there."
        case .writeFailed(let path, let code):
            return "Could not write \(path): \(String(cString: strerror(code)))."
        }
    }

    static func loginCommand(_ provider: DistillAccountProvider) -> String {
        (["distill"] + (provider.cliLoginArguments ?? ["login"])).joined(separator: " ")
    }
}

/// The in-guest agent's copies of the user's Distill sign-ins.
///
/// The guest gets its own `DISTILL_HOME` (a directory on the guest-home bind,
/// never the Mac's `~/.distill` and never single-file binds, which a
/// rename-replace would pin to the old inode). The copies carry the access
/// token but a blank refresh token: Claude and ChatGPT rotate refresh tokens
/// and treat a reused one as theft, so only the Mac may ever spend one. Claude
/// and Codex re-read the file on every request, and Grok adopts newer tokens
/// from disk, so re-copying after the Mac renews a token is enough.
///
/// Every file operation is relative to a directory descriptor opened without
/// following symlinks: the guest owns that directory and could otherwise point
/// it at the Mac's own `~/.distill`, which these writes and deletes would then
/// destroy.
public enum DistillGuestCredentials {
    /// What one sync did, by provider. Never carries file contents.
    public struct SyncResult: Equatable, Sendable {
        public var written: [DistillAccountProvider] = []
        public var unchanged: [DistillAccountProvider] = []
        /// Signed out on the Mac: the guest copy was deleted.
        public var removed: [DistillAccountProvider] = []
        /// The Mac file is not a JSON object: not copied, guest copy deleted.
        public var unreadable: [DistillAccountProvider] = []
    }

    static let temporaryPrefix = ".rc-credential-"

    /// `<guest home>/.distill`, the guest run's `DISTILL_HOME` seen from the Mac.
    public static func distillHome(guestHome: URL) -> URL {
        guestHome.appendingPathComponent(".distill", isDirectory: true)
    }

    // MARK: - Guest copies

    /// The bytes the guest gets for one Mac credential file; nil when the Mac
    /// file is not a JSON object (copying it raw could carry a refresh token).
    static func guestCopy(_ provider: DistillAccountProvider, hostData: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: hostData)) as? [String: Any] else { return nil }
        switch provider {
        case .claude:
            // Distill requires the key: without it the file does not parse and
            // the account looks signed out.
            if root["refresh_token"] != nil { root["refresh_token"] = "" }
        case .chatgpt:
            if var tokens = root["tokens"] as? [String: Any], tokens["refresh_token"] != nil {
                tokens["refresh_token"] = ""
                root["tokens"] = tokens
            }
        case .grok:
            // Optional in Distill's Grok store: each scope just loses it.
            for (scope, value) in root {
                guard var entry = value as? [String: Any] else { continue }
                entry.removeValue(forKey: "refresh_token")
                root[scope] = entry
            }
        case .openrouter:
            break
        }
        guard var data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Makes the guest copies match the Mac sign-ins: written atomically at
    /// 0600 when they differ, deleted when the Mac is signed out.
    @discardableResult
    public static func sync(hostHome: URL, guestDistillHome: URL) throws -> SyncResult {
        let directory = try PrivateDirectory(guestDistillHome, create: true)
        defer { directory.close() }
        var result = SyncResult()
        for provider in DistillAccountProvider.allCases {
            let name = provider.credentialFileName
            let hostFile = hostHome.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: hostFile.path) else {
                if directory.remove(name) { result.removed.append(provider) }
                continue
            }
            guard let hostData = try? Data(contentsOf: hostFile),
                  let copy = guestCopy(provider, hostData: hostData) else {
                directory.remove(name)
                result.unreadable.append(provider)
                guestCredentialLog.error("bot.guest.credentials.unreadable file=\(name, privacy: .public)")
                continue
            }
            if directory.read(name) == copy {
                result.unchanged.append(provider)
                continue
            }
            try directory.writeAtomically(copy, to: name)
            result.written.append(provider)
        }
        return result
    }

    /// Deletes every credential copy (and Distill's locks, temp and corrupt
    /// backups of them) from a guest `DISTILL_HOME`. Missing directory: no-op.
    public static func removeCopies(guestDistillHome: URL) throws {
        let directory: PrivateDirectory
        do {
            directory = try PrivateDirectory(guestDistillHome, create: false)
        } catch DistillGuestCredentialError.writeFailed(_, let code) where code == ENOENT {
            return
        }
        defer { directory.close() }
        let names = DistillAccountProvider.allCases.map(\.credentialFileName)
        for entry in directory.entries() where entry.hasPrefix(temporaryPrefix)
            || names.contains(where: { entry == $0 || entry.hasPrefix($0 + ".") }) {
            directory.remove(entry)
        }
    }

    /// App launch: no guest run survives a quit, so no bot keeps a copy.
    public static func removeAllCopies(guestHomeRoot: URL) {
        let bots = (try? FileManager.default.contentsOfDirectory(atPath: guestHomeRoot.path)) ?? []
        for bot in bots {
            let home = guestHomeRoot.appendingPathComponent(bot, isDirectory: true)
                .appendingPathComponent("home", isDirectory: true)
            do {
                try removeCopies(guestDistillHome: distillHome(guestHome: home))
            } catch {
                guestCredentialLog.error("bot.guest.credentials.cleanup_failed bot=\(bot, privacy: .public)")
            }
        }
    }

    // MARK: - Which sign-in a model needs

    /// The Distill account a model is served with, or nil when it uses an API
    /// key or a provider this app does not manage. A nil/empty model is the
    /// host config's `[models] default`.
    public static func accountProvider(model: String?, hostConfig: String) -> DistillAccountProvider? {
        var id = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { id = DistillGuestConfig.defaultModel(hostConfig: hostConfig) ?? "" }
        let lowered = id.lowercased()
        // Distill's own catalog prefixes (claude_models.rs, codex_models.rs).
        if lowered.hasPrefix("claude/") || lowered.hasPrefix("anthropic/") { return .claude }
        if lowered.hasPrefix("chatgpt/") { return .chatgpt }
        if let endpoint = DistillGuestConfig.modelEndpoint(id: id, hostConfig: hostConfig) {
            guard !endpoint.hasOwnKey, let base = endpoint.baseURL?.lowercased() else { return nil }
            // codex_auth.rs is_codex_backend / claude_auth.rs is_claude_backend.
            if base.hasPrefix("https://chatgpt.com/backend-api") { return .chatgpt }
            if let url = URL(string: base), url.scheme == "https", url.host == "api.anthropic.com" { return .claude }
            return nil
        }
        if lowered.hasPrefix("grok") { return .grok }
        return nil
    }
}

/// Keeps the guest copies of every live guest run fresh while it runs: a Mac
/// Distill process (or the pre-run refresh) renewing a token rewrites
/// `~/.distill/*.json` by rename, which changes the directory and re-syncs
/// every registered guest home after a short debounce. The copies of a guest
/// home are deleted when its last run ends.
public final class DistillGuestCredentialMirror: @unchecked Sendable {
    private let hostHome: URL
    private let debounce: TimeInterval
    // Every mutable member below is touched only on this queue.
    private let queue = DispatchQueue(label: "io.remotecode.distill.guest-credentials")
    private var runs: [String: URL] = [:]
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init(hostHome: URL, debounce: TimeInterval = 0.5) {
        self.hostHome = hostHome
        self.debounce = debounce
    }

    deinit {
        source?.cancel()
    }

    /// Copies the sign-ins into `guestDistillHome` now (the pre-run sync) and
    /// keeps them fresh until `end(runID:)`.
    @discardableResult
    public func begin(runID: String, guestDistillHome: URL) throws -> DistillGuestCredentials.SyncResult {
        try queue.sync {
            let home = guestDistillHome.standardizedFileURL
            let result = try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: home)
            runs[runID] = home
            if source == nil { startWatching() }
            return result
        }
    }

    public func end(runID: String) {
        queue.sync {
            guard let home = runs.removeValue(forKey: runID) else { return }
            if !runs.values.contains(home) {
                do {
                    try DistillGuestCredentials.removeCopies(guestDistillHome: home)
                } catch {
                    guestCredentialLog.error("bot.guest.credentials.cleanup_failed run=\(runID, privacy: .public)")
                }
            }
            if runs.isEmpty {
                pending?.cancel()
                pending = nil
                source?.cancel()
                source = nil
            }
        }
    }

    private func startWatching() {
        let descriptor = open(hostHome.path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            guestCredentialLog.error("bot.guest.credentials.watch_failed errno=\(errno, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            // The directory itself was replaced: watch the new one.
            if !source.data.isDisjoint(with: [.rename, .delete]) {
                source.cancel()
                self.source = nil
                self.startWatching()
            }
            self.scheduleResync()
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func scheduleResync() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.resyncAll() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func resyncAll() {
        pending = nil
        for home in Set(runs.values) {
            do {
                try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: home)
            } catch {
                guestCredentialLog.error("bot.guest.credentials.resync_failed")
            }
        }
    }
}

/// A directory opened with `O_NOFOLLOW`; all access is relative to it.
struct PrivateDirectory {
    let path: String
    let descriptor: Int32

    init(_ url: URL, create: Bool) throws {
        path = url.path
        var fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT, create {
            if mkdir(path, 0o700) != 0, errno != EEXIST {
                throw DistillGuestCredentialError.writeFailed(path: path, errno: errno)
            }
            fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR { throw DistillGuestCredentialError.unsafeDirectory(path: path) }
            throw DistillGuestCredentialError.writeFailed(path: path, errno: code)
        }
        if create, fchmod(fd, 0o700) != 0 {
            let code = errno
            Darwin.close(fd)
            throw DistillGuestCredentialError.writeFailed(path: path, errno: code)
        }
        descriptor = fd
    }

    func close() { Darwin.close(descriptor) }

    /// Nil when missing, unreadable or not a regular file (a symlink included).
    func read(_ name: String) -> Data? {
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return try? handle.readToEnd() ?? Data()
    }

    /// Temp file at 0600 + fsync + rename, so a reader sees the old file or
    /// the whole new one, never a partial one.
    func writeAtomically(_ data: Data, to name: String) throws {
        let temp = "\(DistillGuestCredentials.temporaryPrefix)\(UUID().uuidString).tmp"
        let fd = openat(descriptor, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DistillGuestCredentialError.writeFailed(path: "\(path)/\(name)", errno: errno) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == 0, fsync(fd) != 0 { failure = errno }
        Darwin.close(fd)
        if failure == 0, renameat(descriptor, temp, descriptor, name) != 0 { failure = errno }
        if failure != 0 {
            unlinkat(descriptor, temp, 0)
            throw DistillGuestCredentialError.writeFailed(path: "\(path)/\(name)", errno: failure)
        }
    }

    @discardableResult
    func remove(_ name: String) -> Bool {
        unlinkat(descriptor, name, 0) == 0
    }

    func entries() -> [String] {
        let fd = dup(descriptor)
        guard fd >= 0 else { return [] }
        guard let stream = fdopendir(fd) else {
            Darwin.close(fd)
            return []
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
