import Foundation
import XCTest
@testable import DistillCore

/// Live Ornith-1.5-9B-MLX-4bit benchmark. Skips unless
/// `RC_LIBRARIAN_GENERATE_BASE_URL` and `RC_LIBRARIAN_GENERATE_MODEL` are set
/// and the model id names Ornith-1.5-9B. Ship default is not this class.
final class Ornith9BBenchmarkTests: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 4 * 60 * 60
    }

    func test_allCatalogIDs_onOrnith9B() async throws {
        let runtime = try liveRuntime()
        let dispatcher = LibrarianDispatcher(generate: LibrarianInstrumentedGenerate(runtime))
        if let generate = dispatcher.generate, !(generate is LibrarianInstrumentedGenerate) {
            dispatcher.generate = LibrarianInstrumentedGenerate(generate)
        }
        var rows: [LibrarianProbeRecord] = []
        let ids = LibrarianCatalog.ids
        for (index, id) in ids.enumerated() {
            FileHandle.standardError.write(Data("ornith-bench \(index + 1)/\(ids.count) \(id)\n".utf8))
            rows.append(await LibrarianProbe.run(id: id, dispatcher: dispatcher, model: runtime.model))
        }
        XCTAssertEqual(rows.count, 188)
        XCTAssertEqual(Set(rows.map(\.id)).count, 188)
        let forbidden = rows.filter { $0.safety == "forbidden" }
        XCTAssertFalse(forbidden.isEmpty)
        XCTAssertTrue(forbidden.allSatisfy { $0.status == "refused" || $0.status == "unavailable" })
        XCTAssertTrue(forbidden.allSatisfy { !$0.generateCalled })
        let thinkLeak = rows.filter {
            $0.status == "ok" && $0.usesLLM && (
                $0.paidText.contains("<think>")
                    || $0.paidText.contains("reasoning_content")
                    || $0.envelopeJSON.contains("<think>")
                    || $0.envelopeJSON.contains("reasoning_content")
            )
        }
        XCTAssertTrue(thinkLeak.isEmpty, "think leaked: \(thinkLeak.map(\.id))")
        let spanIDs: Set<String> = ["ask_handle", "cite_spans", "nli_claim"]
        for row in rows where spanIDs.contains(row.id) && row.status == "ok" {
            let fixture = LibrarianProbe.fixture(for: row.id, store: LibrarianHandleStore()).input
            if let data = row.envelopeJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let evidence = obj["evidence"] as? [[String: Any]] {
                for item in evidence {
                    let span = item["span"] as? String ?? ""
                    if !span.isEmpty {
                        XCTAssertTrue(fixture.contains(span), "\(row.id) span is not a substring")
                    }
                }
            }
        }
        if let out = ProcessInfo.processInfo.environment["ORNITH_9B_BENCH_OUT"], !out.isEmpty {
            let payload: [String: Any] = [
                "model": runtime.model,
                "base_url": runtime.baseURL.absoluteString,
                "rows": try rows.map { try encodeRow($0) },
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: out), options: .atomic)
        }
        if let summaryPath = ProcessInfo.processInfo.environment["ORNITH_9B_SUMMARY_OUT"], !summaryPath.isEmpty {
            try LibrarianProbe.summary(rows).write(toFile: summaryPath, atomically: true, encoding: .utf8)
        }
    }

    func test_askHandle_twice_onOrnith9B() async throws {
        let runtime = try liveRuntime()
        let original = "ERROR payment failed at Sources/Billing.swift:12\nretry ignored\n"
        for index in [1, 2] {
            let dispatcher = LibrarianDispatcher(generate: runtime)
            let handle = dispatcher.store.put(original)
            let result = await dispatcher.dispatch(LibrarianRequest(
                id: "ask_handle",
                question: "what failed?",
                handle: handle,
                provider: "grok"
            ))
            XCTAssertTrue([LibrarianStatus.ok, LibrarianStatus.lowConfidence, LibrarianStatus.unavailable].contains(result.status))
            XCTAssertFalse(result.text.contains("<think>"))
            XCTAssertFalse(result.text.contains("reasoning_content"))
            if result.status == .ok {
                let span = result.envelope?.evidence.first?.span ?? ""
                if !span.isEmpty {
                    XCTAssertTrue(original.contains(span))
                }
            }
            if let dir = ProcessInfo.processInfo.environment["ORNITH_9B_ASK_DIR"], !dir.isEmpty {
                let payload: [String: Any] = [
                    "status": result.status.rawValue,
                    "text": result.text,
                    "envelope": result.envelope?.jsonString() ?? "",
                    "saved_tokens": result.analytics.savedTokens,
                    "model": runtime.model,
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                try data.write(
                    to: URL(fileURLWithPath: dir).appendingPathComponent("ornith-9b-ask-\(index).json"),
                    options: .atomic
                )
            }
        }
    }

    private func liveRuntime() throws -> LibrarianOpenAICompatibleRuntime {
        let env = ProcessInfo.processInfo.environment
        let model = env["RC_LIBRARIAN_GENERATE_MODEL"] ?? ""
        guard model.contains("Ornith-1.5-9B") else {
            throw XCTSkip("RC_LIBRARIAN_GENERATE_MODEL must be the oMLX Ornith-1.5-9B id")
        }
        guard let runtime = LibrarianOpenAICompatibleRuntime(environment: env, timeout: 180) else {
            throw XCTSkip("RC_LIBRARIAN_GENERATE_BASE_URL not set")
        }
        return runtime
    }

    private func encodeRow(_ row: LibrarianProbeRecord) throws -> [String: Any] {
        let data = try JSONEncoder().encode(row)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }
}
