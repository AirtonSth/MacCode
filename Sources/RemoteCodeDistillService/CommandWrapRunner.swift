import Darwin
import AgentRuntime
import DistillCore
import Foundation

/// OS-level execution half of the RTK-style transparent command wrappers. The pure
/// decisions (what to wrap, contracts, real-binary resolution) live in
/// `CommandWrapPolicy`; this type runs the real command and detects — fail-closed — whether
/// the wrapper is the TERMINAL command feeding the agent before compressing.
enum CommandWrapRunner {
    /// Optional best-effort work (Wave A ledger POST) that must not delay stdout delivery.
    typealias DeferredSideEffect = @Sendable () async -> Void

    /// Compresses captured stdout (reversible, with the given store floor) using the optional
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
    /// Scoped proof that a child wrapper belongs to one validated mixed shell.
    /// The value is the outer wrapper PID; the child additionally verifies that
    /// PID is its shell parent's parent before treating stdout as terminal.
    private static let segmentedShellEnvironmentKey = "REMOTE_CODE_WRAP_SEGMENTED_SHELL"
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
        // Determine ownership before spawning the real command. A non-terminal wrapper is an
        // intermediate pipeline or a redirected invocation; inheriting both streams preserves
        // the shell's stdout/stderr routing exactly. Capturing first would merge diagnostics
        // into stdout before we discover that the bytes must pass through unchanged.
        let hasAdmittedTokenSaver = WrapPipeInspector.hasAdmittedTokenSaver(environment: env)
        let isTerminalToAgent = WrapPipeInspector.isTerminalToAgent(environment: env)
        if let passthroughReason = CommandWrapPolicy.passthroughReason(
            command: command,
            args: args,
            environment: env
        ) {
            if passthroughReason == "segmented_shell" {
                guard WrapPipeInspector.isTerminalToAgent(
                    environment: env,
                    allowUnownedToolShell: true
                ),
                      let payloadIndex = shellPayloadIndex(in: args),
                      CommandWrapPolicy.boundedSemicolonSegments(args[payloadIndex]) != nil else {
                    // A mixed aggregate is never safe to compress. If we cannot
                    // prove and own each boundary, execute the original shell
                    // once with its streams untouched.
                    return (
                        runInheritingAllStreams(
                            executable: realExe,
                            args: args,
                            markAsParent: hasAdmittedTokenSaver,
                            removingEnvironmentKeys: [segmentedShellEnvironmentKey]
                        ),
                        nil
                    )
                }
                // zsh reads startup files before the `-c` payload. Mark that
                // phase as nested, keep segment ownership out of its environment,
                // then switch markers silently for the validated sequence.
                var scopedArgs = args
                scopedArgs[payloadIndex] = "unset REMOTE_CODE_WRAP_PARENT;export \(segmentedShellEnvironmentKey)=\(getpid());\(args[payloadIndex])"
                return (
                    runInheritingAllStreams(
                        executable: realExe,
                        args: scopedArgs,
                        markAsParent: true,
                        removingEnvironmentKeys: [segmentedShellEnvironmentKey]
                    ),
                    nil
                )
            }
            return (
                runInheritingAllStreams(
                    executable: realExe,
                    args: args,
                    markAsParent: passthroughReason == "explicit_distill_pipeline"
                        || hasAdmittedTokenSaver
                ),
                nil
            )
        }
        if !isTerminalToAgent {
            // A real command can launch another PATH wrapper through a shebang
            // (`npm` -> `/usr/bin/env node`). For an admitted run, keep that
            // nested interpreter raw even though this wrapper is nonterminal.
            return (
                runInheritingAllStreams(
                    executable: realExe,
                    args: args,
                    markAsParent: hasAdmittedTokenSaver
                ),
                nil
            )
        }

        let captured = runCapturingStdout(executable: realExe, args: args)
        // Too large to hold / already streamed raw, or the spawn failed: nothing left to do.
        if captured.overflowed || captured.spawnFailed {
            return (captured.exitCode, nil)
        }

        let text = String(data: captured.stdout, encoding: .utf8)
        let byteCount = captured.stdout.count
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
            args: args,
            isTerminalToAgent: isTerminalToAgent,
            outputIsValidUTF8: text != nil,
            byteCount: byteCount,
            lineCount: lineCount,
            environment: env
        )

        switch action {
        case .passthrough:
            // POSIX write — FileHandle.write raises uncatchable ObjC on closed pipe.
            _ = GuardedStdoutWrite.writeAll(captured.stdout)
            return (captured.exitCode, nil)
        case .compress:
            let query = CommandWrapPolicy.extractionQuery(forCommand: command)
            let (bytes, deferred) = await compressedOrRaw(captured.stdout, query: query, compress: compress)
            // Write stdout first; caller awaits deferred only after this returns.
            let delivered = GuardedStdoutWrite.writeAll(bytes)
            return (
                captured.exitCode,
                GuardedStdoutWrite.deferredSideEffectAfterCompleteDelivery(deferred, delivered: delivered)
            )
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

    private static func shellPayloadIndex(in args: [String]) -> Int? {
        for index in args.indices {
            let argument = args[index]
            guard argument == "-c"
                    || (argument.hasPrefix("-")
                        && !argument.hasPrefix("--")
                        && argument.dropFirst().contains("c")) else {
                continue
            }
            let payloadIndex = args.index(after: index)
            return payloadIndex < args.endIndex ? payloadIndex : nil
        }
        return nil
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

    private static func runInheritingAllStreams(
        executable: String,
        args: [String],
        markAsParent: Bool = false,
        removingEnvironmentKeys: Set<String> = []
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if markAsParent || !removingEnvironmentKeys.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for key in removingEnvironmentKeys {
                environment.removeValue(forKey: key)
            }
            if markAsParent {
                environment["REMOTE_CODE_WRAP_PARENT"] = "1"
            }
            process.environment = environment
        }
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
        var exitCode: Int32
        var overflowed: Bool
        var spawnFailed: Bool
    }

    /// Runs the real command capturing ONLY stdout; stdin and stderr are inherited so the
    /// command reads its real input and its diagnostics reach the agent unchanged. On overflow
    /// the buffered + remaining bytes are streamed straight to our stdout (raw passthrough).
    private static func runCapturingStdout(executable: String, args: [String]) -> CapturedOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["REMOTE_CODE_WRAP_PARENT": "1"],
            uniquingKeysWith: { _, child in child }
        )
        let outPipe = Pipe()
        process.standardOutput = outPipe
        // standardInput / standardError remain inherited (unset).
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("\(CommandWrapPolicy.commandBasename(executable)): \(error.localizedDescription)\n".utf8))
            return CapturedOutput(stdout: Data(), exitCode: 126, overflowed: false, spawnFailed: true)
        }

        let handle = outPipe.fileHandleForReading
        var buffer = Data()
        var overflowed = false
        while true {
            let chunk = handle.readData(ofLength: readChunk)
            if chunk.isEmpty { break }
            if overflowed {
                _ = GuardedStdoutWrite.writeAll(chunk)
                continue
            }
            buffer.append(chunk)
            if buffer.count > captureCapBytes {
                overflowed = true
                _ = GuardedStdoutWrite.writeAll(buffer)
                buffer.removeAll(keepingCapacity: false)
            }
        }
        process.waitUntilExit()
        return CapturedOutput(stdout: buffer, exitCode: process.terminationStatus, overflowed: overflowed, spawnFailed: false)
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
    private static let providerTerminalStdoutKey = "RC_REMOTE_CODE_PROVIDER_TERMINAL_STDOUT"
    private static let unownedToolShellKey = "RC_REMOTE_CODE_UNOWNED_TOOL_SHELL"
    private static let segmentedShellEnvironmentKey = "REMOTE_CODE_WRAP_SEGMENTED_SHELL"

    /// A wrapper is allowed to capture only for a host-admitted Token Saver run.
    /// Provider brokers commonly expose the final stdout as a pipe whose reader is
    /// outside the wrapper's process ancestry; ordinary shell pipelines keep their
    /// reader below the launching shell. Keep those cases distinct.
    static func isTerminalToAgent(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowUnownedToolShell: Bool = false
    ) -> Bool {
        guard hasAdmittedTokenSaver(environment: environment) else { return false }

        // A validated mixed shell exports its outer wrapper PID at the start of
        // its `-c` payload, after startup files have run. Only a direct child
        // wrapper whose shell parent belongs to that exact outer wrapper may
        // own one ordinary segment.
        if segmentedShellOwnsChild(environment: environment) {
            return true
        }

        // Codex resolves its tool shell independently of PATH and can
        // exec-optimize the final child, erasing the shell argv before a child
        // wrapper can inspect it. The host therefore labels this shell as
        // unowned. Only the validated aggregate marker above can transfer
        // selective ownership to a child; otherwise every auto-wrapper fails
        // open and an explicit `| distill` remains the compression boundary.
        if environment[unownedToolShellKey] == "1" && !allowUnownedToolShell {
            return false
        }

        guard let mine = pipeInfo(pid: getpid(), fd: 1) else {
            // A provider PTY is the only non-pipe terminal route we recognize. A
            // user's own terminal without the host admission above remains raw.
            return isatty(STDOUT_FILENO) == 1 || providerTerminalFallback(environment: environment)
        }

        let peerHandle = mine.peer
        var current: Int32? = parentPID(of: getpid())
        var hops = 0
        while let pid = current, pid > 1, hops < 12 {
            if pipeHandles(of: pid).contains(peerHandle) { return true }
            current = parentPID(of: pid)
            hops += 1
        }

        // The provider's broker may own the read end from a process outside this
        // ancestry. A pipeline reader is a descendant of the launching shell. The
        // distinction is deliberately used only after admission, and only when a
        // process actually owns the peer end of this exact pipe.
        let launchingParent = parentPID(of: getpid())
        let parentIsShell = launchingParent.map(isShellProcess) ?? false
        let hasExternalReader = peerOwners(of: peerHandle).contains { owner in
            guard parentIsShell, let launchingParent else { return true }
            return !isDescendant(owner, of: launchingParent)
        }
        return hasExternalReader || providerTerminalFallback(environment: environment)
    }

    private static func segmentedShellOwnsChild(environment: [String: String]) -> Bool {
        guard let raw = environment[segmentedShellEnvironmentKey],
              let wrapperPID = Int32(raw), wrapperPID > 1,
              let parent = parentPID(of: getpid()),
              isManagedShellWrapper(wrapperPID) else {
            return false
        }
        // zsh may exec-optimize the final simple command, in which case the
        // child wrapper's parent is the outer wrapper directly.
        return parent == wrapperPID
            || (isShellProcess(parent) && parentPID(of: parent) == wrapperPID)
    }

    /// The aggregate marker is accepted only from another instance of this
    /// exact service binary invoked through a managed shell symlink. A PID
    /// relationship alone is forgeable (`export marker=$PPID`) inside an
    /// admitted tool shell and must never transfer compression ownership.
    private static func isManagedShellWrapper(_ pid: Int32) -> Bool {
        guard executablePath(of: pid) == executablePath(of: getpid()),
              let argumentZero = processArgumentZero(of: pid) else {
            return false
        }
        return ["sh", "bash", "zsh", "dash", "fish"].contains(
            (argumentZero as NSString).lastPathComponent
        )
    }

    private static func executablePath(of pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path)
    }

    private static func processArgumentZero(of pid: Int32) -> String? {
        var name = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
        var required = 0
        guard sysctl(&name, UInt32(name.count), nil, &required, nil, 0) == 0,
              required >= MemoryLayout<Int32>.size,
              required <= 1024 * 1024 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: required)
        guard bytes.withUnsafeMutableBytes({ buffer in
            sysctl(&name, UInt32(name.count), buffer.baseAddress, &required, nil, 0)
        }) == 0 else {
            return nil
        }

        var index = MemoryLayout<Int32>.size
        while index < required, bytes[index] != 0 { index += 1 }
        while index < required, bytes[index] == 0 { index += 1 }
        let start = index
        while index < required, bytes[index] != 0 { index += 1 }
        guard index > start else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    /// Codex may expose the final tool stream as a socket, which has no pipe
    /// peer handle to prove ownership. A single bare command is exec-optimized
    /// by the shell, so its parent is the provider broker; a pipeline stage
    /// retains the launching shell as its parent. The host-issued marker is
    /// considered only after full receipt/scope admission above.
    private static func providerTerminalFallback(environment: [String: String]) -> Bool {
        guard environment[providerTerminalStdoutKey] == "1",
              let parent = parentPID(of: getpid()) else { return false }
        return !isShellProcess(parent)
    }

    static func hasAdmittedTokenSaver(environment: [String: String]) -> Bool {
        // The hint is descriptive prompt/runtime state, not an admission proof.
        // Only the host-issued, structurally validated receipt can authorize
        // wrapper capture; managed PATH and a forged hint must remain raw.
        guard let receipt = TokenSaverExecutionReceiptSeam.receipt(from: environment) else {
            return false
        }
        return receipt.admitted
            && receipt.sameUser
            && receipt.capabilities.distill == true
            && receipt.capabilities.managedPath == true
            && hasCompleteScope(environment: environment, receipt: receipt)
    }

    private static func hasCompleteScope(
        environment: [String: String],
        receipt: TokenSaverExecutionReceipt
    ) -> Bool {
        let required = [
            "RC_TOKEN_SAVER_WORKSPACE_ID",
            "RC_TOKEN_SAVER_PROJECT_ID",
            "RC_TOKEN_SAVER_THREAD_ID",
            "RC_TOKEN_SAVER_ATTEMPT_ID",
            "REMOTE_CODE_AGENT_PROVIDER",
        ]
        guard required.allSatisfy({
            guard let value = environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return false }
            return true
        }) else { return false }
        return receipt.provider == environment["REMOTE_CODE_AGENT_PROVIDER"]
            && receipt.threadId == environment["RC_TOKEN_SAVER_THREAD_ID"]
            && receipt.workspaceId == environment["RC_TOKEN_SAVER_WORKSPACE_ID"]
            && receipt.projectId == environment["RC_TOKEN_SAVER_PROJECT_ID"]
            && receipt.attemptId == environment["RC_TOKEN_SAVER_ATTEMPT_ID"]
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

    private static func peerOwners(of peerHandle: UInt64) -> [Int32] {
        let required = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard required > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(required) / MemoryLayout<Int32>.size)
        let written = pids.withUnsafeMutableBytes { rawBuffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                rawBuffer.baseAddress,
                Int32(rawBuffer.count)
            )
        }
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<Int32>.size).compactMap { pid in
            pipeHandles(of: pid).contains(peerHandle) ? pid : nil
        }
    }

    private static func isDescendant(_ pid: Int32, of ancestor: Int32) -> Bool {
        var current: Int32? = pid
        var hops = 0
        while let value = current, value > 1, hops < 32 {
            if value == ancestor { return true }
            current = parentPID(of: value)
            hops += 1
        }
        return false
    }

    private static func isShellProcess(_ pid: Int32) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let executable = String(cString: path)
        let basename = (executable as NSString).lastPathComponent
        return ["sh", "bash", "zsh", "dash", "fish"].contains(basename)
    }
}
