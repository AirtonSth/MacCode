// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteCode2",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RemoteCode2", targets: ["AppShell"]),
        .executable(name: "rc2", targets: ["RC2CLI"]),
        .library(name: "CoreModel", targets: ["CoreModel"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .library(name: "SocketServer", targets: ["SocketServer"]),
        .library(name: "Surfaces", targets: ["Surfaces"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CSystem",
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
            dependencies: ["CoreModel", "Persistence"],
            path: "Sources/AgentRuntime"
        ),
        .target(
            name: "SocketServer",
            dependencies: ["CoreModel", "Persistence", "AgentRuntime"],
            path: "Sources/SocketServer"
        ),
        .target(
            name: "Surfaces",
            dependencies: ["CoreModel", "AgentRuntime", "Persistence", "CSystem"],
            path: "Sources/Surfaces"
        ),
        .executableTarget(
            name: "AppShell",
            dependencies: ["CoreModel", "Persistence", "AgentRuntime", "SocketServer", "Surfaces"],
            path: "Sources/AppShell"
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
            name: "SocketServerTests",
            dependencies: ["SocketServer", "CoreModel", "Persistence"],
            path: "Tests/SocketServerTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
