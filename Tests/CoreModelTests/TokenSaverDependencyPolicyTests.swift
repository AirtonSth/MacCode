import XCTest

final class TokenSaverDependencyPolicyTests: XCTestCase {
    func test_packageDoesNotAddDisallowedTokenSaverRuntimeDependencies() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let forbiddenDependencies = [
            "headroom",
            "onnxruntime",
            "onnx-runtime",
            "tree-sitter",
            "PythonKit",
            "Rust"
        ]

        for dependency in forbiddenDependencies {
            XCTAssertFalse(
                package.localizedCaseInsensitiveContains(dependency),
                "N1/F7: Token Saver must not add \(dependency) as a SwiftPM dependency"
            )
        }

        XCTAssertTrue(package.contains("mlx-swift"), "F7: Core ML/MLX is the native Token Saver runtime path")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
