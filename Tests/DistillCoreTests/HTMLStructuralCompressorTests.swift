import XCTest
@testable import DistillCore

final class HTMLStructuralCompressorTests: XCTestCase {
    func test_compressElidesBulkyScriptStyleAndPreservesReadableStructure() throws {
        let script = (0..<60)
            .map { "console.log('debug-\($0)');" }
            .joined(separator: "\n")
        let style = (0..<40)
            .map { ".unused-\($0) { color: #abcdef; }" }
            .joined(separator: "\n")
        let html = """
        <!doctype html>
        <html>
          <head>
            <title>RemoteCode Status</title>
            <style>
        \(style)
            </style>
          </head>
          <body>
            <h1>Build failed</h1>
            <p>Check Sources/App.swift:42 before retrying.</p>
            <script>
        \(script)
            </script>
          </body>
        </html>
        """

        let compressed = try XCTUnwrap(HTMLStructuralCompressor.compress(html, droppedHandle: "[[rc:html123]]"))
        XCTAssertTrue(compressed.contains("<title>RemoteCode Status</title>"))
        XCTAssertTrue(compressed.contains("<h1>Build failed</h1>"))
        XCTAssertTrue(compressed.contains("Sources/App.swift:42"))
        XCTAssertTrue(compressed.contains("[[rc:html123]]"))
        XCTAssertTrue(compressed.contains("html block elided"))
        XCTAssertFalse(compressed.contains("console.log('debug-59')"))
        XCTAssertFalse(compressed.contains(".unused-39"))
        XCTAssertLessThan(compressed.count, html.count)
    }

    func test_routerUsesStoreBackedHTMLCompressorWhenHandleExists() throws {
        let script = (0..<80)
            .map { "window.__payload_\($0) = '\(String(repeating: "x", count: 40))';" }
            .joined(separator: "\n")
        let html = """
        <!doctype html>
        <html>
          <body>
            <main><h1>Run Report</h1><p>Keep this user-visible report.</p></main>
            <script>
        \(script)
            </script>
          </body>
        </html>
        """

        let router = DistillContentRouter()
        let result = try XCTUnwrap(
            router.route(
                html,
                options: .init(allowElementDropping: true, reversibleHandle: "html456")
            ),
            "B1 HTML routing must use a native store-backed compressor instead of falling through to generic prose"
        )

        XCTAssertEqual(result.contentType, .html)
        XCTAssertFalse(result.lossless)
        XCTAssertTrue(result.output.contains("<h1>Run Report</h1>"))
        XCTAssertTrue(result.output.contains("[[rc:html456]]"))
        XCTAssertFalse(result.output.contains("window.__payload_79"))
    }

    func test_htmlCompressionRequiresHandleAndWorthwhileSavings() {
        XCTAssertNil(HTMLStructuralCompressor.compress("<html><body>tiny</body></html>", droppedHandle: ""))
        XCTAssertNil(
            HTMLStructuralCompressor.compress("<html><body>tiny</body></html>", droppedHandle: "html123"),
            "tiny HTML should fail open because a retrieve marker costs more than it saves"
        )
    }
}
