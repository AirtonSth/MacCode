import XCTest
import CoreModel
@testable import Persistence

/// Token Saver lane for bot MCP tool results. WHY: bot workloads are MCP-heavy
/// (web fetch/search, guest exec) and Codex/Grok have no PostToolUse hook, so
/// without this seam a bot thread measures 0 saved tokens no matter how much
/// compressible tool output it produced.
final class ManagedBotMCPDistillTests: XCTestCase {
    private final class DistillerSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(tool: String, text: String)] = []
        var replacement: String?

        init(replacement: String?) {
            self.replacement = replacement
        }

        func record(tool: String, text: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            calls.append((tool, text))
            return replacement
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls.count
        }

        var firstTool: String? {
            lock.lock()
            defer { lock.unlock() }
            return calls.first?.tool
        }
    }

    private func webServer(
        distiller: DistillerSpy?,
        fetchText: String = "Hello page text"
    ) -> ManagedBotWebMCP {
        let bot = BotID()
        return ManagedBotWebMCP(
            environment: [BotWebCatalog.callerEnvironmentKey: bot.value.uuidString],
            serviceFactory: { _ in
                var service = BotWebService(callerBotID: bot)
                service.fetchHandler = { url in
                    (
                        status: 200,
                        body: Data("<html><body><p>\(fetchText)</p></body></html>".utf8),
                        contentType: "text/html",
                        finalURL: url
                    )
                }
                return service
            },
            distillToolResult: distiller.map { spy in
                { tool, text in spy.record(tool: tool, text: text) }
            }
        )
    }

    private func contentText(_ reply: String?) throws -> (text: String, isError: Bool) {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(XCTUnwrap(reply).utf8)) as? [String: Any]
        )
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return (text, result["isError"] as? Bool ?? false)
    }

    private func fetchCall() -> String {
        #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"bot_web_fetch","arguments":{"url":"https://example.com/page"}}}"#
    }

    func test_webFetchResult_routesThroughDistiller_andReplacesText() async throws {
        // WHY: this is the seam that makes bot MCP output measurable savings on
        // EVERY provider — the compressed text (with its recovery handle) must be
        // what the model actually receives, or the ledger row would be a lie.
        let spy = DistillerSpy(replacement: "COMPRESSED SUMMARY\n[[rc:test-handle]]")
        let reply = await webServer(distiller: spy).handle(fetchCall())
        let content = try contentText(reply)
        XCTAssertEqual(content.text, "COMPRESSED SUMMARY\n[[rc:test-handle]]")
        XCTAssertFalse(content.isError)
        XCTAssertEqual(spy.callCount, 1)
        XCTAssertEqual(spy.firstTool, BotWebCatalog.fetch)
    }

    func test_webFetchResult_keepsOriginal_whenDistillerDeclines() async throws {
        // WHY: fail-open — a declined/failed compression must never replace or
        // drop tool output; the bot keeps working exactly as without Token Saver.
        let spy = DistillerSpy(replacement: nil)
        let reply = await webServer(distiller: spy, fetchText: "Verbatim body").handle(fetchCall())
        let content = try contentText(reply)
        XCTAssertTrue(content.text.contains("Verbatim body"))
        XCTAssertFalse(content.isError)
        XCTAssertEqual(spy.callCount, 1)
    }

    func test_webHandler_withoutDistiller_keepsOriginal() async throws {
        // WHY: the distiller is opt-in wiring from the service executable; a
        // server constructed without it must behave exactly as before.
        let reply = await webServer(distiller: nil, fetchText: "Plain body").handle(fetchCall())
        let content = try contentText(reply)
        XCTAssertTrue(content.text.contains("Plain body"))
        XCTAssertFalse(content.isError)
    }

    func test_errorReply_neverDistilled() async throws {
        // WHY: error text is diagnostic for the model; compressing it could hide
        // the failure cause — and must never be counted as savings.
        let spy = DistillerSpy(replacement: "SHOULD NOT APPEAR")
        let bot = BotID()
        let server = ManagedBotWebMCP(
            environment: [BotWebCatalog.callerEnvironmentKey: bot.value.uuidString],
            serviceFactory: { _ in
                var service = BotWebService(callerBotID: bot)
                service.fetchHandler = { _ in throw BotWebError.invalid("boom") }
                return service
            },
            distillToolResult: { tool, text in spy.record(tool: tool, text: text) }
        )
        let reply = await server.handle(fetchCall())
        let content = try contentText(reply)
        XCTAssertTrue(content.isError)
        XCTAssertFalse(content.text.contains("SHOULD NOT APPEAR"))
        XCTAssertEqual(spy.callCount, 0)
    }

    func test_webDistillableToolNames_coverContentTools() {
        // WHY: search/fetch results are read-only content — the whole point of
        // the lane. If a rename drops them, bot web savings silently die.
        XCTAssertEqual(
            BotWebCatalog.distillableToolNames,
            [BotWebCatalog.search, BotWebCatalog.fetch]
        )
    }

    func test_computerDistillableToolNames_excludeActionTools() {
        // WHY: observe/act results carry coordinates and screen state the bot
        // echoes back verbatim on the next step; compressing them breaks the
        // act loop. Only exec (command output) is content.
        XCTAssertEqual(
            BotComputerCatalog.distillableToolNames,
            [BotComputerCatalog.exec]
        )
        XCTAssertFalse(BotComputerCatalog.distillableToolNames.contains(BotComputerCatalog.observe))
        XCTAssertFalse(BotComputerCatalog.distillableToolNames.contains(BotComputerCatalog.act))
        XCTAssertFalse(BotComputerCatalog.distillableToolNames.contains(BotComputerCatalog.rebuild))
    }
}
