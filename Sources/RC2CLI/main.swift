import Foundation
import Darwin
import CoreModel
import Persistence

let args = CommandLine.arguments
let prog = (args.first as NSString?)?.lastPathComponent ?? "remotecode"

func usage(_ exit: Int32 = 0) -> Never {
    let text = """
    Usage: \(prog) [--socket PATH] [--json] [--timeout MS] <command> [args...]
      --timeout MS defaults to \(RC2CLITimeoutParser.defaultReceiveTimeoutMS) for one-shot RPCs

    Commands:
      ping
      capabilities
      workspaces             list workspaces
      new-workspace --cwd PATH --name NAME
      new-surface --workspace WID --type terminal|browser|agent|markdown|filepreview|rightsidebartool [--title T]
      new-split  --workspace WID --pane PID --direction right|down|left|up --type ...
      focus --workspace WID --id SID
      close --workspace WID --id SID
      send-text --id SID --text "..."
      send-key --id SID --key KEY
      read-text --id SID
      clear-history --id SID
      health --id SID
      surface move --workspace WID --id SID --target-pane PID
      surface reorder --workspace WID --id SID --target-pane PID [--position N]
      pane list --workspace WID
      pane swap --workspace WID --a PID --b PID
      pane resize --workspace WID --split SPLIT_ID --ratios "0.3,0.7"
      window list / window current / window create [--title T] / window focus --id WID / window close --id WID
      workspace move-to-window --workspace WID --window WIDX
      events recent / events stream [--after-seq N]
      notification create [--workspace WID] --title T [--body B] [--category C]
      notification list [--workspace WID] [--unread]
      notification mark-read --id N / notification dismiss --id N
      browser navigate --id SID --url URL / browser back/forward/reload/url --id SID
      browser snapshot --id SID
      browser click/focus/hover/check/uncheck --id SID --ref REF
      browser fill/type/select --id SID --ref REF --value V
      browser wait --id SID --selector CSS [--timeout MS]
      browser screenshot --id SID [--path PATH]
      browser eval --id SID --script JS
      agent open --workspace WID
      agent thread list [--workspace WID]
      agent thread create [--workspace WID] [--title T] [--provider distill] [--model M]
      agent send --thread TID --text "..." [--provider ...] [--model ...]
      agent stop --thread TID
      agent models --provider distill
      agent-app codex|claude|grok [PROMPT] [--prompt-file PATH] [--workspace WID]
                [--model M] [--permission MODE] [--reasoning-effort LEVEL]
    """
    FileHandle.standardError.write(Data(text.utf8))
    Darwin.exit(exit)
}

/// Write a specific diagnostic to stderr then show usage and exit.
///
/// WHY: every guard failure in this file must tell the user WHICH flag or
/// argument was missing/invalid, not just dump a generic usage block.
/// The reason line is written to stderr first so it is visible even when
/// usage output is long.
func diagError(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("\(reason)\n".utf8))
    usage(RC2ExitCode.usageError)
}

// Parse --timeout before the global flag loop so it is available when RPC is
// constructed. The parser strips the token(s) and returns the cleaned list.
let _timeoutResult = RC2CLITimeoutParser.parseLeadingGlobal(Array(args.dropFirst()))
if _timeoutResult.invalidValue != nil {
    diagError(RC2CLIDiagnostics.invalidValue(for: "timeout"))
}
var receiveTimeoutMS: Int? = _timeoutResult.timeoutMS ?? RC2CLITimeoutParser.defaultReceiveTimeoutMS
// Reconstructed args with --timeout removed; the loop below indexes from 1 so
// we prepend a placeholder for the program name slot.
let _cleanedArgs: [String] = [args.first ?? ""] + _timeoutResult.remaining

func parseFlags(_ a: [String]) -> ([String: String], [String]) {
    CLIArgParser.parseFlagsWithTerminator(a)
}

let envChannel = ProcessInfo.processInfo.environment["RC2_CHANNEL"] ?? "debug"
let releaseChannel = ReleaseChannel(rawValue: envChannel) ?? .debug
var socketPath = AppPaths.socketPath(for: releaseChannel)
var jsonOutput = false

// Per-subcommand help strings for undocumented and advanced commands.
let subcommandHelp: [String: String] = [
    "ping":           "Usage: \(prog) ping\n\n  Send a liveness ping to the MacCode daemon.",
    "capabilities":   "Usage: \(prog) capabilities\n\n  List daemon capabilities.",
    "workspaces":     "Usage: \(prog) workspaces\n\n  List all open workspaces.",
    "new-workspace":  "Usage: \(prog) new-workspace --cwd PATH [--name NAME]\n\n  Create a new workspace at PATH.",
    "new-surface":    "Usage: \(prog) new-surface --workspace WID --type TYPE [--title T]\n\n  Types: terminal browser agent markdown filepreview rightsidebartool",
    "new-split":      "Usage: \(prog) new-split --workspace WID --pane PID --direction DIR --type TYPE\n\n  Directions: right down left up",
    "focus":          "Usage: \(prog) focus --workspace WID --id SID\n\n  Focus a surface.",
    "close":          "Usage: \(prog) close --workspace WID --id SID\n\n  Close a surface.",
    "send-text":      "Usage: \(prog) send-text --id SID --text TEXT\n\n  Send text to a terminal surface.\n  Use --text=TEXT to pass values that start with -.",
    "send-key":       "Usage: \(prog) send-key --id SID --key KEY\n\n  Send a key event to a surface.",
    "read-text":      "Usage: \(prog) read-text --id SID\n\n  Read terminal output from a surface.",
    "clear-history":  "Usage: \(prog) clear-history --id SID\n\n  Clear the scrollback history of a surface.",
    "health":         "Usage: \(prog) health --id SID\n\n  Get health status of a surface.",
    "surface":        "Usage: \(prog) surface <subcommand> [args...]\n\n  Subcommands: move reorder",
    "pane":           "Usage: \(prog) pane <subcommand> [args...]\n\n  Subcommands: list swap resize",
    "window":         "Usage: \(prog) window <subcommand> [args...]\n\n  Subcommands: list current create focus close",
    "workspace":      "Usage: \(prog) workspace move-to-window --workspace WID --window WIDX",
    "events":         "Usage: \(prog) events <subcommand> [args...]\n\n  Subcommands:\n    recent           Print recent events\n    stream [--after-seq N]  Stream events in real-time (NDJSON)",
    "notification":   "Usage: \(prog) notification <subcommand> [args...]\n\n  Subcommands: create list mark-read dismiss",
    "browser":        "Usage: \(prog) browser <subcommand> [args...]\n\n  Subcommands: navigate back forward reload url snapshot click focus hover check uncheck fill type select wait screenshot eval",
    "agent":          "Usage: \(prog) agent <subcommand> [args...]\n\n  Subcommands:\n    open --workspace WID\n    thread list [--workspace WID]\n    thread create [--workspace WID] [--title T] [--provider distill] [--model M]\n    send --thread TID --text TEXT [--provider P] [--model M]\n    stop --thread TID\n    models [--provider distill]",
    "agent-app":      "Usage: \(prog) agent-app <codex|claude|grok> [PROMPT] [--prompt-file PATH] [--workspace WID] [--model M] [--permission supervised|auto_accept_edits|full_access] [--reasoning-effort LEVEL] [--turn-timeout MS] [--output-format text|json|grok-json]\n\n  Runs a persisted headless turn through the same Agent App pipeline as the UI. Runtime profiles are reserved for MacCode's managed provider bridge.",
]

var rest: [String] = []
var globalTerminated = false
var i = 1
while i < _cleanedArgs.count {
    let s = _cleanedArgs[i]
    if globalTerminated || !rest.isEmpty { rest.append(s); i += 1; continue }
    if s == "--" { globalTerminated = true; i += 1; continue }
    if s == "--version" {
        print(RC2CLIVersion.versionString())
        Darwin.exit(0)
    }
    if s == "--socket", i + 1 < _cleanedArgs.count { socketPath = _cleanedArgs[i+1]; i += 2; continue }
    if s == "--json" { jsonOutput = true; i += 1; continue }
    if s == "--help" || s == "-h" { usage(0) }
    rest.append(s); i += 1
}
// Check for per-subcommand help: rc2 <cmd> --help
if rest.count >= 2 && (rest[1] == "--help" || rest[1] == "-h") {
    let cmdName = rest[0]
    if let helpText = subcommandHelp[cmdName] {
        print(helpText)
        Darwin.exit(0)
    }
    usage(0)
}
if rest.isEmpty { usage(RC2ExitCode.usageError) }

struct RPC {
    let socketPath: String
    /// When non-nil, SO_RCVTIMEO is applied to the socket so a read cannot
    /// block longer than this many milliseconds.
    let receiveTimeoutMS: Int?

    func call(_ method: String, params: [String: Any]) -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            return ["error": [
                "code": -1,
                "message": "socket(): \(String(cString: strerror(errno)))",
                "_mutation_delivery": "definite"
            ]]
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = socketPath.utf8CString
        if bytes.count > maxPath {
            return ["error": [
                "code": -1,
                "message": "socket path too long",
                "_mutation_delivery": "definite"
            ]]
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tp in
            tp.withMemoryRebound(to: CChar.self, capacity: maxPath) { tbase in
                bytes.withUnsafeBufferPointer { src in
                    for i in 0..<src.count { tbase[i] = src[i] }
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let conn = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, addrLen)
            }
        }
        if conn < 0 {
            let msg = String(cString: strerror(errno))
            close(fd)
            let channelHint = envChannel != "stable"
                ? " (tip: set RC2_CHANNEL=stable if using the App Store build)"
                : ""
            return ["error": [
                "code": -1,
                "message": "connect(\(socketPath)): \(msg). Is the MacCode app running?\(channelHint)",
                "_connect_failure": true,
                "_mutation_delivery": "definite"
            ]]
        }
        // Apply receive timeout when requested via --timeout MS.
        if let ms = receiveTimeoutMS {
            let sec  = ms / 1000
            let usec = (ms % 1000) * 1000
            var tv = timeval(tv_sec: sec, tv_usec: Int32(usec))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        defer { close(fd) }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...1_000_000),
            "method": method,
            "params": params
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return ["error": [
                "code": -1,
                "message": "serialize failed",
                "_mutation_delivery": "definite"
            ]]
        }
        data.append(0x0A)
        let writeResult = RC2CLIWriteLoop.writeAll(fd: fd, data: data)
        if !writeResult.success {
            return ["error": [
                "code": -1,
                "message": "write failed",
                "_mutation_delivery": "ambiguous"
            ]]
        }
        // read until newline
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n == 0 {
                return ["error": [
                    "code": -1,
                    "message": RC2CLIDiagnostics.responseClosedBeforeReply(),
                    "_mutation_delivery": "ambiguous"
                ]]
            }
            if n < 0 {
                if (errno == EAGAIN || errno == EWOULDBLOCK), let receiveTimeoutMS {
                    return ["error": [
                        "code": -1,
                        "message": RC2CLIDiagnostics.responseTimedOut(afterMilliseconds: receiveTimeoutMS),
                        "_mutation_delivery": "ambiguous"
                    ]]
                }
                return ["error": [
                    "code": -1,
                    "message": "read failed: \(String(cString: strerror(errno)))",
                    "_mutation_delivery": "ambiguous"
                ]]
            }
            buf.append(tmp, count: n)
            if buf.last == 0x0A { break }
        }
        guard let any = try? JSONSerialization.jsonObject(with: buf) as? [String: Any] else {
            return ["error": [
                "code": -1,
                "message": "decode failed: \(String(data: buf, encoding: .utf8) ?? "")",
                "_mutation_delivery": "ambiguous"
            ]]
        }
        return any
    }
}

// Ignore SIGPIPE so a server-side close between connect and write does not
// kill the process via the default signal handler.  Without this, any write
// to a half-closed socket delivers SIGPIPE and terminates the process before
// the caller can handle the error.
signal(SIGPIPE, SIG_IGN)

if _timeoutResult.timeoutMS == nil, rest.first == "agent-app" {
    let (agentAppFlags, _) = parseFlags(Array(rest.dropFirst()))
    let turnTimeoutMS = Int(agentAppFlags["turn-timeout"] ?? "3600000") ?? 3_600_000
    if turnTimeoutMS > 0 {
        receiveTimeoutMS = AgentAppMiddlewareTimeoutPolicy.receiveTimeoutMS(
            explicitGlobalTimeoutMS: nil,
            turnTimeoutMS: turnTimeoutMS
        )
    }
}
let rpc = RPC(socketPath: socketPath, receiveTimeoutMS: receiveTimeoutMS)

enum AgentAppCLIError: Error, LocalizedError, AgentAppMiddlewareSendFailure {
    case rpc(String, AgentAppMiddlewareSendFailureDisposition)
    case invalidResponse
    case invalidPromptFile(String)

    var agentAppMiddlewareSendFailureDisposition: AgentAppMiddlewareSendFailureDisposition {
        switch self {
        case .rpc(_, let disposition): return disposition
        case .invalidResponse: return .ambiguous
        case .invalidPromptFile: return .definite
        }
    }

    var errorDescription: String? {
        switch self {
        case .rpc(let message, _): return message
        case .invalidResponse: return "MacCode returned an invalid RPC response."
        case .invalidPromptFile(let path): return "Could not read --prompt-file \(path)."
        }
    }
}

func agentAppRPCValue(_ any: Any) -> AgentAppRPCValue? {
    switch any {
    case let value as String:
        return .string(value)
    case let value as NSNumber:
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return .bool(value.boolValue)
        }
        return .number(value.doubleValue)
    case let value as [String: Any]:
        var object: [String: AgentAppRPCValue] = [:]
        for (key, child) in value {
            guard let converted = agentAppRPCValue(child) else { return nil }
            object[key] = converted
        }
        return .object(object)
    case let value as [Any]:
        let converted = value.compactMap(agentAppRPCValue)
        guard converted.count == value.count else { return nil }
        return .array(converted)
    case _ as NSNull:
        return .null
    default:
        return nil
    }
}

func callAgentAppRPC(_ method: String, params: [String: AgentAppRPCValue]) throws -> AgentAppRPCValue {
    func foundationValue(_ value: AgentAppRPCValue) -> Any {
        switch value {
        case .string(let string): return string
        case .number(let number): return number
        case .bool(let bool): return bool
        case .object(let object): return object.mapValues(foundationValue)
        case .array(let array): return array.map(foundationValue)
        case .null: return NSNull()
        }
    }
    let response = rpc.call(method, params: params.mapValues(foundationValue))
    if let error = response["error"] as? [String: Any] {
        let code = (error["code"] as? NSNumber)?.intValue
        let definitelyNotAccepted = error["_mutation_delivery"] as? String == "definite"
            || (code.map { $0 != -1 } ?? false)
        throw AgentAppCLIError.rpc(
            error["message"] as? String ?? "MacCode RPC \(method) failed.",
            definitelyNotAccepted ? .definite : .ambiguous
        )
    }
    guard let result = response["result"],
          let converted = agentAppRPCValue(result) else {
        throw AgentAppCLIError.invalidResponse
    }
    return converted
}

func emitAgentAppOutput(_ output: AgentAppMiddlewareOutput, format: String) -> Never {
    switch format {
    case "json", "grok-json":
        var object: [String: Any] = [
            "text": output.response,
            "thread_id": output.threadID
        ]
        if let runID = output.runID { object["run_id"] = runID }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data ?? Data("{\"text\":\"\"}".utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
    default:
        print(output.response)
    }
    Darwin.exit(RC2ExitCode.success)
}

func emit(_ obj: Any) {
    if jsonOutput {
        // Determine exit code before stripping internal metadata.
        var isConnect = false
        if let dict = obj as? [String: Any],
           let errDict = dict["error"] as? [String: Any] {
            isConnect = (errDict["_connect_failure"] as? Bool) == true
        }
        let code = RC2ExitCode.exitCode(for: (obj as? [String: Any]) ?? [:], isConnect: isConnect)

        // Strip internal-only keys before serialising to the caller.
        var cleaned = obj
        if var dict = obj as? [String: Any],
           var errDict = dict["error"] as? [String: Any] {
            errDict.removeValue(forKey: "_connect_failure")
            errDict.removeValue(forKey: "_mutation_delivery")
            dict["error"] = errDict
            cleaned = dict
        }

        if let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .fragmentsAllowed]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
        if code != RC2ExitCode.success { Darwin.exit(code) }
    } else {
        if let dict = obj as? [String: Any], let err = dict["error"] as? [String: Any] {
            FileHandle.standardError.write(Data("error: \(err["message"] ?? "")\n".utf8))
            let isConnect = (err["_connect_failure"] as? Bool) == true
            Darwin.exit(isConnect ? RC2ExitCode.connectFailure : RC2ExitCode.rpcError)
        }
        if let dict = obj as? [String: Any], let result = dict["result"] {
            print(prettyPrint(result))
        } else {
            print("\(obj)")
        }
    }
}

func prettyPrint(_ any: Any, indent: Int = 0) -> String {
    let pad = String(repeating: "  ", count: indent)
    if let s = any as? String { return s }
    if let n = any as? NSNumber { return n.stringValue }
    if let arr = any as? [Any] {
        return arr.map { pad + prettyPrint($0, indent: indent + 1) }.joined(separator: "\n")
    }
    if let dict = any as? [String: Any] {
        return dict.map { k, v in "\(pad)\(k): \(prettyPrint(v, indent: indent + 1))" }.joined(separator: "\n")
    }
    return "\(any)"
}

let cmd = rest[0]
let restArgs = Array(rest.dropFirst())

switch cmd {
case "ping":
    emit(rpc.call("system.ping", params: [:]))
case "capabilities":
    emit(rpc.call("system.capabilities", params: [:]))
case "workspaces":
    emit(rpc.call("workspace.list", params: [:]))
case "new-workspace":
    let (flags, _) = parseFlags(restArgs)
    let cwd = flags["cwd"] ?? FileManager.default.currentDirectoryPath
    let name = flags["name"] ?? (cwd as NSString).lastPathComponent
    emit(rpc.call("workspace.create", params: ["name": name, "cwd": cwd]))
case "new-surface":
    let (flags, _) = parseFlags(restArgs)
    guard let wid = flags["workspace"] else { diagError(RC2CLIDiagnostics.missingFlag("workspace")) }
    guard let type = flags["type"] else { diagError(RC2CLIDiagnostics.missingFlag("type")) }
    var p: [String: Any] = ["workspace_id": wid, "type": type]
    if let t = flags["title"] { p["title"] = t }
    emit(rpc.call("surface.create", params: p))
case "new-split":
    let (flags, _) = parseFlags(restArgs)
    guard let wid = flags["workspace"] else { diagError(RC2CLIDiagnostics.missingFlag("workspace")) }
    guard let pid = flags["pane"] else { diagError(RC2CLIDiagnostics.missingFlag("pane")) }
    guard let dir = flags["direction"] else { diagError(RC2CLIDiagnostics.missingFlag("direction")) }
    guard let type = flags["type"] else { diagError(RC2CLIDiagnostics.missingFlag("type")) }
    emit(rpc.call("surface.split", params: ["workspace_id": wid, "pane_id": pid, "direction": dir, "type": type]))
case "focus":
    let (flags, _) = parseFlags(restArgs)
    guard let wid = flags["workspace"] else { diagError(RC2CLIDiagnostics.missingFlag("workspace")) }
    guard let sid = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
    emit(rpc.call("surface.focus", params: ["workspace_id": wid, "id": sid]))
case "close":
    let (flags, _) = parseFlags(restArgs)
    guard let wid = flags["workspace"] else { diagError(RC2CLIDiagnostics.missingFlag("workspace")) }
    guard let sid = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
    emit(rpc.call("surface.close", params: ["workspace_id": wid, "id": sid]))
case "send-text":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
    guard let text = flags["text"] else { diagError(RC2CLIDiagnostics.missingFlag("text")) }
    emit(rpc.call("surface.send_text", params: ["id": sid, "text": text]))
case "send-key":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
    guard let key = flags["key"] else { diagError(RC2CLIDiagnostics.missingFlag("key")) }
    emit(rpc.call("surface.send_key", params: ["id": sid, "key": key]))
case "clear-history":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
    emit(rpc.call("surface.clear_history", params: ["id": sid]))
case "health":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
    emit(rpc.call("surface.health", params: ["id": sid]))
case "read-text":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
    emit(rpc.call("surface.read_text", params: ["id": sid]))
case "surface":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let (flags, _) = parseFlags(Array(restArgs.dropFirst()))
    switch sub {
    case "move":
        guard let w = flags["workspace"] else { diagError(RC2CLIDiagnostics.missingFlag("workspace")) }
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        guard let target = flags["target-pane"] else { diagError(RC2CLIDiagnostics.missingFlag("target-pane")) }
        emit(rpc.call("surface.move", params: ["workspace_id": w, "id": id, "target_pane_id": target]))
    case "reorder":
        guard let w = flags["workspace"] else { diagError(RC2CLIDiagnostics.missingFlag("workspace")) }
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        guard let target = flags["target-pane"] else { diagError(RC2CLIDiagnostics.missingFlag("target-pane")) }
        let pos = Int(flags["position"] ?? "0") ?? 0
        emit(rpc.call("surface.reorder", params: ["workspace_id": w, "id": id, "target_pane_id": target, "position": pos]))
    default: diagError(RC2CLIDiagnostics.unknownSubcommand(sub, of: "surface"))
    }
case "pane":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let (flags, _) = parseFlags(Array(restArgs.dropFirst()))
    switch sub {
    case "list":
        guard let w = flags["workspace"] else { diagError(RC2CLIDiagnostics.missingFlag("workspace")) }
        emit(rpc.call("pane.list", params: ["workspace_id": w]))
    case "swap":
        guard let w = flags["workspace"] else { diagError(RC2CLIDiagnostics.missingFlag("workspace")) }
        guard let a = flags["a"] else { diagError(RC2CLIDiagnostics.missingFlag("a")) }
        guard let b = flags["b"] else { diagError(RC2CLIDiagnostics.missingFlag("b")) }
        emit(rpc.call("pane.swap", params: ["workspace_id": w, "a": a, "b": b]))
    case "resize":
        guard let w = flags["workspace"] else { diagError(RC2CLIDiagnostics.missingFlag("workspace")) }
        guard let s = flags["split"] else { diagError(RC2CLIDiagnostics.missingFlag("split")) }
        guard let r = flags["ratios"] else { diagError(RC2CLIDiagnostics.missingFlag("ratios")) }
        let ratios = r.split(separator: ",").compactMap { Double($0) }
        emit(rpc.call("pane.resize", params: ["workspace_id": w, "split_id": s, "ratios": ratios]))
    default: diagError(RC2CLIDiagnostics.unknownSubcommand(sub, of: "pane"))
    }
case "window":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let (flags, _) = parseFlags(Array(restArgs.dropFirst()))
    switch sub {
    case "list":    emit(rpc.call("window.list", params: [:]))
    case "current": emit(rpc.call("window.current", params: [:]))
    case "create":
        var p: [String: Any] = [:]; if let t = flags["title"] { p["title"] = t }
        emit(rpc.call("window.create", params: p))
    case "focus":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        emit(rpc.call("window.focus", params: ["id": id]))
    case "close":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        emit(rpc.call("window.close", params: ["id": id]))
    default: diagError(RC2CLIDiagnostics.unknownSubcommand(sub, of: "window"))
    }
case "events":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    switch sub {
    case "recent": emit(rpc.call("events.recent", params: [:]))
    case "stream":
        let (flags, _) = parseFlags(Array(restArgs.dropFirst()))
        let afterSeq = Int(flags["after-seq"] ?? "0") ?? 0
        // Open a dedicated socket and enter long-lived NDJSON follow mode.
        // Each server-pushed JSONRPCResponse arrives as one '\n'-terminated
        // JSON line; we forward it verbatim to stdout so callers can pipe
        // through `jq` or any NDJSON consumer.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            FileHandle.standardError.write(Data("error: socket(): \(String(cString: strerror(errno)))\n".utf8))
            Darwin.exit(1)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let spBytes = socketPath.utf8CString
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        if spBytes.count > maxPath {
            FileHandle.standardError.write(Data("error: socket path too long\n".utf8))
            Darwin.exit(1)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tp in
            tp.withMemoryRebound(to: CChar.self, capacity: maxPath) { base in
                spBytes.withUnsafeBufferPointer { src in
                    for i in 0..<src.count { base[i] = src[i] }
                }
            }
        }
        let connResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connResult < 0 {
            let msg = String(cString: strerror(errno))
            FileHandle.standardError.write(Data("error: connect(\(socketPath)): \(msg). Is the MacCode app running?\n".utf8))
            Darwin.close(fd)
            Darwin.exit(RC2ExitCode.connectFailure)
        }
        // Send events.stream request.
        let streamReqDict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "events.stream",
            "method": "events.stream",
            "params": ["after_seq": afterSeq]
        ]
        guard var reqData = try? JSONSerialization.data(withJSONObject: streamReqDict, options: []) else {
            Darwin.close(fd); Darwin.exit(1)
        }
        reqData.append(0x0A)
        reqData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < reqData.count {
                let n = Darwin.write(fd, base.advanced(by: written), reqData.count - written)
                if n <= 0 { return }
                written += n
            }
        }
        // Read NDJSON lines forever; SIGINT / pipe-close terminates the loop.
        var lineBuf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            lineBuf.append(chunk, count: n)
            while let nlIdx = lineBuf.firstIndex(of: 0x0A) {
                let line = lineBuf.subdata(in: lineBuf.startIndex..<lineBuf.index(after: nlIdx)) // includes \n
                lineBuf.removeSubrange(lineBuf.startIndex...nlIdx)
                FileHandle.standardOutput.write(line)
            }
        }
        Darwin.close(fd)
        Darwin.exit(0)
    default: diagError(RC2CLIDiagnostics.unknownSubcommand(sub, of: "events"))
    }
case "notification":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let (flags, _) = parseFlags(Array(restArgs.dropFirst()))
    switch sub {
    case "create":
        var p: [String: Any] = ["title": flags["title"] ?? "Notification"]
        if let w = flags["workspace"] { p["workspace_id"] = w }
        if let b = flags["body"] { p["body"] = b }
        if let c = flags["category"] { p["category"] = c }
        emit(rpc.call("notification.create", params: p))
    case "list":
        var p: [String: Any] = [:]; if let w = flags["workspace"] { p["workspace_id"] = w }
        if flags["unread"] != nil { p["unread_only"] = true }
        emit(rpc.call("notification.list", params: p))
    case "mark-read":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        emit(rpc.call("notification.mark_read", params: ["id": id]))
    case "dismiss":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        emit(rpc.call("notification.dismiss", params: ["id": id]))
    default: diagError(RC2CLIDiagnostics.unknownSubcommand(sub, of: "notification"))
    }
case "browser":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let (flags, _) = parseFlags(Array(restArgs.dropFirst()))
    switch sub {
    case "navigate":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        guard let url = flags["url"] else { diagError(RC2CLIDiagnostics.missingFlag("url")) }
        emit(rpc.call("browser.navigate", params: ["id": id, "url": url]))
    case "back", "forward", "reload", "url":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        emit(rpc.call("browser." + (sub == "url" ? "url.get" : sub), params: ["id": id]))
    case "snapshot":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        emit(rpc.call("browser.snapshot", params: ["id": id]))
    case "click", "focus", "hover", "check", "uncheck":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        guard let ref = flags["ref"] else { diagError(RC2CLIDiagnostics.missingFlag("ref")) }
        emit(rpc.call("browser." + sub, params: ["id": id, "ref": ref]))
    case "fill", "type", "select":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        guard let ref = flags["ref"] else { diagError(RC2CLIDiagnostics.missingFlag("ref")) }
        guard let val = flags["value"] else { diagError(RC2CLIDiagnostics.missingFlag("value")) }
        emit(rpc.call("browser." + sub, params: ["id": id, "ref": ref, "value": val]))
    case "wait":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        guard let sel = flags["selector"] else { diagError(RC2CLIDiagnostics.missingFlag("selector")) }
        let t = Int(flags["timeout"] ?? "5000") ?? 5000
        emit(rpc.call("browser.wait", params: ["id": id, "selector": sel, "timeout_ms": t]))
    case "screenshot":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        var p: [String: Any] = ["id": id]
        if let path = flags["path"] { p["path"] = path }
        emit(rpc.call("browser.screenshot", params: p))
    case "eval":
        guard let id = flags["id"] else { diagError(RC2CLIDiagnostics.missingFlag("id")) }
        guard let script = flags["script"] else { diagError(RC2CLIDiagnostics.missingFlag("script")) }
        emit(rpc.call("browser.eval", params: ["id": id, "script": script]))
    default: diagError(RC2CLIDiagnostics.unknownSubcommand(sub, of: "browser"))
    }
case "workspace":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let (flags, _) = parseFlags(Array(restArgs.dropFirst()))
    switch sub {
    case "move-to-window":
        guard let w = flags["workspace"] else { diagError(RC2CLIDiagnostics.missingFlag("workspace")) }
        guard let win = flags["window"] else { diagError(RC2CLIDiagnostics.missingFlag("window")) }
        emit(rpc.call("workspace.move_to_window", params: ["workspace_id": w, "window_id": win]))
    default: diagError(RC2CLIDiagnostics.unknownSubcommand(sub, of: "workspace"))
    }
case "agent":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let rest2 = Array(restArgs.dropFirst())
    switch sub {
    case "open":
        let (flags, _) = parseFlags(rest2)
        guard let wid = flags["workspace"] else { diagError(RC2CLIDiagnostics.missingFlag("workspace")) }
        emit(rpc.call("agent.open", params: ["workspace_id": wid]))
    case "thread":
        if rest2.isEmpty { usage(RC2ExitCode.usageError) }
        let op = rest2[0]
        let rest3 = Array(rest2.dropFirst())
        let (flags, _) = parseFlags(rest3)
        switch op {
        case "list":
            var p: [String: Any] = [:]; if let w = flags["workspace"] { p["workspace_id"] = w }
            emit(rpc.call("agent.thread.list", params: p))
        case "create":
            var p: [String: Any] = [:]
            if let w = flags["workspace"] { p["workspace_id"] = w }
            if let t = flags["title"] { p["title"] = t }
            if let pr = flags["provider"] { p["provider"] = pr }
            if let m = flags["model"] { p["model"] = m }
            emit(rpc.call("agent.thread.create", params: p))
        default: diagError(RC2CLIDiagnostics.unknownSubcommand(op, of: "agent thread"))
        }
    case "send":
        let (flags, _) = parseFlags(rest2)
        guard let tid = flags["thread"] else { diagError(RC2CLIDiagnostics.missingFlag("thread")) }
        guard let text = flags["text"] else { diagError(RC2CLIDiagnostics.missingFlag("text")) }
        var p: [String: Any] = ["thread_id": tid, "text": text]
        if let pr = flags["provider"] { p["provider"] = pr }
        if let m = flags["model"] { p["model"] = m }
        emit(rpc.call("agent.message.send", params: p))
    case "stop":
        let (flags, _) = parseFlags(rest2)
        guard let tid = flags["thread"] else { diagError(RC2CLIDiagnostics.missingFlag("thread")) }
        emit(rpc.call("agent.run.stop", params: ["thread_id": tid]))
    case "models":
        let (flags, _) = parseFlags(rest2)
        let prov = flags["provider"] ?? "distill"
        emit(rpc.call("agent.models.list", params: ["provider": prov]))
    default: diagError(RC2CLIDiagnostics.unknownSubcommand(sub, of: "agent"))
    }
case "agent-app":
    let (flags, positional) = parseFlags(restArgs)
    guard let providerName = positional.first,
          let provider = AgentProvider(rawValue: providerName) else {
        diagError("agent-app requires provider codex, claude, or grok.")
    }
    let trailingPrompt = positional.dropFirst().joined(separator: " ")
    let prompt: String
    if let path = flags["prompt-file"] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), let contents = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("\(AgentAppCLIError.invalidPromptFile(path).localizedDescription)\n".utf8))
            Darwin.exit(RC2ExitCode.rpcError)
        }
        prompt = contents
    } else if let text = flags["text"] ?? flags["prompt"] {
        prompt = text
    } else {
        prompt = trailingPrompt
    }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        diagError("agent-app requires a prompt, --text, or --prompt-file.")
    }
    let environment = ProcessInfo.processInfo.environment
    let workspaceID = flags["workspace"]
        ?? environment["RC_TOKEN_SAVER_WORKSPACE_ID"]
        ?? environment["RC_REMOTE_CODE_WORKSPACE_ID"]
    let parentRunID = environment["RC_REMOTE_CODE_ROOT_RUN_ID"]
        ?? environment["RC_TOKEN_SAVER_ROOT_RUN_ID"]
        ?? environment["RC_TOKEN_SAVER_ATTEMPT_ID"]
    let parentThreadID = environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"]
        ?? environment["RC_TOKEN_SAVER_THREAD_ID"]
    let parentCapability =
        environment[AgentDelegationCapabilityTransport.environmentKey]
    guard AgentDelegationCapabilityTransport.permitsAgentAppLaunch(
        middlewareEnabled: environment[
            "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"
        ] == "1",
        parentRunID: parentRunID,
        parentThreadID: parentThreadID,
        parentCapability: parentCapability
    ) else {
        diagError(
            "Managed agent-app delegation requires an active parent run, thread, and capability."
        )
    }
    let subagentNodeID: String? = {
        guard parentRunID != nil,
              parentThreadID != nil,
              parentCapability != nil else { return nil }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "nested.\(provider.rawValue).\(ProcessInfo.processInfo.processIdentifier).\(suffix.prefix(12))"
    }()
    let permissionText = flags["permission"] ?? flags["permission-mode"] ?? "supervised"
    guard let permission = AgentPermissionMode(rawValue: permissionText.replacingOccurrences(of: "-", with: "_")) else {
        diagError("Invalid --permission \(permissionText).")
    }
    let effortText = flags["reasoning-effort"] ?? flags["effort"] ?? "medium"
    guard let effort = AgentReasoningEffort(rawValue: effortText) else {
        diagError("Invalid --reasoning-effort \(effortText).")
    }
    let tierText = flags["service-tier"] ?? "auto"
    guard let tier = AgentServiceTier(rawValue: tierText) else {
        diagError("Invalid --service-tier \(tierText).")
    }
    let timeoutMS = Int(flags["turn-timeout"] ?? "3600000") ?? 3_600_000
    guard timeoutMS > 0 else { diagError("Invalid --turn-timeout \(timeoutMS).") }
    let pollIntervalUS: useconds_t = 100_000
    let maxPolls = max(1, timeoutMS / Int(pollIntervalUS / 1_000))
    let outputFormat = flags["output-format"] ?? (jsonOutput ? "json" : "text")
    guard ["text", "json", "grok-json"].contains(outputFormat) else {
        diagError("Invalid --output-format \(outputFormat).")
    }
    let runtimeProfile = flags["runtime-profile"].flatMap(AgentAppRuntimeProfile.init)
    if flags["runtime-profile"] != nil, runtimeProfile == nil {
        diagError("Invalid managed Agent App runtime profile.")
    }
    do {
        let output = try AgentAppMiddlewareWorkflow.execute(
            request: AgentAppMiddlewareRequest(
                provider: provider,
                prompt: prompt,
                workspaceID: workspaceID,
                title: flags["title"],
                model: flags["model"],
                permissionMode: permission,
                reasoningEffort: effort,
                serviceTier: tier,
                parentRunID: parentRunID,
                parentThreadID: parentThreadID,
                subagentNodeID: subagentNodeID,
                parentCapability: parentCapability,
                runtimeProfile: runtimeProfile
            ),
            maxPolls: maxPolls,
            call: callAgentAppRPC,
            wait: { usleep(pollIntervalUS) }
        )
        emitAgentAppOutput(output, format: outputFormat)
    } catch {
        FileHandle.standardError.write(Data("remote-code agent-app: \(error.localizedDescription)\n".utf8))
        Darwin.exit(RC2ExitCode.rpcError)
    }
default:
    diagError(RC2CLIDiagnostics.unknownSubcommand(cmd, of: prog))
}
