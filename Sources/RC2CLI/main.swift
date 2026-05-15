import Foundation
import Darwin
import CoreModel

let args = CommandLine.arguments
let prog = (args.first as NSString?)?.lastPathComponent ?? "remotecode2"

func usage(_ exit: Int32 = 0) -> Never {
    let text = """
    Usage: \(prog) [--socket PATH] [--json] <command> [args...]

    Commands:
      ping
      capabilities
      workspaces             list workspaces
      new-workspace --cwd PATH --name NAME
      new-surface --workspace WID --type terminal|browser|agent [--title T]
      new-split  --workspace WID --pane PID --direction right|down|left|up --type ...
      focus --workspace WID --id SID
      close --workspace WID --id SID
      send-text --id SID --text "..."
      read-text --id SID
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
let defaultDisplay: String = {
    switch envChannel {
    case "stable": return "RemoteCode2"
    case "canary": return "RemoteCode2Canary"
    default: return "RemoteCode2Debug"
    }
}()
var socketPath = "/tmp/\(defaultDisplay).sock"
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
if rest.isEmpty { usage(2) }

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
            return ["error": ["code": -1, "message": "connect(\(socketPath)): \(msg). Is the RemoteCode 2 app running?"]]
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
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .fragmentsAllowed]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
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
    guard let wid = flags["workspace"], let type = flags["type"] else { usage(2) }
    var p: [String: Any] = ["workspace_id": wid, "type": type]
    if let t = flags["title"] { p["title"] = t }
    emit(rpc.call("surface.create", params: p))
case "new-split":
    let (flags, _) = parseFlags(restArgs)
    guard let wid = flags["workspace"], let pid = flags["pane"], let dir = flags["direction"], let type = flags["type"] else { usage(2) }
    emit(rpc.call("surface.split", params: ["workspace_id": wid, "pane_id": pid, "direction": dir, "type": type]))
case "focus":
    let (flags, _) = parseFlags(restArgs)
    guard let wid = flags["workspace"], let sid = flags["id"] else { usage(2) }
    emit(rpc.call("surface.focus", params: ["workspace_id": wid, "id": sid]))
case "close":
    let (flags, _) = parseFlags(restArgs)
    guard let wid = flags["workspace"], let sid = flags["id"] else { usage(2) }
    emit(rpc.call("surface.close", params: ["workspace_id": wid, "id": sid]))
case "send-text":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"], let text = flags["text"] else { usage(2) }
    emit(rpc.call("surface.send_text", params: ["id": sid, "text": text]))
case "read-text":
    let (flags, _) = parseFlags(restArgs)
    guard let sid = flags["id"] else { usage(2) }
    emit(rpc.call("surface.read_text", params: ["id": sid]))
case "agent":
    if restArgs.isEmpty { usage(2) }
    let sub = restArgs[0]
    let rest2 = Array(restArgs.dropFirst())
    switch sub {
    case "open":
        let (flags, _) = parseFlags(rest2)
        guard let wid = flags["workspace"] else { usage(2) }
        emit(rpc.call("agent.open", params: ["workspace_id": wid]))
    case "thread":
        if rest2.isEmpty { usage(2) }
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
        default: usage(2)
        }
    case "send":
        let (flags, _) = parseFlags(rest2)
        guard let tid = flags["thread"], let text = flags["text"] else { usage(2) }
        var p: [String: Any] = ["thread_id": tid, "text": text]
        if let pr = flags["provider"] { p["provider"] = pr }
        if let m = flags["model"] { p["model"] = m }
        emit(rpc.call("agent.message.send", params: p))
    case "stop":
        let (flags, _) = parseFlags(rest2)
        guard let tid = flags["thread"] else { usage(2) }
        emit(rpc.call("agent.run.stop", params: ["thread_id": tid]))
    case "models":
        let (flags, _) = parseFlags(rest2)
        let prov = flags["provider"] ?? "codex"
        emit(rpc.call("agent.models.list", params: ["provider": prov]))
    default: usage(2)
    }
default:
    usage(2)
}
