import Foundation

#if canImport(Vision)
import Vision
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

/// Media ops: on-device Vision OCR, screenshot diff, video keyframe OCR, local
/// speech transcription and spreadsheet extraction. All run on the Mac; none of
/// them sends bytes to a provider.
enum LibrarianMediaOps {
    // MARK: - screenshot_ocr

    static func screenshotOCR(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        guard let relative = request.paths.first ?? request.fileName, !relative.isEmpty else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "missing_image",
                text: "screenshot_ocr needs an image path"
            )
        }
        let path = LibrarianWorkspaceOps.absolute(relative, root: env.root(for: request))
        guard env.host.fileExists(path) else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "image_not_found",
                text: "no image at \(path)"
            )
        }
        guard let observations = LibrarianVisionOCR.recognize(path: path) else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "vision_ocr_unavailable",
                text: "Vision OCR could not decode \(path)"
            )
        }
        guard !observations.isEmpty else {
            return LibrarianHandlerOutput(
                status: .ok,
                text: "screenshot_ocr path=\(relative) text_blocks=0 (image decoded, no text detected)",
                originalForSavings: request.input
            )
        }
        var lines = ["screenshot_ocr path=\(relative) text_blocks=\(observations.count) mode=vision-on-device"]
        for observation in observations.prefix(60) {
            let box = observation.box
            lines.append(String(
                format: "%.3f\tx=%.3f y=%.3f w=%.3f h=%.3f\t%@",
                observation.confidence, box.x, box.y, box.width, box.height, observation.text
            ))
        }
        let joined = lines.joined(separator: "\n")
        _ = store.put(joined)
        return LibrarianHandlerOutput(status: .ok, text: joined, originalForSavings: request.input)
    }

    // MARK: - screenshot_diff_digest

    static func screenshotDiffDigest(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        guard request.paths.count >= 2 else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "two_image_paths_required",
                text: "screenshot_diff_digest needs two image paths"
            )
        }
        let root = env.root(for: request)
        let beforePath = LibrarianWorkspaceOps.absolute(request.paths[0], root: root)
        let afterPath = LibrarianWorkspaceOps.absolute(request.paths[1], root: root)
        guard let diff = LibrarianImageDiff.diff(before: beforePath, after: afterPath) else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "image_decode_failed",
                text: "could not decode both images (\(beforePath), \(afterPath))"
            )
        }
        var lines = [String(
            format: "screenshot_diff_digest before=%@ after=%@ size=%dx%d changed_pct=%.2f regions=%d",
            request.paths[0], request.paths[1], diff.width, diff.height, diff.changedPercent, diff.regions.count
        )]
        for region in diff.regions.prefix(12) {
            lines.append(String(
                format: "region x=%d y=%d w=%d h=%d changed=%.3f",
                region.x, region.y, region.width, region.height, region.changedFraction
            ))
        }
        if let afterText = LibrarianVisionOCR.recognize(path: afterPath), !afterText.isEmpty {
            lines.append("after_ocr:")
            lines.append(contentsOf: afterText.prefix(20).map { $0.text })
        }
        let joined = lines.joined(separator: "\n")
        _ = store.put(joined)
        return LibrarianHandlerOutput(status: .ok, text: joined, originalForSavings: request.input)
    }

    // MARK: - video_keyframe_ocr

    static func videoKeyframeOCR(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        guard let relative = request.paths.first ?? request.fileName, !relative.isEmpty else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "missing_video",
                text: "video_keyframe_ocr needs a video path"
            )
        }
        let path = LibrarianWorkspaceOps.absolute(relative, root: env.root(for: request))
        guard env.host.fileExists(path) else {
            return LibrarianWorkspaceOps.missingArgument(request, reason: "video_not_found", text: "no video at \(path)")
        }
        guard let frames = LibrarianVideoFrames.keyframes(path: path, count: request.topK ?? 6) else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "video_decode_failed",
                text: "could not decode \(path) as a video"
            )
        }
        var lines = ["video_keyframe_ocr path=\(relative) keyframes=\(frames.count) mode=avfoundation+vision"]
        for frame in frames {
            let observations = LibrarianVisionOCR.recognize(image: frame.image)
            let text = observations.map(\.text).joined(separator: " | ")
            lines.append(String(format: "t=%.2fs text_blocks=%d\t%@", frame.seconds, observations.count, text))
        }
        let joined = lines.joined(separator: "\n")
        _ = store.put(joined)
        return LibrarianHandlerOutput(status: .ok, text: joined, originalForSavings: request.input)
    }

    // MARK: - audio_transcribe_local

    static func audioTranscribeLocal(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        guard let relative = request.paths.first ?? request.fileName, !relative.isEmpty else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "missing_audio",
                text: "audio_transcribe_local needs an audio path"
            )
        }
        let path = LibrarianWorkspaceOps.absolute(relative, root: env.root(for: request))
        guard env.host.fileExists(path) else {
            return LibrarianWorkspaceOps.missingArgument(request, reason: "audio_not_found", text: "no audio at \(path)")
        }
        guard let transcriber = env.speech else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "speech_unavailable",
                text: "the system speech recognizer is not available on this host"
            )
        }
        switch transcriber.authorization {
        case .denied:
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "audio_transcribe_local speech_authorization=denied (grant microphone/speech access in System Settings)",
                envelope: .unavailable(op: request.id, reason: "speech_authorization_denied", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        case .notDetermined, .unavailable:
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "audio_transcribe_local speech_authorization=not_determined (no prompt is shown from a tool call)",
                envelope: .unavailable(op: request.id, reason: "speech_authorization_not_determined", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        case .authorized:
            break
        }
        guard let transcript = await transcriber.transcribe(path, request.locale ?? "en-US"), !transcript.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "audio_transcribe_local speech_state=no_transcript path=\(relative)",
                envelope: .unavailable(op: request.id, reason: "speech_no_transcript", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        let text = "audio_transcribe_local path=\(relative) mode=on-device-speech chars=\(transcript.count)\n\(transcript)"
        _ = store.put(text)
        return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: request.input)
    }

    // MARK: - spreadsheet_extract

    static func spreadsheetExtract(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        guard let relative = request.paths.first ?? request.fileName, !relative.isEmpty else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "missing_workbook",
                text: "spreadsheet_extract needs a workbook path"
            )
        }
        let path = LibrarianWorkspaceOps.absolute(relative, root: env.root(for: request))
        guard env.host.fileExists(path) else {
            return LibrarianWorkspaceOps.missingArgument(request, reason: "workbook_not_found", text: "no workbook at \(path)")
        }
        let digest = LibrarianSpreadsheet.extract(path: path, host: env.host, rows: request.topK ?? 20)
        switch digest {
        case .csv(let text):
            _ = store.put(text)
            return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: request.input)
        case .xlsx(let text):
            _ = store.put(text)
            return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: request.input)
        case .unsupported(let reason):
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "spreadsheet_extract unsupported: \(reason)",
                envelope: .unavailable(op: request.id, reason: reason, handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
    }
}

// MARK: - Vision OCR

public struct LibrarianOCRBox: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct LibrarianOCRLine: Sendable, Equatable {
    public let text: String
    public let confidence: Double
    public let box: LibrarianOCRBox
}

public enum LibrarianVisionOCR {
    #if canImport(Vision) && canImport(ImageIO)
    public static func recognize(path: String) -> [LibrarianOCRLine]? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return recognize(image: image)
    }

    public static func recognize(image: CGImage) -> [LibrarianOCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return LibrarianOCRLine(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                box: LibrarianOCRBox(
                    x: Double(box.origin.x),
                    y: Double(box.origin.y),
                    width: Double(box.width),
                    height: Double(box.height)
                )
            )
        }
    }
    #else
    public static func recognize(path: String) -> [LibrarianOCRLine]? { nil }
    public static func recognize(image: Any) -> [LibrarianOCRLine] { [] }
    #endif
}

// MARK: - Image diff

public enum LibrarianImageDiff {
    public struct Region: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        public let changedFraction: Double
    }

    public struct Result: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let changedPercent: Double
        public let regions: [Region]
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    public static func diff(before: String, after: String) -> Result? {
        guard let beforeImage = load(before), let afterImage = load(after) else { return nil }
        return diff(before: beforeImage, after: afterImage)
    }

    static func load(_ path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func diff(before: CGImage, after: CGImage) -> Result? {
        let width = min(before.width, after.width)
        let height = min(before.height, after.height)
        guard width > 0, height > 0 else { return nil }
        guard let beforeData = rgbaBytes(before, width: width, height: height),
              let afterData = rgbaBytes(after, width: width, height: height) else { return nil }
        let tile = 16
        var changedPixels = 0
        var regions: [Region] = []
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                var changed = 0
                var total = 0
                for row in y..<min(height, y + tile) {
                    for column in x..<min(width, x + tile) {
                        let offset = (row * width + column) * 4
                        total += 1
                        let delta = abs(Int(beforeData[offset]) - Int(afterData[offset]))
                            + abs(Int(beforeData[offset + 1]) - Int(afterData[offset + 1]))
                            + abs(Int(beforeData[offset + 2]) - Int(afterData[offset + 2]))
                        if delta > 30 { changed += 1 }
                    }
                }
                changedPixels += changed
                if total > 0, Double(changed) / Double(total) > 0.05 {
                    regions.append(Region(
                        x: x, y: y,
                        width: min(tile, width - x), height: min(tile, height - y),
                        changedFraction: Double(changed) / Double(total)
                    ))
                }
                x += tile
            }
            y += tile
        }
        let totalPixels = width * height
        return Result(
            width: width,
            height: height,
            changedPercent: totalPixels == 0 ? 0 : Double(changedPixels) / Double(totalPixels) * 100,
            regions: regions.sorted { $0.changedFraction > $1.changedFraction }
        )
    }

    private static func rgbaBytes(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
    #else
    public static func diff(before: String, after: String) -> Result? { nil }
    #endif
}

// MARK: - Video keyframes

public enum LibrarianVideoFrames {
    public struct Frame: Sendable {
        public let seconds: Double
        #if canImport(CoreGraphics)
        public let image: CGImage
        #endif
    }

    #if canImport(AVFoundation) && canImport(CoreGraphics)
    public static func keyframes(path: String, count: Int) -> [Frame]? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let samples = max(1, min(24, count))
        var frames: [Frame] = []
        for index in 0..<samples {
            let seconds = duration * Double(index) / Double(samples)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            frames.append(Frame(seconds: seconds, image: image))
        }
        return frames.isEmpty ? nil : frames
    }
    #else
    public static func keyframes(path: String, count: Int) -> [Frame]? { nil }
    #endif
}

// MARK: - Speech

public enum LibrarianSpeechRecognition {
    #if canImport(Speech)
    public static func transcribe(path: String, locale: String) async -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return nil }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            return nil
        }
        let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        return await withCheckedContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, _ in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
    #else
    public static func transcribe(path: String, locale: String) async -> String? { nil }
    #endif
}

// MARK: - Spreadsheets

public enum LibrarianSpreadsheet {
    public enum Digest {
        case csv(String)
        case xlsx(String)
        case unsupported(String)
    }

    public static func extract(path: String, host: LibrarianHostIO, rows: Int) -> Digest {
        switch (path as NSString).pathExtension.lowercased() {
        case "csv", "tsv", "txt":
            guard let text = host.readText(path, LibrarianWorkspaceFiles.maxFileBytes) else {
                return .unsupported("workbook_unreadable")
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let head = lines.prefix(max(1, rows)).joined(separator: "\n")
            return .csv("spreadsheet_extract format=\(path.split(separator: ".").last ?? "csv") rows=\(lines.count)\n\(head)")
        case "xlsx":
            guard let unzip = host.resolveTool("unzip") else {
                return .unsupported("unzip_unavailable")
            }
            let shared = host.runProcess(LibrarianProcessInvocation(
                executable: unzip, arguments: ["-p", path, "xl/sharedStrings.xml"], timeout: 20
            ))
            let sharedStrings = LibrarianXLSXParser.sharedStrings(xml: shared.stdout)
            let sheet = host.runProcess(LibrarianProcessInvocation(
                executable: unzip, arguments: ["-p", path, "xl/worksheets/sheet1.xml"], timeout: 20
            ))
            guard sheet.launched, sheet.exitCode == 0, !sheet.stdout.isEmpty else {
                return .unsupported("xlsx_sheet_unreadable")
            }
            let parsed = LibrarianXLSXParser.rows(xml: sheet.stdout, sharedStrings: sharedStrings, limit: rows)
            guard !parsed.isEmpty else { return .unsupported("xlsx_no_rows") }
            let body = parsed.enumerated().map { index, values in
                "r\(index + 1)\t" + values.joined(separator: "\t")
            }.joined(separator: "\n")
            return .xlsx("spreadsheet_extract format=xlsx sheets=1 rows=\(parsed.count) shared_strings=\(sharedStrings.count)\n\(body)")
        case "numbers":
            return .unsupported("numbers_format_not_supported")
        default:
            return .unsupported("unsupported_extension")
        }
    }
}

/// Minimal sheet1.xml reader: enough for a deterministic digest (cell refs +
/// shared/inline strings + numbers) without an XLSX dependency.
public enum LibrarianXLSXParser {
    public static func sharedStrings(xml: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inside = false
        var buffer = ""
        var index = xml.startIndex
        while let range = xml.range(of: "<si>", range: index..<xml.endIndex) {
            guard let end = xml.range(of: "</si>", range: range.upperBound..<xml.endIndex) else { break }
            let body = String(xml[range.upperBound..<end.lowerBound])
            values.append(stripTags(body))
            index = end.upperBound
            _ = (current, inside, buffer)
            current = ""
            inside = false
            buffer = ""
        }
        return values
    }

    public static func rows(xml: String, sharedStrings: [String], limit: Int) -> [[String]] {
        var rows: [[String]] = []
        var index = xml.startIndex
        while let rowRange = xml.range(of: "<row", range: index..<xml.endIndex) {
            guard let rowEnd = xml.range(of: "</row>", range: rowRange.upperBound..<xml.endIndex) else { break }
            let body = String(xml[rowRange.upperBound..<rowEnd.lowerBound])
            rows.append(cells(in: body, sharedStrings: sharedStrings))
            if rows.count >= limit { break }
            index = rowEnd.upperBound
        }
        return rows
    }

    private static func cells(in row: String, sharedStrings: [String]) -> [String] {
        var values: [String] = []
        var index = row.startIndex
        while let cellRange = row.range(of: "<c", range: index..<row.endIndex) {
            guard let cellEnd = row.range(of: "</c>", range: cellRange.upperBound..<row.endIndex) else { break }
            let open = String(row[cellRange.upperBound..<cellEnd.lowerBound])
            let type = attribute("t", in: String(row[cellRange.lowerBound..<cellEnd.lowerBound]))
            let value = valueTag(open)
            if type == "s", let raw = Int(value), raw >= 0, raw < sharedStrings.count {
                values.append(sharedStrings[raw])
            } else if type == "inlineStr" {
                values.append(stripTags(open))
            } else {
                values.append(value)
            }
            index = cellEnd.upperBound
        }
        return values
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name)=\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func valueTag(_ xml: String) -> String {
        guard let start = xml.range(of: "<v>"), let end = xml.range(of: "</v>", range: start.upperBound..<xml.endIndex) else {
            return ""
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    private static func stripTags(_ xml: String) -> String {
        var out = ""
        var inside = false
        for character in xml {
            if character == "<" { inside = true; continue }
            if character == ">" { inside = false; continue }
            if !inside { out.append(character) }
        }
        return out
    }
}
