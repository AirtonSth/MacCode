// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteCode",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RemoteCode", targets: ["AppShell"]),
        .executable(name: "RemoteCodeDistillService", targets: ["RemoteCodeDistillService"]),
        .executable(name: "rc2", targets: ["RC2CLI"]),
        .library(name: "CoreModel", targets: ["CoreModel"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .library(name: "DistillCore", targets: ["DistillCore"]),
        .library(name: "SocketServer", targets: ["SocketServer"]),
        .library(name: "Surfaces", targets: ["Surfaces"]),
        .library(name: "DesignSystemKit", targets: ["DesignSystemKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        // Direct dependency on mlx-swift (already resolved transitively by mlx-swift-lm)
        // so DistillCore can `import MLX` to bound the Metal buffer cache. Constraint
        // mirrors mlx-swift-lm's to keep resolution to the same revision.
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .target(
            name: "RemoteCodeCSystem",
            path: "Sources/CSystem",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CoreModel",
            path: "Sources/CoreModel"
        ),
        .target(
            name: "Persistence",
            dependencies: ["CoreModel"],
            path: "Sources/Persistence",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "AgentRuntime",
            dependencies: ["CoreModel", "Persistence", "RemoteCodeCSystem"],
            path: "Sources/AgentRuntime"
        ),
        .target(
            name: "DistillCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/DistillCore"
        ),
        .executableTarget(
            name: "RemoteCodeDistillService",
            dependencies: ["DistillCore", "AgentRuntime", "Persistence"],
            path: "Sources/RemoteCodeDistillService"
        ),
        .target(
            name: "SocketServer",
            dependencies: ["CoreModel", "Persistence", "AgentRuntime"],
            path: "Sources/SocketServer"
        ),
        .target(
            name: "DesignSystemKit",
            path: "Sources/DesignSystemKit"
        ),
        .target(
            name: "Surfaces",
            dependencies: ["CoreModel", "AgentRuntime", "Persistence", "RemoteCodeCSystem", "DesignSystemKit", "GhosttyKit"],
            path: "Sources/Surfaces",
            resources: [
                .copy("Resources/ghostty")
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
                .linkedFramework("GameController")
            ]
        ),
        .executableTarget(
            name: "AppShell",
            dependencies: [
                "CoreModel",
                "Persistence",
                "AgentRuntime",
                "DistillCore",
                "SocketServer",
                "Surfaces",
                "DesignSystemKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/AppShell",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "RC2CLI",
            dependencies: ["CoreModel"],
            path: "Sources/RC2CLI"
        ),
        .testTarget(
            name: "CoreModelTests",
            dependencies: ["CoreModel"],
            path: "Tests/CoreModelTests"
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", "CoreModel"],
            path: "Tests/PersistenceTests"
        ),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime", "CoreModel"],
            path: "Tests/AgentRuntimeTests"
        ),
        .testTarget(
            name: "DistillCoreTests",
            dependencies: ["DistillCore", "AgentRuntime"],
            path: "Tests/DistillCoreTests"
        ),
        .testTarget(
            name: "SocketServerTests",
            dependencies: ["SocketServer", "CoreModel", "Persistence"],
            path: "Tests/SocketServerTests"
        ),
        .testTarget(
            name: "SurfacesTests",
            dependencies: ["Surfaces", "CoreModel", "AgentRuntime"],
            path: "Tests/SurfacesTests"
        ),
        .testTarget(
            name: "AppShellTests",
            dependencies: ["AppShell", "CoreModel", "Persistence", "SocketServer", "Surfaces"],
            path: "Tests/AppShellTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
