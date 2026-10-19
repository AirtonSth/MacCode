import Foundation
import XCTest
@testable import AppShell

private let fakeServerScript = #"""
import json, os, sys, time

out = sys.stdout.buffer
if os.environ.get("FAKE_LAUNCH_LOG"):
    open(os.environ["FAKE_LAUNCH_LOG"], "a").write("start\n")

def read_msg():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        key, value = line.decode().split(":", 1)
        headers[key.strip().lower()] = value.strip()
    msg = json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
    if os.environ.get("FAKE_METHOD_LOG"):
        with open(os.environ["FAKE_METHOD_LOG"], "a") as log:
            log.write((msg.get("method") or "response") + "\n")
    return msg

def send(obj, split=False):
    body = json.dumps(obj).encode()
    frame = b"Content-Length: %d\r\n\r\n" % len(body) + body
    if split:
        half = len(frame) // 2
        out.write(frame[:half]); out.flush()
        time.sleep(0.2)
        out.write(frame[half:]); out.flush()
    else:
        out.write(frame); out.flush()

while True:
    msg = read_msg()
    if msg is None:
        break
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"capabilities": {}}})
        if os.environ.get("FAKE_CLOSE_STDIN"):
            sys.stdin.close()
            time.sleep(2)
            break
    elif method == "textDocument/didOpen":
        send({"jsonrpc": "2.0", "id": 900, "method": "workspace/configuration",
              "params": {"items": [{"section": "x"}]}})
        while True:
            reply = read_msg()
            if reply is None or reply.get("id") == 900:
                break
        uri = msg["params"]["textDocument"]["uri"]
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {
            "uri": uri,
            "diagnostics": [{"range": {"start": {"line": 0, "character": 0},
                                       "end": {"line": 0, "character": 3}},
                             "severity": 2, "message": "unused"}]}})
    elif method == "textDocument/completion":
        send({"jsonrpc": "2.0", "id": mid, "result": {"isIncomplete": False, "items": [
            {"label": "printValue", "insertText": "wrong",
             "textEdit": {"range": {"start": {"line": 0, "character": 2},
                                    "end": {"line": 0, "character": 4}},
                          "newText": "printValue"}},
            {"label": "foo", "insertText": "foo(${1:x})$0", "insertTextFormat": 2},
            {"label": "café"}] + ([{"label": "dollar", "insertText": "$0", "insertTextFormat": 1}] if os.environ.get("FAKE_PLAIN_ITEM") else [])}})
    elif method == "textDocument/hover":
        send({"jsonrpc": "2.0", "id": mid, "result": {"contents": {"kind": "markdown", "value": "**doc**"}}}, split=True)
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": mid, "result": None})
    elif method == "exit":
        break
"""#

private final class DiagnosticsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [(String, [LSPDiagnostic])] = []

    func append(_ path: String, _ diagnostics: [LSPDiagnostic]) {
        lock.lock()
        received.append((path, diagnostics))
        lock.unlock()
    }

    var all: [(String, [LSPDiagnostic])] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

final class FilesLanguageServerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-lsp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for key in ["FAKE_CLOSE_STDIN", "FAKE_PLAIN_ITEM", "FAKE_LAUNCH_LOG", "FAKE_METHOD_LOG"] { unsetenv(key) }
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fakeServerCommand() throws -> [String] {
        let script = tempDir.appendingPathComponent("fake_lsp.py")
        try fakeServerScript.write(to: script, atomically: true, encoding: .utf8)
        return ["/usr/bin/python3", script.path]
    }

    private func startedClient() async throws -> LanguageServerClient {
        let client = LanguageServerClient(command: try fakeServerCommand(), rootPath: tempDir.path)
        try await client.start()
        return client
    }

    func testHandshakeAndCompletionParsesEditsSnippetsAndMultibyteLabels() async throws {
        let client = try await startedClient()
        let items = try await client.completion(path: tempDir.appendingPathComponent("a.py").path,
                                                position: LSPPosition(line: 0, character: 4))
        await client.shutdown()

        XCTAssertEqual(items.count, 3, "CompletionList.items must all be parsed, or the editor loses suggestions")
        XCTAssertEqual(items[0].insertText, "printValue", "textEdit.newText must win over insertText, or inserts use the wrong text")
        XCTAssertEqual(items[0].replaceRange, LSPRange(start: LSPPosition(line: 0, character: 2),
                                                      end: LSPPosition(line: 0, character: 4)),
                       "textEdit.range must decode, or the editor cannot replace the typed prefix")
        XCTAssertEqual(items[1].insertText, "foo(x)", "snippet placeholders must be stripped, or raw `${1:x}` syntax is inserted")
        XCTAssertEqual(items[2].label, "café", "multi-byte labels must survive framing and JSON decoding intact")
    }

    func testDiagnosticsHandlerReceivesPathAndAnswersServerConfigRequest() async throws {
        let client = try await startedClient()
        let box = DiagnosticsBox()
        let delivered = expectation(description: "diagnostics delivered")
        await client.setDiagnosticsHandler { path, diagnostics in
            box.append(path, diagnostics)
            delivered.fulfill()
        }
        let file = tempDir.appendingPathComponent("b.py").path
        await client.didOpen(path: file, languageID: "python", version: 1, text: "x = 1\n")
        // The fake server waits for our reply to workspace/configuration before publishing;
        // a missing reply would leave this expectation unfulfilled.
        await fulfillment(of: [delivered], timeout: 5)
        await client.shutdown()

        let first = try XCTUnwrap(box.all.first, "publishDiagnostics must reach the handler")
        XCTAssertEqual(first.0, file, "handler path must round-trip from the file:// URI, or diagnostics attach to the wrong tab")
        XCTAssertEqual(first.1.first?.severity, 2, "severity must be decoded as sent")
        XCTAssertEqual(first.1.first?.message, "unused", "message must be decoded as sent")
    }

    func testHoverReturnsMarkupValueFromSplitResponse() async throws {
        let client = try await startedClient()
        let text = try await client.hover(path: tempDir.appendingPathComponent("c.py").path,
                                          position: LSPPosition(line: 0, character: 0))
        await client.shutdown()
        XCTAssertEqual(text, "**doc**", "MarkupContent.value must be returned as plain text for the hover popover")
    }

    func testPositionOffsetRoundTripCountsUTF16Units() {
        let text = "a\nçé😀b\nz"
        XCTAssertEqual(text.utf16.count, 9)
        for offset in 0...text.utf16.count {
            let position = LSPText.position(forUTF16Offset: offset, in: text)
            XCTAssertEqual(LSPText.utf16Offset(for: position, in: text), offset,
                           "offset \(offset) must round-trip, or cursor placement drifts after non-BMP characters")
        }
        XCTAssertEqual(LSPText.position(forUTF16Offset: 6, in: text), LSPPosition(line: 1, character: 4),
                       "emoji must count as 2 UTF-16 units, or LSP columns misalign")
        XCTAssertEqual(LSPText.utf16Offset(for: LSPPosition(line: 1, character: 100), in: text), 7,
                       "columns past line end must clamp to line end")
        XCTAssertEqual(LSPText.utf16Offset(for: LSPPosition(line: 99, character: 0), in: text), 9,
                       "lines past text end must clamp to text end")
    }

    func testRegistryFindsExecutableInSearchPathAndRejectsUnknownExtensions() throws {
        let server = tempDir.appendingPathComponent("sourcekit-lsp")
        try "#!/bin/sh\n".write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        XCTAssertEqual(LanguageServerRegistry.command(forPath: "x.swift", language: nil, searchPath: [tempDir.path]),
                       [server.path], "an installed sourcekit-lsp must be resolved to its absolute path")
        XCTAssertNil(LanguageServerRegistry.command(forPath: "x.unknownext", language: nil, searchPath: [tempDir.path]),
                     "unknown extensions must not start any server")
        XCTAssertNil(LanguageServerRegistry.command(forPath: "x.swift", language: nil, searchPath: []),
                     "an empty search path must find no server, or lookups touch arbitrary directories")
    }

    func testShutdownStopsClientAndLaterRequestsFailNotRunning() async throws {
        let client = try await startedClient()
        await client.shutdown()
        let running = await client.isRunning
        XCTAssertFalse(running, "shutdown must clear isRunning so the editor does not send to a dead server")
        do {
            _ = try await client.completion(path: tempDir.appendingPathComponent("d.py").path,
                                            position: LSPPosition(line: 0, character: 0))
            XCTFail("completion after shutdown must throw")
        } catch {
            XCTAssertEqual(error as? LanguageServerError, .notRunning,
                           "requests after shutdown must fail with notRunning, not hang until timeout")
        }
    }

    func testWriteAfterStdinClosedThrowsInsteadOfCrashing() async throws {
        setenv("FAKE_CLOSE_STDIN", "1", 1)
        let client = try await startedClient()
        do {
            _ = try await client.completion(path: tempDir.appendingPathComponent("e.py").path,
                                            position: LSPPosition(line: 0, character: 0))
            XCTFail("completion must throw once the server stopped reading stdin")
        } catch {
            let known = error as? LanguageServerError
            XCTAssertTrue(known == .notRunning || known == .timedOut,
                          "a broken stdin pipe must surface as notRunning or timedOut, not a SIGPIPE crash")
        }
        await client.shutdown()
    }

    func testPoolLeaseKeepsServerUntilLastRelease() async throws {
        let command = try fakeServerCommand()
        let pool = LanguageServerPool()
        let first = try await pool.client(command: command, rootPath: tempDir.path)
        _ = try await pool.client(command: command, rootPath: tempDir.path)
        await pool.release(command: command, rootPath: tempDir.path)
        let stillRunning = await first.isRunning
        XCTAssertTrue(stillRunning, "a second lease holder must keep the server alive after one release")
        await pool.release(command: command, rootPath: tempDir.path)
        var running = true
        let deadline = Date().addingTimeInterval(2)
        while running && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            running = await first.isRunning
        }
        XCTAssertFalse(running, "the last release must stop the server, or idle servers pile up")
    }

    func testConcurrentAcquiresLaunchServerOnce() async throws {
        let launchLog = tempDir.appendingPathComponent("launches.log")
        setenv("FAKE_LAUNCH_LOG", launchLog.path, 1)
        let command = try fakeServerCommand()
        let root = tempDir.path
        let pool = LanguageServerPool()
        try await withThrowingTaskGroup(of: LanguageServerClient.self) { group in
            for _ in 0..<5 {
                group.addTask { try await pool.client(command: command, rootPath: root) }
            }
            for try await _ in group {}
        }
        let launches = (try? String(contentsOf: launchLog, encoding: .utf8))?.split(separator: "\n").count ?? 0
        XCTAssertEqual(launches, 1, "concurrent acquires must share one launch, or each tab spawns its own server")
        await pool.shutdownAll()
    }

    func testSharedDocumentSendsOneDidOpenAndNoCloseUntilLastClose() async throws {
        let methodLog = tempDir.appendingPathComponent("methods.log")
        setenv("FAKE_METHOD_LOG", methodLog.path, 1)
        let client = try await startedClient()
        let file = tempDir.appendingPathComponent("f.py").path
        let first = DiagnosticsBox()
        let second = DiagnosticsBox()
        let delivered = expectation(description: "both diagnostics subscribers notified")
        delivered.expectedFulfillmentCount = 2
        _ = await client.addDiagnosticsHandler { path, diagnostics in
            first.append(path, diagnostics)
            delivered.fulfill()
        }
        _ = await client.addDiagnosticsHandler { path, diagnostics in
            second.append(path, diagnostics)
            delivered.fulfill()
        }
        await client.didOpen(path: file, languageID: "python", version: 1, text: "x = 1\n")
        await client.didOpen(path: file, languageID: "python", version: 1, text: "x = 1\n")
        await client.didClose(path: file)
        await fulfillment(of: [delivered], timeout: 5)
        await client.shutdown()

        let methods = (try? String(contentsOf: methodLog, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(methods.filter { $0 == "textDocument/didOpen" }.count, 1,
                       "two openers of one file must send a single didOpen, or the server resets its document state")
        XCTAssertEqual(methods.filter { $0 == "textDocument/didClose" }.count, 0,
                       "a close that leaves one opener must not send didClose")
        XCTAssertEqual(first.all.count, 1, "every diagnostics subscriber must receive publishes")
        XCTAssertEqual(second.all.count, 1, "every diagnostics subscriber must receive publishes")
    }

    func testPlainTextItemKeepsDollarZeroWhenNotSnippet() async throws {
        setenv("FAKE_PLAIN_ITEM", "1", 1)
        let client = try await startedClient()
        let items = try await client.completion(path: tempDir.appendingPathComponent("g.py").path,
                                                position: LSPPosition(line: 0, character: 0))
        await client.shutdown()
        let item = try XCTUnwrap(items.first { $0.label == "dollar" })
        XCTAssertEqual(item.insertText, "$0", "insertText without insertTextFormat 2 is plain text; stripping it drops user content")
    }

    func testLaunchFailureThrowsLaunchFailed() async {
        let client = LanguageServerClient(command: ["/nonexistent/server"], rootPath: tempDir.path)
        do {
            try await client.start()
            XCTFail("start must throw when the executable is missing")
        } catch {
            XCTAssertEqual(error as? LanguageServerError, .launchFailed,
                           "a missing server binary must surface as launchFailed, or the editor retries silently")
        }
    }
}
