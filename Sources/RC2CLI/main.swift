import Foundation
import Darwin
import CoreModel
import Persistence

let args = CommandLine.arguments
let prog = (args.first as NSString?)?.lastPathComponent ?? "remotecode"

func usage(_ exit: Int32 = 0) -> Never {
    let text = """
    Usage: \(prog) [--socket PATH] [--json] <command> [args...]

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
      read-text --id SID
      surface move --workspace WID --id SID --target-pane PID
      surface reorder --workspace WID --id SID --target-pane PID [--position N]
      pane list --workspace WID
      pane swap --workspace WID --a PID --b PID
      pane resize --workspace WID --split SPLIT_ID --ratios "0.3,0.7"
      window list / window current / window create [--title T] / window focus --id WID / window close --id WID
      workspace move-to-window --workspace WID --window WIDX
      events recent / events stream
      notification create [--workspace WID] --title T [--body B] [--category C]
      notification list [--workspace WID] [--unread]
      notification mark-read --id N / notification dismiss --id N
      browser navigate --id SID --url URL / browser back/forward/reload --id SID
      browser snapshot --id SID
      browser click --id SID --ref REF
      browser fill --id SID --ref REF --value V
      browser type --id SID --ref REF --value V
      browser wait --id SID --selector CSS [--timeout MS]
      browser screenshot --id SID [--path PATH]
      agent open --workspace WID
      agent thread list [--workspace WID]
      agent thread create [--workspace WID] [--title T] [--provider codex|claude] [--model M]
      agent send --thread TID --text "..." [--provider ...] [--model ...]
      agent stop --thread TID
      agent models --provider codex|claude
    """
    FileHandle.standardError.write(Data(text.utf8))
    Darwin.exit(exit)
}

func parseFlags(_ a: [String]) -> ([String: String], [String]) {
    var dict: [String: String] = [:]
    var positional: [String] = []
    var i = 0
    while i < a.count {
        let s = a[i]
        if s.hasPrefix("--") {
            let key = String(s.dropFirst(2))
            if i + 1 < a.count && !a[i+1].hasPrefix("--") {
                dict[key] = a[i+1]
                i += 2; continue
            } else {
                dict[key] = "true"
            }
        } else {
            positional.append(s)
        }
        i += 1
    }
    return (dict, positional)
}

let envChannel = ProcessInfo.processInfo.environment["RC2_CHANNEL"] ?? "debug"
let releaseChannel = ReleaseChannel(rawValue: envChannel) ?? .debug
var socketPath = AppPaths.socketPath(for: releaseChannel)
var jsonOutput = false

var rest: [String] = []
var i = 1
while i < args.count {
    let s = args[i]
    if s == "--socket", i + 1 < args.count { socketPath = args[i+1]; i += 2; continue }
    if s == "--json" { jsonOutput = true; i += 1; continue }
    if s == "--help" || s == "-h" { usage(0) }
    rest.append(s); i += 1
}
if rest.isEmpty { usage(RC2ExitCode.usageError) }

struct RPC {
    let socketPath: String
    func call(_ method: String, params: [String: Any]) -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return ["error": ["code": -1, "message": "socket(): \(String(cString: strerror(errno)))"]] }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = socketPath.utf8CString
        if bytes.count > maxPath {
            return ["error": ["code": -1, "message": "socket path too long"]]
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
            return ["error": ["code": -1, "message": "connect(\(socketPath)): \(msg). Is the RemoteCode app running?", "_connect_failure": true]]
        }
        defer { close(fd) }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...1_000_000),
            "method": method,
            "params": params
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return ["error": ["code": -1, "message": "serialize failed"]]
        }
        data.append(0x0A)
        let written = data.withUnsafeBytes { ptr -> Int in
            return Darwin.write(fd, ptr.baseAddress, data.count)
        }
        if written < 0 { return ["error": ["code": -1, "message": "write failed"]] }
        // read until newline
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buf.append(tmp, count: n)
            if buf.last == 0x0A { break }
        }
        guard let any = try? JSONSerialization.jsonObject(with: buf) as? [String: Any] else {
            return ["error": ["code": -1, "message": "decode failed: \(String(data: buf, encoding: .utf8) ?? "")"]]
        }
        return any
    }
}

let rpc = RPC(socketPath: socketPath)

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
            Darwin.exit(1)
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
    guard let wid = flags["workspace"], let type = flags["type"] else { usage(RC2ExitCode.usageError) }
    var p: [String: Any] = ["workspace_id": wid, "type": type]
    if let t = flags["title"] { p["title"] = t }
    emit(rpc.call("surface.create", params: p))
case "new-split":
    let (flags, _) = parseFlags(restArgs)
    guard let wid = flags["workspace"], let pid = flags["pane"], let dir = flags["direction"], let type = flags["type"] else { usage(RC2ExitCode.usageError) }
    emit(rpc.call("surface.split", params: ["workspace_id": wid, "pane_id": pid, "direction": dir, "type": type]))
case "focus":
    let (flags, _) = parseFlags(restArgs)
    guard let wid = flags["workspace"], let sid = flags["id"] else { usage(RC2ExitCode.usageError) }
    emit(rpc.call("surface.focus", params: ["workspace_id": wid, "id": sid]))
case "close":
    let (flags, _) = parseFlags(restArgs)
    guard let wid = flags["workspace"], let sid = flags["id"] else { usage(RC2ExitCode.usageError) }
    emit(rpc.call("surface.close", params: ["workspace_id": wid, "id": sid]))
case "send-text":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"], let text = flags["text"] else { usage(RC2ExitCode.usageError) }
    emit(rpc.call("surface.send_text", params: ["id": sid, "text": text]))
case "send-key":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"], let key = flags["key"] else { usage(RC2ExitCode.usageError) }
    emit(rpc.call("surface.send_key", params: ["id": sid, "key": key]))
case "clear-history":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"] else { usage(RC2ExitCode.usageError) }
    emit(rpc.call("surface.clear_history", params: ["id": sid]))
case "health":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"] else { usage(RC2ExitCode.usageError) }
    emit(rpc.call("surface.health", params: ["id": sid]))
case "read-text":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"] else { usage(RC2ExitCode.usageError) }
    emit(rpc.call("surface.read_text", params: ["id": sid]))
case "surface":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let (flags, _) = parseFlags(Array(restArgs.dropFirst()))
    switch sub {
    case "move":
        guard let w = flags["workspace"], let id = flags["id"], let target = flags["target-pane"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("surface.move", params: ["workspace_id": w, "id": id, "target_pane_id": target]))
    case "reorder":
        guard let w = flags["workspace"], let id = flags["id"], let target = flags["target-pane"] else { usage(RC2ExitCode.usageError) }
        let pos = Int(flags["position"] ?? "0") ?? 0
        emit(rpc.call("surface.reorder", params: ["workspace_id": w, "id": id, "target_pane_id": target, "position": pos]))
    default: usage(RC2ExitCode.usageError)
    }
case "pane":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let (flags, _) = parseFlags(Array(restArgs.dropFirst()))
    switch sub {
    case "list":
        guard let w = flags["workspace"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("pane.list", params: ["workspace_id": w]))
    case "swap":
        guard let w = flags["workspace"], let a = flags["a"], let b = flags["b"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("pane.swap", params: ["workspace_id": w, "a": a, "b": b]))
    case "resize":
        guard let w = flags["workspace"], let s = flags["split"], let r = flags["ratios"] else { usage(RC2ExitCode.usageError) }
        let ratios = r.split(separator: ",").compactMap { Double($0) }
        emit(rpc.call("pane.resize", params: ["workspace_id": w, "split_id": s, "ratios": ratios]))
    default: usage(RC2ExitCode.usageError)
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
        guard let id = flags["id"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("window.focus", params: ["id": id]))
    case "close":
        guard let id = flags["id"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("window.close", params: ["id": id]))
    default: usage(RC2ExitCode.usageError)
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
            FileHandle.standardError.write(Data("error: connect(\(socketPath)): \(msg). Is the RemoteCode app running?\n".utf8))
            Darwin.close(fd)
            Darwin.exit(1)
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
    default: usage(RC2ExitCode.usageError)
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
        guard let id = flags["id"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("notification.mark_read", params: ["id": id]))
    case "dismiss":
        guard let id = flags["id"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("notification.dismiss", params: ["id": id]))
    default: usage(RC2ExitCode.usageError)
    }
case "browser":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let (flags, _) = parseFlags(Array(restArgs.dropFirst()))
    switch sub {
    case "navigate":
        guard let id = flags["id"], let url = flags["url"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("browser.navigate", params: ["id": id, "url": url]))
    case "back", "forward", "reload", "url":
        guard let id = flags["id"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("browser." + (sub == "url" ? "url.get" : sub), params: ["id": id]))
    case "snapshot":
        guard let id = flags["id"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("browser.snapshot", params: ["id": id]))
    case "click", "focus", "hover", "check", "uncheck":
        guard let id = flags["id"], let ref = flags["ref"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("browser." + sub, params: ["id": id, "ref": ref]))
    case "fill", "type", "select":
        guard let id = flags["id"], let ref = flags["ref"], let val = flags["value"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("browser." + sub, params: ["id": id, "ref": ref, "value": val]))
    case "wait":
        guard let id = flags["id"], let sel = flags["selector"] else { usage(RC2ExitCode.usageError) }
        let t = Int(flags["timeout"] ?? "5000") ?? 5000
        emit(rpc.call("browser.wait", params: ["id": id, "selector": sel, "timeout_ms": t]))
    case "screenshot":
        guard let id = flags["id"] else { usage(RC2ExitCode.usageError) }
        var p: [String: Any] = ["id": id]
        if let path = flags["path"] { p["path"] = path }
        emit(rpc.call("browser.screenshot", params: p))
    case "eval":
        guard let id = flags["id"], let script = flags["script"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("browser.eval", params: ["id": id, "script": script]))
    default: usage(RC2ExitCode.usageError)
    }
case "workspace":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let (flags, _) = parseFlags(Array(restArgs.dropFirst()))
    switch sub {
    case "move-to-window":
        guard let w = flags["workspace"], let win = flags["window"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("workspace.move_to_window", params: ["workspace_id": w, "window_id": win]))
    default: usage(RC2ExitCode.usageError)
    }
case "agent":
    if restArgs.isEmpty { usage(RC2ExitCode.usageError) }
    let sub = restArgs[0]
    let rest2 = Array(restArgs.dropFirst())
    switch sub {
    case "open":
        let (flags, _) = parseFlags(rest2)
        guard let wid = flags["workspace"] else { usage(RC2ExitCode.usageError) }
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
        default: usage(RC2ExitCode.usageError)
        }
    case "send":
        let (flags, _) = parseFlags(rest2)
        guard let tid = flags["thread"], let text = flags["text"] else { usage(RC2ExitCode.usageError) }
        var p: [String: Any] = ["thread_id": tid, "text": text]
        if let pr = flags["provider"] { p["provider"] = pr }
        if let m = flags["model"] { p["model"] = m }
        emit(rpc.call("agent.message.send", params: p))
    case "stop":
        let (flags, _) = parseFlags(rest2)
        guard let tid = flags["thread"] else { usage(RC2ExitCode.usageError) }
        emit(rpc.call("agent.run.stop", params: ["thread_id": tid]))
    case "models":
        let (flags, _) = parseFlags(rest2)
        let prov = flags["provider"] ?? "codex"
        emit(rpc.call("agent.models.list", params: ["provider": prov]))
    default: usage(RC2ExitCode.usageError)
    }
default:
    usage(RC2ExitCode.usageError)
}
