import DistillCore
import Foundation

/// Test double for the shipped `LibrarianGenerating` seam. Returns extractive JSON
/// whose `span` is a substring of the source block in the prompt — the same
/// contract the oMLX runtime must satisfy.
struct LibrarianScriptedGenerate: LibrarianGenerating {
    func generate(_ call: LibrarianGenerateCall) async -> String? {
        let user = call.user
        let source: String
        if let range = user.range(of: "Source (cite exact substrings only):\n") {
            source = String(user[range.upperBound...])
        } else {
            source = user
        }
        let span = source
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.count >= 4
                    && !trimmed.hasPrefix("Op:")
                    && !trimmed.hasPrefix("Question:")
                    && !trimmed.hasPrefix("Return ")
            }) ?? String(source.prefix(16))
        let payload: [String: String] = ["answer": span, "span": span]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}

/// Scripted generate wrapped the way Ornith-1.5 emits reasoning: a `<think>`
/// block plus a `reasoning_content` JSON key. The shipped strip path must
/// drop both before paid-facing text is recorded.
struct LibrarianThinkWrappedGenerate: LibrarianGenerating {
    let inner = LibrarianScriptedGenerate()

    func generate(_ call: LibrarianGenerateCall) async -> String? {
        guard let body = await inner.generate(call),
              let data = body.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "<think>hidden chain</think>\n{\"answer\":\"x\",\"span\":\"x\",\"reasoning_content\":\"NOPE\"}"
        }
        object["reasoning_content"] = "internal scratch that must never reach paid context"
        guard let encoded = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: encoded, encoding: .utf8) else {
            return nil
        }
        return "<think>secret chain of thought about billing</think>\n" + json
    }
}
