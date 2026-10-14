import XCTest
import Darwin
import AgentRuntime
@testable import Surfaces

/// WHY: the Agent App branch chip + changed-files header reloads on every
/// surface load and after every finished run, once per open tab. It used to
/// run `GitDiff.branches` only to keep `.current`, then `GitDiff.summary`,
/// which repeats `isGit` and `rev-parse --abbrev-ref HEAD`: 8 git spawns per
/// refresh where 5 give the same answer.
final class AgentGitHeaderLoadTests: XCTestCase {
    func test_gitHeaderLoad_spawnsOnlyTheSummaryCommands() throws {
        let shimDir = NSTemporaryDirectory() + "rc2-git-count-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: shimDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: shimDir) }
        let log = shimDir + "/calls.log"
        let shim = shimDir + "/git"
        try """
        #!/bin/sh
        echo "$*" >> '\(log)'
        case "$*" in
          *--is-inside-work-tree*) echo "true" ;;
          *--abbrev-ref*) echo "feature/x" ;;
        esac
        """.write(toFile: shim, atomically: true, encoding: .utf8)
        chmod(shim, 0o755)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", shimDir + ":" + originalPath, 1)
        defer { setenv("PATH", originalPath, 1) }

        let header = AgentAppViewModel.loadGitHeader(cwd: shimDir)

        let calls = (try String(contentsOfFile: log, encoding: .utf8)).split(separator: "\n")
        NSLog("[perf-proof] agent git header spawns=%d", calls.count)
        XCTAssertEqual(header.branch, "feature/x")
        XCTAssertEqual(header.summary.branch, "feature/x")
        XCTAssertTrue(header.summary.isGitRepo)
        XCTAssertEqual(calls.count, 5, "one header refresh must cost exactly the summary's git spawns: \(calls)")
    }

    /// Wall time of one header refresh on a real repo. Skipped unless
    /// `RC_PERF_GIT_REPO` names one; warms once, prints the median.
    func test_bench_gitHeaderLoad() throws {
        let repo = try benchRepo()
        bench("agent.gitHeaderLoad") { _ = AgentAppViewModel.loadGitHeader(cwd: repo) }
    }

    /// One git spawn through `GitDiff.runCommand`, to separate per-spawn cost
    /// from the number of spawns.
    func test_bench_singleGitProbe() throws {
        let repo = try benchRepo()
        bench("gitDiff.isGit") { _ = GitDiff.isGit(repo) }
    }

    private func benchRepo() throws -> String {
        guard let repo = ProcessInfo.processInfo.environment["RC_PERF_GIT_REPO"], !repo.isEmpty else {
            throw XCTSkip("RC_PERF_GIT_REPO is not set")
        }
        return repo
    }

    private func bench(_ name: String, _ body: () -> Void) {
        let count = Int(ProcessInfo.processInfo.environment["RC_PERF_SAMPLES"] ?? "") ?? 7
        body()
        var samples: [Double] = []
        for _ in 0..<count {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let median = samples.sorted()[samples.count / 2]
        let rendered = samples.map { String(format: "%.2f", $0) }.joined(separator: ",")
        print("PERF_BENCH name=\(name) median_ms=\(String(format: "%.2f", median)) samples_ms=[\(rendered)]")
    }
}
