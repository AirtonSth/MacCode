import AgentRuntime
import DistillCore
import Darwin
import Foundation
import XCTest

/// P5-T5 perf gate. Measures per-mode p95 distill latency on the real MLX model on THIS
/// device. Gated behind the same env var as the live-model test (requires the model);
/// skips loudly otherwise (never a silent pass). Numbers are printed for the record.
final class DistillLivePerfTests: XCTestCase {
    func test_perModeWarmLatencyWithinBudget() async throws {
        guard ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip("MANUAL: set REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_TEST=1 (+ model dir) to run the live perf gate.")
        }
        let supportDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_DIR"]
                ?? "/tmp/RemoteCodeTokenSaverLiveModel",
            isDirectory: true
        )
        let installer = TokenSaverModelInstaller(appSupportDirectory: supportDirectory)
        let downloader = TokenSaverModelDownloader(installer: installer)
        let manifest = try await downloader.downloadApprovedModel { _ in }
        let runtime = try await MLXDistillRuntime(modelDirectory: installer.modelStorageDirectory(revision: manifest.revision))

        // Pay cold-start before measuring (proves warmup removes the first-call cost).
        try await runtime.warmup()

        // Budget: a warm distill on Apple Silicon must stay well under the per-call
        // deadline (default 20s). 18s p95 leaves headroom while catching a stall.
        let budgetMs: Double = 18_000
        let device = sysModel()

        for mode in [DistillMode.commandOutput, .longText] {
            var samples: [Double] = []
            let input = String(repeating: "build step \(mode.rawValue): compiled module, 0 warnings, exit 0\n", count: 12)
            for _ in 0..<6 {
                let start = DispatchTime.now()
                _ = try await runtime.distill(DistillRequest(mode: mode, input: input, maxOutputCharacters: 400))
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                samples.append(ms)
            }
            let p95 = percentile(samples, 0.95)
            print("TokenSaverPerf device=\(device) mode=\(mode.rawValue) p95=\(Int(p95))ms samples=\(samples.map { Int($0) })")
            XCTAssertLessThanOrEqual(p95, budgetMs, "mode \(mode.rawValue) p95 \(Int(p95))ms exceeds \(Int(budgetMs))ms budget on \(device)")
        }
    }

    func test_warmGenerationRSSStaysBelowCeiling() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip("MANUAL: set REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_TEST=1 (+ model dir) to run the live RSS gate.")
        }

        let ceilingGB = Double(env["REMOTE_CODE_TOKEN_SAVER_RSS_CEILING_GB"] ?? "21") ?? 21
        let ceilingBytes = UInt64(ceilingGB * 1024 * 1024 * 1024)
        let supportDirectory = URL(
            fileURLWithPath: env["REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_DIR"]
                ?? "/tmp/RemoteCodeTokenSaverLiveModel",
            isDirectory: true
        )
        let installer = TokenSaverModelInstaller(appSupportDirectory: supportDirectory)
        let downloader = TokenSaverModelDownloader(installer: installer)
        let manifest = try await downloader.downloadApprovedModel { _ in }
        let runtime = try await MLXDistillRuntime(modelDirectory: installer.modelStorageDirectory(revision: manifest.revision))

        try await runtime.warmup()
        for i in 0..<4 {
            _ = try await runtime.distill(DistillRequest(
                mode: .longText,
                input: String(repeating: "RSS guard sample \(i): RemoteCode Token Saver must not grow without bound.\n", count: 16),
                maxOutputCharacters: 400
            ))
        }

        let footprint = try currentPhysicalFootprintBytes()
        print("TokenSaverRSS device=\(sysModel()) footprintBytes=\(footprint) ceilingBytes=\(ceilingBytes)")
        XCTAssertGreaterThan(footprint, 0, "RSS/physical-footprint probe must return a real value")
        XCTAssertLessThanOrEqual(footprint, ceilingBytes,
                                 "warm MLX generation footprint \(footprint) exceeds \(ceilingBytes)-byte ceiling")
    }

    private func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * q).rounded(.up))
        return sorted[min(idx, sorted.count - 1)]
    }

    private func sysModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
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
}
