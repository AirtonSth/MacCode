import XCTest
@testable import DistillCore

final class SourceCodeSkeletonizerTests: XCTestCase {
    func test_skeletonizeElidesSwiftFunctionBodyButPreservesSignatureAndHandle() throws {
        let body = (0..<40)
            .map { "        let value\($0) = input + \($0)" }
            .joined(separator: "\n")
        let source = """
        import Foundation

        struct Renderer {
            public func render(input: Int) -> String {
        \(body)
                return String(value39)
            }
        }
        """

        let skeleton = try XCTUnwrap(SourceCodeSkeletonizer.skeletonize(source, droppedHandle: "[[rc:abc123]]"))
        XCTAssertTrue(skeleton.contains("public func render(input: Int) -> String {"))
        XCTAssertTrue(skeleton.contains("[[rc:abc123]]"))
        XCTAssertTrue(skeleton.contains("code lines elided"))
        XCTAssertTrue(skeleton.contains("struct Renderer {"))
        XCTAssertFalse(skeleton.contains("let value39 = input + 39"))
        XCTAssertLessThan(skeleton.count, source.count)
    }

    func test_skeletonizeElidesPythonFunctionByIndentation() throws {
        let body = (0..<30)
            .map { "    value_\($0) = input_value + \($0)" }
            .joined(separator: "\n")
        let source = """
        def compute(input_value):
        \(body)
            return value_29

        def keep_signature():
            return "ok"
        """

        let skeleton = try XCTUnwrap(SourceCodeSkeletonizer.skeletonize(source, droppedHandle: "pyhandle"))
        XCTAssertTrue(skeleton.contains("def compute(input_value):"))
        XCTAssertTrue(skeleton.contains("[[rc:pyhandle]]"))
        XCTAssertFalse(skeleton.contains("value_29 = input_value + 29"))
        XCTAssertTrue(skeleton.contains("def keep_signature():"))
    }

    func test_skeletonizeRequiresStoreHandleAndWorthwhileSavings() {
        let source = """
        func tiny() {
            return 1
        }
        """

        XCTAssertNil(SourceCodeSkeletonizer.skeletonize(source, droppedHandle: ""))
        XCTAssertNil(
            SourceCodeSkeletonizer.skeletonize(source, droppedHandle: "abc123"),
            "small source should pass through because the retrieve marker would cost more than it saves"
        )
    }

    func test_routerStillFallsThroughForSourceCodeWithoutStoreBackedSkeletonizer() {
        let source = """
        import Foundation
        func run() -> String {
            return "ok"
        }
        """

        let router = DistillContentRouter()
        XCTAssertEqual(router.classify(source), .sourceCode)
        XCTAssertNil(router.route(source))
    }
}
