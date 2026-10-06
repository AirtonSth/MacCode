import XCTest
import CoreModel
@testable import Persistence

/// The in-app guest gateway serves the web and computer MCPs through
/// `handleSynchronously` (on its own threads, never Swift's cooperative pool).
/// A bot inside its Linux VM must get exactly the replies the Mac stdio server
/// gives a Mac run, so the synchronous entry may not drift from `handle`.
final class ManagedBotMCPSynchronousTests: XCTestCase {
    private let bot = BotID()

    private func webServer(fetch: @escaping @Sendable (URL) throws -> (status: Int, body: Data, contentType: String, finalURL: URL)) -> ManagedBotWebMCP {
        let bot = bot
        return ManagedBotWebMCP(
            environment: [BotWebCatalog.callerEnvironmentKey: bot.value.uuidString],
            serviceFactory: { _ in
                var service = BotWebService(callerBotID: bot)
                service.fetchHandler = fetch
                return service
            }
        )
    }

    /// Replies compared as JSON values (dictionary key order is not stable),
    /// including the JSON a tool result carries as its text.
    private func parsed(_ reply: String?) -> NSObject? {
        func normalize(_ value: Any) -> Any {
            if let text = value as? String,
               let inner = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
               inner is [String: Any] {
                return normalize(inner)
            }
            if let object = value as? [String: Any] { return object.mapValues(normalize) }
            if let array = value as? [Any] { return array.map(normalize) }
            return value
        }
        return reply
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
            .map(normalize) as? NSObject
    }

    private let lines = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"not_a_tool"}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"nope"}"#,
        "not json",
    ]

    func test_webSynchronousRepliesMatchAsyncRepliesForSuccessErrorAndProtocol() async throws {
        let ok = webServer { url in
            (status: 200, body: Data("<html><body><p>Page body</p></body></html>".utf8), contentType: "text/html", finalURL: url)
        }
        let failing = webServer { _ in throw BotWebError.invalid("boom") }
        let fetch = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"bot_web_fetch","arguments":{"url":"https://example.com/page"}}}"#
        for line in lines + [fetch] {
            let asyncReply = await ok.handle(line)
            XCTAssertEqual(parsed(ok.handleSynchronously(line)), parsed(asyncReply), line)
            XCTAssertEqual(ok.handleSynchronously(line) == nil, asyncReply == nil, line)
        }
        let failedAsync = await failing.handle(fetch)
        XCTAssertEqual(parsed(failing.handleSynchronously(fetch)), parsed(failedAsync))
        XCTAssertTrue(try XCTUnwrap(ok.handleSynchronously(fetch)).contains("Page body"))
        XCTAssertTrue(try XCTUnwrap(failing.handleSynchronously(fetch)).contains(#""isError":true"#))
    }

    func test_computerSynchronousRepliesMatchAsyncRepliesForProtocolAndErrors() async throws {
        let server = ManagedBotComputerMCP(
            environment: [BotComputerCatalog.callerEnvironmentKey: bot.value.uuidString],
            storeFactory: { _ in throw BotComputerError.invalid("store unavailable") }
        )
        let call = #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"bot_post_screenshot","arguments":{}}}"#
        for line in lines + [call] {
            let asyncReply = await server.handle(line)
            XCTAssertEqual(parsed(server.handleSynchronously(line)), parsed(asyncReply), line)
            XCTAssertEqual(server.handleSynchronously(line) == nil, asyncReply == nil, line)
        }
        XCTAssertTrue(try XCTUnwrap(server.handleSynchronously(call)).contains("store unavailable"))
    }
}
