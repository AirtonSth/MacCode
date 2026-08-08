import Foundation

public struct CacheAlignerVolatileTokenScan: Sendable, Equatable {
    public let uuidCount: Int
    public let iso8601Count: Int
    public let jwtCount: Int
    public let hexCount: Int

    public var warningCount: Int {
        uuidCount + iso8601Count + jwtCount + hexCount
    }
}

public enum CacheAlignerVolatileTokenDetector {
    private static let patterns: [(WritableKeyPath<Counts, Int>, NSRegularExpression)] = [
        (\.uuid, try! NSRegularExpression(pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#)),
        (\.iso8601, try! NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?\b"#)),
        (\.jwt, try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#)),
        (\.hex, try! NSRegularExpression(pattern: #"\b[0-9a-fA-F]{16,}\b"#))
    ]

    public static func scan(_ text: String) -> CacheAlignerVolatileTokenScan {
        var counts = Counts()
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for (keyPath, regex) in patterns {
            counts[keyPath: keyPath] = regex.numberOfMatches(in: text, range: range)
        }
        return CacheAlignerVolatileTokenScan(
            uuidCount: counts.uuid,
            iso8601Count: counts.iso8601,
            jwtCount: counts.jwt,
            hexCount: counts.hex
        )
    }

    private struct Counts {
        var uuid = 0
        var iso8601 = 0
        var jwt = 0
        var hex = 0
    }
}

public enum CacheAlignerPromptContract {
    public static func systemPromptHash(for request: DistillRequest) -> String {
        let contract = [
            "mode=\(request.mode.rawValue)",
            "runMode=\(request.effectiveRunMode.rawValue)",
            "question=\(request.question ?? "")",
            "rerankQuery=\(request.rerankQuery ?? "")",
            "encoderLane=\(request.encoderLane ?? "")",
            "cacheState=\(request.cacheState ?? "")",
            "maxOutputCharacters=\(request.maxOutputCharacters)"
        ].joined(separator: "\n")

        // PERF: DistillSHA256 contiguous UTF-8 + nibble hex (not Data(utf8) +
        // String(format:)) on every distill metrics prompt-hash record.
        return DistillSHA256.hex(contract)
    }
}
