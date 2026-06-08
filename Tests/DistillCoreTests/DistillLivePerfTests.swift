import AgentRuntime
import DistillCore
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
        await runtime.warmup()

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
}
