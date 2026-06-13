import XCTest
import Darwin
import CoreModel
@testable import Surfaces

@MainActor
final class TerminalSurfaceTeardownLeakTests: XCTestCase {
    func test_createStreamCloseTerminalSurfacesKeepsFDsAndFootprintBounded() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RC2_TERMINAL_TEARDOWN_STRESS"] == "1" else {
            throw XCTSkip("set RC2_TERMINAL_TEARDOWN_STRESS=1 to run terminal teardown/leak stress")
        }
        let iterations = Int(env["RC2_TERMINAL_TEARDOWN_ITERATIONS"] ?? "100") ?? 100
        let maxFDGrowth = Int(env["RC2_TERMINAL_TEARDOWN_MAX_FD_GROWTH"] ?? "8") ?? 8
        let maxFootprintGrowthMB = UInt64(env["RC2_TERMINAL_TEARDOWN_MAX_FOOTPRINT_MB"] ?? "96") ?? 96

        let baselineFDs = try openFDCount()
        let baselineFootprint = try currentPhysicalFootprintBytes()

        for index in 0..<iterations {
            try autoreleasepool {
                let surface = try TerminalSurface(
                    workspaceID: WorkspaceID(),
                    title: "teardown-\(index)",
                    launch: .shell(cwd: NSTemporaryDirectory())
                )
                let marker = "RC2_TEARDOWN_\(index)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                XCTAssertEqual(surface.sendTextStatus("printf '\\n\(marker)\\n'; exit 0\n"), .accepted,
                               "terminal \(index) must accept input before teardown")
                _ = try waitForSnapshot(surface, containing: marker)
                _ = try waitForDead(surface)
                surface.close()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let finalFDs = try openFDCount()
        let finalFootprint = try currentPhysicalFootprintBytes()
        let fdGrowth = finalFDs - baselineFDs
        let footprintGrowth = finalFootprint > baselineFootprint ? finalFootprint - baselineFootprint : 0
        let maxFootprintGrowthBytes = maxFootprintGrowthMB * 1024 * 1024

        print("TerminalTeardownStress iterations=\(iterations) baselineFDs=\(baselineFDs) finalFDs=\(finalFDs) fdGrowth=\(fdGrowth) baselineFootprint=\(baselineFootprint) finalFootprint=\(finalFootprint) footprintGrowth=\(footprintGrowth)")
        XCTAssertLessThanOrEqual(fdGrowth, maxFDGrowth,
                                 "creating/closing \(iterations) terminals must return fd count near baseline")
        XCTAssertLessThanOrEqual(footprintGrowth, maxFootprintGrowthBytes,
                                 "creating/closing \(iterations) terminals must not grow physical footprint beyond \(maxFootprintGrowthMB) MB")
    }

    private func waitForSnapshot(_ surface: TerminalSurface, containing needle: String, timeout: TimeInterval = 6) throws -> TerminalTextSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var last = surface.readTextSnapshot()
        while Date() < deadline {
            last = surface.readTextSnapshot()
            if last.text.contains(needle) { return last }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for terminal output containing \(needle); last tail=\(String(last.text.suffix(240)))")
        throw WaitTimeout(reason: "terminal output \(needle)")
    }

    private func waitForDead(_ surface: TerminalSurface, timeout: TimeInterval = 6) throws -> TerminalRuntimeHealth {
        let deadline = Date().addingTimeInterval(timeout)
        var last = surface.runtimeHealth()
        while Date() < deadline {
            last = surface.runtimeHealth()
            if !last.processAlive { return last }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for terminal process exit; last health=\(last)")
        throw WaitTimeout(reason: "terminal dead")
    }

    private func openFDCount() throws -> Int {
        let entries = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
        return entries.compactMap(Int.init).count
    }

    private func currentPhysicalFootprintBytes() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: "task_info(TASK_VM_INFO) failed with \(result)"
            ])
        }
        return info.phys_footprint
    }

    private struct WaitTimeout: Error, CustomStringConvertible {
        let reason: String
        var description: String { "timed out waiting for \(reason)" }
    }
}
