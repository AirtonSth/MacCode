import XCTest
import Darwin
@testable import SocketServer

final class UnixSocketServerTests: XCTestCase {
    @MainActor
    func testSocketIsCurrentUserOwnedAndMode0600BeforeClientsConnect() throws {
        let socketURL = URL(fileURLWithPath: "/tmp/rc2-p-\(UUID().uuidString.prefix(8)).sock")
        let server = UnixSocketServer(socketPath: socketURL.path, dispatcher: JSONRPCDispatcher(router: FakeRouter()))
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, geteuid(),
                       "local IPC must be owned by the current user")
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, UInt16(0o600),
                       "local IPC must not grant group or other access")
    }

    @MainActor
    func testLocalIPCMutationUsesSharedHandlerWithoutRemoteWireIdentity() async throws {
        let router = FakeRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatchLocalIPC(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .string("local"),
            method: "workspace.create",
            params: ["name": .string("local"), "cwd": .string("/tmp")]
        ))

        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.objectValue?["name"], .string("local"))
        XCTAssertEqual(router.workspaces.count, 1,
                       "owner-only local IPC must keep the CLI domain-handler path without remote receipt fields")
    }

    @MainActor
    func testEventStreamDeliversLiveEventsOverSerializedUnixSocketWriter() throws {
        let socketURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc2-unix-\(UUID().uuidString).sock")
        let server = UnixSocketServer(socketPath: socketURL.path, dispatcher: JSONRPCDispatcher(router: FakeRouter()))
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: socketURL)
        }
        Thread.sleep(forTimeInterval: 0.05)

        let fd = try connectUnix(path: socketURL.path)
        defer { Darwin.close(fd) }

        let startSeq = EventBus.shared.snapshot().lastSeq
        let request = #"{"jsonrpc":"2.0","id":"stream","method":"events.stream","params":{"after_seq":\#(startSeq)}}"# + "\n"
        try writeAll(fd: fd, data: Data(request.utf8))
        let ack = try readLine(fd: fd)

        let kind = "unix.test.\(UUID().uuidString)"
        EventBus.shared.publish(kind: kind, payload: .string("ok"))
        let event = try readLine(fd: fd)

        XCTAssertTrue(ack.contains(#""subscribed":true"#),
                      "event stream clients need an ack before waiting for live events")
        XCTAssertTrue(event.contains(kind),
                      "live events must be serialized through the Unix socket writer without dropping the frame")
    }

    private func connectUnix(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        XCTAssertLessThanOrEqual(bytes.count, maxPath)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: maxPath) { target in
                for i in 0..<bytes.count { target[i] = bytes[i] }
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc < 0 {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += n
            }
        }
    }

    private func readLine(fd: Int32) throws -> String {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
