import XCTest
import CoreModel
@testable import Persistence

final class BotWebTests: XCTestCase {
    func test_fetchRejectsFileAndLoopback() throws {
        // WHY: Host-owned fetch must not read local files or loopback.
        let bot = BotID()
        let service = BotWebService(callerBotID: bot)
        XCTAssertThrowsError(
            try service.call(name: BotWebCatalog.fetch, arguments: ["url": "file:///etc/passwd"])
        )
        XCTAssertThrowsError(
            try service.call(name: BotWebCatalog.fetch, arguments: ["url": "http://127.0.0.1/secret"])
        )
        XCTAssertThrowsError(
            try service.call(name: BotWebCatalog.fetch, arguments: ["url": "http://localhost/x"])
        )
        XCTAssertThrowsError(
            try service.call(name: BotWebCatalog.fetch, arguments: ["url": "http://192.168.1.9/x"])
        )
        XCTAssertFalse(BotWebPolicy.allow(URL(string: "http://10.0.0.2")!))
        XCTAssertTrue(BotWebPolicy.allow(URL(string: "https://example.com/a")!))
    }

    func test_fetchUsesInjectedHandlerAndMarksUntrusted() throws {
        let bot = BotID()
        var service = BotWebService(callerBotID: bot)
        service.fetchHandler = { url in
            (
                status: 200,
                body: Data("<html><body><p>Hello</p></body></html>".utf8),
                contentType: "text/html",
                finalURL: url
            )
        }
        let result = try service.call(
            name: BotWebCatalog.fetch,
            arguments: ["url": "https://example.com/page"]
        )
        XCTAssertEqual(result["status"] as? Int, 200)
        XCTAssertEqual(result["untrusted"] as? Bool, true)
        XCTAssertEqual(result["text"] as? String, "Hello")
    }

    func test_searchParsesInstantAnswerJSON() throws {
        let json = """
        {"Heading":"Paris","AbstractText":"Capital of France.","AbstractURL":"https://example.com/paris","RelatedTopics":[{"Text":"Eiffel Tower","FirstURL":"https://example.com/tower"}]}
        """
        let rows = try BotWebSearchParser.results(from: Data(json.utf8))
        XCTAssertEqual(rows.first?["url"], "https://example.com/paris")
        XCTAssertTrue(rows.contains { $0["url"] == "https://example.com/tower" })
        let bot = BotID()
        var service = BotWebService(callerBotID: bot)
        service.searchHandler = { _ in rows }
        let result = try service.call(name: BotWebCatalog.search, arguments: ["query": "paris"])
        XCTAssertEqual(result["backend"] as? String, "duckduckgo-instant-answer")
        XCTAssertEqual(result["untrusted"] as? Bool, true)
    }

    func test_crossBotRejected() {
        let service = BotWebService(callerBotID: BotID())
        XCTAssertThrowsError(
            try service.call(
                name: BotWebCatalog.search,
                arguments: ["bot_id": BotID().value.uuidString, "query": "x"]
            )
        ) { error in
            XCTAssertEqual(error as? BotWebError, .crossBot)
        }
    }
}
