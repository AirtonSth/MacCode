import Foundation

/// A lightweight in-process git-repo builder for unit tests.
///
/// Creates a real bare-minimum git repository in /tmp, exposes helpers
/// to add commits, dirty files, branches, and binary files, then
/// removes the directory on `cleanup()` or when `defer { fixture.cleanup() }`
/// is used.
///
/// Ownership: shared test helper; used by AgentRuntimeTests + SurfacesTests.
/// WHY: T028-T035 tests each built temp repos inline (mkTmpRepo / seed helpers
/// duplicated across GitDiffTests + DiffPanelViewModelTests). A single
/// shared fixture eliminates that duplication and gives consistent repo
/// topology for all git-related tests.
public struct GitRepoFixture {

    // MARK: - Public API

    /// Absolute path to the repository root.
    public let path: String

    /// Initialise and configure a new bare-minimum git repo in /tmp.
    /// Throws if git init or config fails unexpectedly.
    public init(prefix: String = "rc2-fixture") throws {
        let dir = NSTemporaryDirectory() + prefix + "-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        Self.run(["git", "init", "-q", "-b", "main", dir])
        Self.run(["git", "-C", dir, "config", "user.email", "fixture@rc2.test"])
        Self.run(["git", "-C", dir, "config", "user.name", "Fixture"])
        path = dir
    }

    // MARK: - Commit helpers

    /// Write `content` to `filename` in the repo root and stage+commit it.
    /// Returns self for chaining.
    @discardableResult
    public func commit(file filename: String,
                       content: String = "initial\n",
                       message: String = "init") throws -> GitRepoFixture {
        let filePath = path + "/" + filename
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        Self.run(["git", "-C", path, "add", filename])
        Self.run(["git", "-C", path, "commit", "-q", "-m", message])
        return self
    }

    /// Write multiple (filename, content) pairs and make one commit.
    @discardableResult
    public func commit(files: [(name: String, content: String)],
                       message: String = "batch commit") throws -> GitRepoFixture {
        for (name, content) in files {
            try content.write(toFile: path + "/" + name, atomically: true, encoding: .utf8)
            Self.run(["git", "-C", path, "add", name])
        }
        Self.run(["git", "-C", path, "commit", "-q", "-m", message])
        return self
    }

    // MARK: - Dirty / untracked helpers

    /// Write `content` to `filename` without staging it.
    /// If the file was previously committed this creates a working-tree modification.
    /// If it is new it becomes untracked.
    @discardableResult
    public func writeUnstaged(file filename: String,
                              content: String = "dirty\n") throws -> GitRepoFixture {
        try content.write(toFile: path + "/" + filename,
                          atomically: true, encoding: .utf8)
        return self
    }

    /// Delete a tracked file from the working tree without staging the deletion.
    @discardableResult
    public func deleteUnstaged(file filename: String) throws -> GitRepoFixture {
        try FileManager.default.removeItem(atPath: path + "/" + filename)
        return self
    }

    // MARK: - Branch helpers

    /// Create a local branch (does not switch HEAD).
    @discardableResult
    public func createBranch(named name: String) -> GitRepoFixture {
        Self.run(["git", "-C", path, "branch", name])
        return self
    }

    /// Create and checkout a branch.
    @discardableResult
    public func checkoutNewBranch(named name: String) -> GitRepoFixture {
        Self.run(["git", "-C", path, "checkout", "-qb", name])
        return self
    }

    /// Switch to an existing branch.
    @discardableResult
    public func checkout(branch name: String) -> GitRepoFixture {
        Self.run(["git", "-C", path, "checkout", "-q", name])
        return self
    }

    // MARK: - Binary file helper

    /// Write a minimal PNG header (8 bytes) as a binary file and commit it.
    /// WHY: verifies that diff output is handled when binary files are present.
    @discardableResult
    public func commitBinaryFile(named filename: String = "image.png",
                                 message: String = "add binary") throws -> GitRepoFixture {
        let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let data = Data(pngHeader)
        let filePath = path + "/" + filename
        try data.write(to: URL(fileURLWithPath: filePath))
        Self.run(["git", "-C", path, "add", filename])
        Self.run(["git", "-C", path, "commit", "-q", "-m", message])
        return self
    }

    // MARK: - Remote helpers

    /// Add a local bare repo as `origin` and push `main`.
    /// Returns the bare repo path (caller should include it in their `defer` cleanup).
    @discardableResult
    public func addLocalRemote() throws -> String {
        let bare = NSTemporaryDirectory() + "rc2-bare-" + UUID().uuidString + ".git"
        Self.run(["git", "init", "--bare", "-q", bare])
        Self.run(["git", "-C", path, "remote", "add", "origin", bare])
        Self.run(["git", "-C", path, "push", "-q", "origin", "main"])
        return bare
    }

    // MARK: - Shell helpers

    /// Run a git command and capture stdout as a String.
    public func shell(_ args: [String]) -> String {
        Self.shell(args)
    }

    // MARK: - Cleanup

    /// Delete the repo directory.  Call from `defer` in each test method.
    public func cleanup() {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Internal process helpers

    @discardableResult
    static func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        // Suppress git output so test logs stay clean.
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func shell(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8) ?? ""
    }
}
