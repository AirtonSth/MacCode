import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AgentRuntime

final class PrivateDirectoryTreeTests: XCTestCase {
    private func withDirectories(_ body: (URL, PrivateDirectory, URL, PrivateDirectory) throws -> Void) throws {
        guard let probeRoot = ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"] else {
            XCTFail("RC_CONTEXT_PROBE_ROOT must name caller-owned scratch space")
            return
        }
        let root = URL(fileURLWithPath: probeRoot, isDirectory: true)
            .appendingPathComponent("private-directory-tree-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        let destinationURL = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try PrivateDirectory(sourceURL, create: false)
        let destination = try PrivateDirectory(destinationURL, create: false)
        defer { source.close(); destination.close() }
        try body(root, source, destinationURL, destination)
    }

    func testCopyStreamsTreeAndExcludesOnlyRootConfiguration() throws {
        try withDirectories { root, source, destinationURL, destination in
            let nested = try source.child("nested", create: true)
            defer { nested.close() }
            try Data("nested payload".utf8).write(to: URL(fileURLWithPath: nested.path).appendingPathComponent("file.txt"))
            let empty = try nested.child("empty", create: true)
            empty.close()
            let binary = Data((0..<2 * 1024 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            try binary.write(to: URL(fileURLWithPath: source.path).appendingPathComponent("large.bin"))
            try Data("exclude".utf8).write(to: URL(fileURLWithPath: source.path).appendingPathComponent("config.toml"))

            let sourceInventory = try PrivateDirectoryTree.inventory(source, excludingRootNames: ["config.toml"])
            let copiedInventory = try PrivateDirectoryTree.copy(from: source, to: destination, excludingRootNames: ["config.toml"])
            XCTAssertEqual(copiedInventory, sourceInventory)
            XCTAssertEqual(try PrivateDirectoryTree.inventory(destination), sourceInventory)
            XCTAssertEqual(try PrivateDirectoryTree.inventory(source, excludingRootNames: ["config.toml"]), sourceInventory)
            XCTAssertEqual(try PrivateDirectoryTree.inventory(source, excludingRootNames: ["config.toml"]), sourceInventory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.appendingPathComponent("config.toml").path))
            let hash = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(sourceInventory.first(where: { $0.path == "large.bin" })?.sha256, hash)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destinationURL.appendingPathComponent("large.bin").path)[.size] as? Int, binary.count)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("source/config.toml").path))
        }
    }

    func testRejectsSymlinkHardLinkAndFIFOWithoutFollowingOrBlocking() throws {
        try withDirectories { root, source, destinationURL, destination in
            let sourceURL = URL(fileURLWithPath: source.path)
            let outside = root.appendingPathComponent("outside")
            try Data("original".utf8).write(to: outside)
            XCTAssertEqual(symlink(outside.path, sourceURL.appendingPathComponent("link").path), 0)
            XCTAssertThrowsError(try PrivateDirectoryTree.inventory(source))
            XCTAssertEqual(try Data(contentsOf: outside), Data("original".utf8))
            XCTAssertEqual(unlink(sourceURL.appendingPathComponent("link").path), 0)

            let regular = sourceURL.appendingPathComponent("regular")
            try Data("unchanged".utf8).write(to: regular)
            XCTAssertEqual(link(regular.path, sourceURL.appendingPathComponent("hardlink").path), 0)
            XCTAssertThrowsError(try PrivateDirectoryTree.inventory(source))
            XCTAssertEqual(try Data(contentsOf: regular), Data("unchanged".utf8))
            XCTAssertEqual(unlink(sourceURL.appendingPathComponent("hardlink").path), 0)

            XCTAssertEqual(mkfifo(sourceURL.appendingPathComponent("pipe").path, 0o600), 0)
            let finished = expectation(description: "FIFO inventory returns promptly")
            DispatchQueue.global().async {
                defer { finished.fulfill() }
                do {
                    _ = try PrivateDirectoryTree.inventory(source)
                    XCTFail("FIFO inventory should fail")
                } catch {
                    // Expected: unsupported FIFO must fail without blocking.
                }
            }
            wait(for: [finished], timeout: 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        }
    }

    func testInventoryBoundsFlatDirectoryNames() throws {
        try withDirectories { _, source, _, _ in
            let sourceURL = URL(fileURLWithPath: source.path)
            for index in 0...100_000 {
                XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.appendingPathComponent("item-\(index)").path, contents: Data()))
            }
            XCTAssertThrowsError(try PrivateDirectoryTree.inventory(source))
        }
    }
    func testRenameIsExclusiveAndRemoveIsStrict() throws {
        try withDirectories { _, source, _, destination in
            try Data("source".utf8).write(to: URL(fileURLWithPath: source.path).appendingPathComponent("item"))
            try Data("destination".utf8).write(to: URL(fileURLWithPath: destination.path).appendingPathComponent("item"))
            XCTAssertThrowsError(try PrivateDirectoryTree.renameChild("item", from: source, to: destination, as: "item"))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source.path).appendingPathComponent("item")), Data("source".utf8))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path).appendingPathComponent("item")), Data("destination".utf8))
            XCTAssertEqual(unlink(URL(fileURLWithPath: destination.path).appendingPathComponent("item").path), 0)
            try PrivateDirectoryTree.renameChild("item", from: source, to: destination, as: "renamed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: source.path).appendingPathComponent("item").path))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination.path).appendingPathComponent("renamed")), Data("source".utf8))
            try PrivateDirectoryTree.removeChild("renamed", from: destination)
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: destination.path).appendingPathComponent("renamed").path))
            XCTAssertThrowsError(try PrivateDirectoryTree.removeChild("renamed", from: destination))
        }
    }
}
