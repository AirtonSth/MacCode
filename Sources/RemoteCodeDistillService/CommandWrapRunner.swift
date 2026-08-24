import Darwin
import AgentRuntime
import DistillCore
import Foundation

/// OS-level execution half of the RTK-style transparent command wrappers. The pure
/// decisions (what to wrap, thresholds, contracts, real-binary resolution) live in
/// `CommandWrapPolicy`; this type runs the real command and detects — fail-closed — whether
/// the wrapper is the TERMINAL command feeding the agent before compressing.
enum CommandWrapRunner {
    /// Optional best-effort work (Wave A ledger POST) that must not delay stdout delivery.
    typealias DeferredSideEffect = @Sendable () async -> Void

    /// Compresses `captured` stdout (reversible, with the given store floor) using the optional
    /// per-command extraction `query`, returning the emitted bytes (compressed text + recovery
    /// handle) plus an optional deferred side effect, or nil to fall back to the raw bytes.
    typealias Compressor = @Sendable (
        _ captured: Data,
        _ query: String?,
        _ storeFloorBytes: Int
    ) async -> (bytes: Data, deferredSideEffect: DeferredSideEffect?)?

    /// Reads from the real command's stdout in 64 KB chunks.
    private static let readChunk = 64 * 1024
    /// Above this captured size we never buffer for compression — we stream the output raw so a
    /// runaway producer can't be held in memory. Matches the sidecar's own 512 KB stdin cap with
    /// generous headroom for review-sized output.
    private static let captureCapBytes = 8 * 1024 * 1024

    /// Fail-open for unexpected PATH wrappers (`node`, `env`, leftover names).
    /// Inherit every stream so a long-running child (Codex app-server via
    /// `#!/usr/bin/env node`) is not buffered or distilled.
    static func runPassthroughInheritingStreams(command: String, args: [String]) -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard let realExe = resolveRealExecutable(command: command, environment: env) else {
            FileHandle.standardError.write(
                Data("\(CommandWrapPolicy.commandBasename(command)): command not found\n".utf8)
            )
            return 127
        }
        return runInheritingAllStreams(executable: realExe, args: args)
    }

    /// Runs the wrapped command and writes its (possibly compressed) output to our real stdout
    /// before any deferred ledger side effect is returned to the caller.
    /// Always returns the REAL command's exit code so the agent's shell sees the true status.
    static func run(
        command: String,
        args: [String],
        compress: Compressor
    ) async -> (exitCode: Int32, deferredSideEffect: DeferredSideEffect?) {
        let env = ProcessInfo.processInfo.environment
        guard let realExe = resolveRealExecutable(command: command, environment: env) else {
            FileHandle.standardError.write(Data("\(CommandWrapPolicy.commandBasename(command)): command not found\n".utf8))
            return (127, nil)
        }

        let isTerminalToAgent = WrapPipeInspector.isTerminalToAgent()
        switch CommandWrapPolicy.childStreams(
            command: command,
            args: args,
            environment: env,
            isTerminalToAgent: isTerminalToAgent
        ) {
        case .inheritAll:
            return (runInheritingAllStreams(executable: realExe, args: args), nil)
        case .captureSeparateStdoutAndStderr:
            break
        }

        let captured = runCapturingSeparateStreams(executable: realExe, args: args)
        // Too large to hold / already streamed raw, or the spawn failed: nothing left to do.
        if captured.overflowed || captured.spawnFailed {
            return (captured.exitCode, nil)
        }

        let combined = CommandWrapPolicy.combinedDistillInput(
            stdout: captured.stdout,
            stderr: captured.stderr
        )
        let text = String(data: combined, encoding: .utf8)
        let byteCount = combined.count
        // PERF: `decide` only needs lineCount when the byte gate fails. Multi-MB
        // captures that already clear minBytes must not full-split into Substrings.
        let minBytes = CommandWrapPolicy.minBytes(environment: env)
        let lineCount: Int
        if byteCount > minBytes {
            lineCount = 0
        } else if let text {
            lineCount = Self.lineCount(text, exceeding: CommandWrapPolicy.minLines(environment: env))
        } else {
            lineCount = 0
        }
        let action = CommandWrapPolicy.decide(
            command: command,
            isTerminalToAgent: isTerminalToAgent,
            outputIsValidUTF8: text != nil,
            byteCount: byteCount,
            lineCount: lineCount,
            environment: env
        )

        switch CommandWrapPolicy.capturedDelivery(
            action: action,
            stdout: captured.stdout,
            stderr: captured.stderr
        ) {
        case .passthrough(let stdout, let stderr):
            _ = GuardedStdoutWrite.writeAll(stdout, to: STDOUT_FILENO)
            _ = GuardedStdoutWrite.writeAll(stderr, to: STDERR_FILENO)
            return (captured.exitCode, nil)
        case .distill(let payload):
            let query = CommandWrapPolicy.extractionQuery(forCommand: command)
            let (bytes, deferred) = await compressedOrRaw(payload, query: query, compress: compress)
            let deliveredDeferred = GuardedStdoutWrite.deliveredValue(
                deferred,
                afterWriting: bytes
            )
            return (captured.exitCode, deliveredDeferred)
        }
    }

    /// Compress, but emit the RAW bytes whenever compression failed or returned an implausibly
    /// small result (the distill model occasionally answers with a "NONE"/"PASS" token). The
    /// agent's command output is never replaced by garbage.
    private static func compressedOrRaw(
        _ raw: Data,
        query: String?,
        compress: Compressor
    ) async -> (Data, DeferredSideEffect?) {
        guard let emitted = await compress(raw, query, CommandWrapPolicy.reversibleStoreFloorBytes),
              let text = String(data: emitted.bytes, encoding: .utf8),
              CommandWrapPolicy.isFaithfulCompression(
                  rawByteCount: raw.count,
                  compressedContentByteCount: CommandWrapPolicy.compressedContentByteCount(text)
              )
        else {
            return (raw, nil)
        }
        return (emitted.bytes, emitted.deferredSideEffect)
    }

    /// Line-component count for the wrap size gate (`lineCount > minLines`).
    ///
    /// Empty → 0 (same as prior). Non-empty matches
    /// `split(separator: "\n", omittingEmptySubsequences: false).count`.
    /// PERF: UTF-8 LF scan with early exit once components exceed `threshold`
    /// (no `Array` of `Substring` for medium dumps that failed the byte gate).
    private static func lineCount(_ text: String, exceeding threshold: Int) -> Int {
        if text.isEmpty { return 0 }
        // components = newlines + 1; components > threshold ⇔ newlines >= threshold
        var newlines = 0
        let stopAt = max(1, threshold)
        for byte in text.utf8 where byte == 0x0A {
            newlines += 1
            if newlines >= stopAt { return stopAt + 1 }
        }
        return newlines + 1
    }

    // MARK: - real-binary resolution

    private static func resolveRealExecutable(command: String, environment: [String: String]) -> String? {
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let managedBin = (CommandLine.arguments.first.map { ($0 as NSString).deletingLastPathComponent } ?? "")
        let selfReal = canonicalPath(currentExecutablePath() ?? CommandLine.arguments.first ?? "")
        return CommandWrapPolicy.resolveRealExecutable(
            command: command,
            pathEntries: pathEntries,
            managedBinDirectory: managedBin,
            isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) },
            resolvesToSelf: { candidate in
                guard let selfReal else { return false }
                return canonicalPath(candidate) == selfReal
            }
        )
    }

    private static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - subprocess execution

    private static func runInheritingAllStreams(executable: String, args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        // Leave standardInput/Output/Error unset so the child inherits ours verbatim.
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("\(CommandWrapPolicy.commandBasename(executable)): \(error.localizedDescription)\n".utf8))
            return 126
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private struct CapturedOutput {
        var stdout: Data
        var stderr: Data
        var exitCode: Int32
        var overflowed: Bool
        var spawnFailed: Bool
    }

    /// Independent stdout and stderr pipes. Distill may join the buffers only
    /// after `decide` returns `.compress`. Overflow fail-opens each stream to
    /// its original fd so a pipeline never sees mixed bytes.
    private static func runCapturingSeparateStreams(executable: String, args: [String]) -> CapturedOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("\(CommandWrapPolicy.commandBasename(executable)): \(error.localizedDescription)\n".utf8))
            return CapturedOutput(stdout: Data(), stderr: Data(), exitCode: 126, overflowed: false, spawnFailed: true)
        }

        let box = CaptureBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(
                handle: outPipe.fileHandleForReading,
                box: box,
                isStdout: true
            )
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(
                handle: errPipe.fileHandleForReading,
                box: box,
                isStdout: false
            )
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        box.lock.lock()
        let stdout = box.stdout
        let stderr = box.stderr
        let overflowed = box.overflowed
        box.lock.unlock()
        return CapturedOutput(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus,
            overflowed: overflowed,
            spawnFailed: false
        )
    }

    private final class CaptureBox: @unchecked Sendable {
        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()
        var overflowed = false
    }

    private static func drain(handle: FileHandle, box: CaptureBox, isStdout: Bool) {
        let liveFD: Int32 = isStdout ? STDOUT_FILENO : STDERR_FILENO
        while true {
            let chunk = handle.readData(ofLength: readChunk)
            if chunk.isEmpty { break }
            box.lock.lock()
            if box.overflowed {
                box.lock.unlock()
                _ = GuardedStdoutWrite.writeAll(chunk, to: liveFD)
                continue
            }
            if isStdout {
                box.stdout.append(chunk)
            } else {
                box.stderr.append(chunk)
            }
            if box.stdout.count + box.stderr.count > captureCapBytes {
                box.overflowed = true
                let out = box.stdout
                let err = box.stderr
                box.stdout.removeAll(keepingCapacity: false)
                box.stderr.removeAll(keepingCapacity: false)
                box.lock.unlock()
                _ = GuardedStdoutWrite.writeAll(out, to: STDOUT_FILENO)
                _ = GuardedStdoutWrite.writeAll(err, to: STDERR_FILENO)
                continue
            }
            box.lock.unlock()
        }
    }
}

/// Fail-closed detection of whether this process's stdout flows to the agent (it is the
/// TERMINAL command) versus an intermediate pipeline stage. Validated empirically: a wrapper's
/// output reaches the agent iff an ANCESTOR process holds the READ end of the wrapper's stdout
/// pipe (the agent captures the final stage). Intermediate stages' readers are SIBLING
/// processes, never ancestors, so this never false-positives a mid-pipeline command — the case
/// that would corrupt the downstream command. Handles bash's exec-optimization of single
/// commands (the wrapper's parent becomes the agent itself).
enum WrapPipeInspector {
    static func isTerminalToAgent() -> Bool {
        if let mine = pipeInfo(pid: getpid(), fd: STDOUT_FILENO) {
            let peerHandle = mine.peer
            var current: Int32? = parentPID(of: getpid())
            var hops = 0
            while let pid = current, pid > 1, hops < 12 {
                if pipeHandles(of: pid).contains(peerHandle) { return true }
                current = parentPID(of: pid)
                hops += 1
            }
            return false
        }

        // Claude Code 2.1.x captures a top-level Bash command in a regular
        // `.../claude-<uid>/.../tasks/<id>.output` file. That file is the
        // provider's terminal-to-agent transport, not a user redirect. Pipeline
        // intermediates keep a pipe and therefore cannot enter this branch.
        guard let path = filePath(fd: STDOUT_FILENO) else { return false }
        return CommandWrapPolicy.isClaudeBashCaptureTransport(
            path: path,
            provider: ProcessInfo.processInfo.environment["REMOTE_CODE_AGENT_PROVIDER"],
            userID: getuid()
        )
    }

    private static func filePath(fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }

    private static func pipeInfo(pid: Int32, fd: Int32) -> (handle: UInt64, peer: UInt64)? {
        var info = pipe_fdinfo()
        let size = Int32(MemoryLayout<pipe_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDPIPEINFO, &info, size) == size else { return nil }
        return (info.pipeinfo.pipe_handle, info.pipeinfo.pipe_peerhandle)
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    /// pipe_handle of every pipe FD held by `pid`. Used to find which ancestor reads our stdout.
    private static func pipeHandles(of pid: Int32) -> [UInt64] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, needed)
        guard written > 0 else { return [] }
        var handles: [UInt64] = []
        for fd in fds.prefix(Int(written) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_PIPE) {
            if let info = pipeInfo(pid: pid, fd: fd.proc_fd) { handles.append(info.handle) }
        }
        return handles
    }
}
