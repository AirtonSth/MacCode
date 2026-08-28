import XCTest

final class ScheduledTaskPackageScriptTests: XCTestCase {
    func test_packagerEmbedsLaunchAgentWithHeadlessArgument_becauseSchedulesMustSurviveAppExit() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/package-app.sh"), encoding: .utf8)
        XCTAssertTrue(source.contains("Contents/Library/LaunchAgents"))
        XCTAssertTrue(source.contains("--scheduled-task-agent"))
        XCTAssertTrue(source.contains("BundleProgram"))
        XCTAssertTrue(source.contains("MachServices"))
        XCTAssertTrue(source.contains("KeepAlive"))
        XCTAssertTrue(source.contains("RC2_CODESIGN_IDENTITY"))
        XCTAssertTrue(source.contains("Contents/Resources/RemoteCodeScheduledTaskAgent"))
        XCTAssertTrue(source.contains("RC2_DISABLE_MANAGED_DISTILL_RECONCILE"))
        XCTAssertTrue(source.contains("RC2_SCHEDULED_TASK_AGENT"))
    }

    func test_bundleValidatorRequiresLaunchAgent_becauseMissingPackagingMustFailCI() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/check-app-bundle.sh"), encoding: .utf8)
        XCTAssertTrue(source.contains("missing Scheduled Tasks LaunchAgent"))
        XCTAssertTrue(source.contains("Scheduled Tasks headless argument is missing"))
    }

    func test_codesignMetadataSummaryConsumesLargeOutput_underPipefail() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/package-app.sh"),
            encoding: .utf8
        )
        let beginMarker = "# BEGIN codesign metadata summary parser"
        let endMarker = "# END codesign metadata summary parser"
        guard let begin = source.range(of: beginMarker),
              let end = source.range(of: endMarker, range: begin.upperBound..<source.endIndex) else {
            XCTFail("package script must contain the production codesign metadata parser")
            return
        }
        let parser = String(source[begin.lowerBound..<end.upperBound])
        XCTAssertTrue(parser.contains("while IFS= read -r"))
        XCTAssertTrue(parser.contains("done <<< \"$sign_meta\""))
        XCTAssertFalse(parser.contains("| awk"), "metadata parsing must not leave printf exposed to an early parser exit")

        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        \(parser)
        sign_meta=$'Executable=/tmp/RemoteCode\\nTeamIdentifier=TEAM123\\nflags=0x10000(runtime)'
        for index in $(seq 1 20000); do
          sign_meta+=$'\\nmetadata-'"$index"'=padding-padding-padding-padding-padding-padding-padding-padding'
        done
        summary="$(codesign_metadata_summary "$sign_meta")"
        [[ "$summary" == 'codesign team=TEAM123 class=durable flags=runtime' ]]
        """

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "large codesign metadata must not trip pipefail: \(stderr)")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
