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
