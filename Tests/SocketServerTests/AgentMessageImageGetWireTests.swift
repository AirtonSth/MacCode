import CoreModel
import CryptoKit
import ImageIO
import RemoteCodeTreaty
import UniformTypeIdentifiers
import XCTest
@testable import SocketServer

/// WHY: `agent.message.image.get` lets a read-only phone pull bytes off the
/// Mac. It must hand out only image files that an assistant message on that
/// thread literally names, downsampled under the reply cap — never an
/// arbitrary host file, a file the message does not mention, or a non-image.
final class AgentMessageImageGetWireTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("msg-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeImage(_ name: String, width: Int, height: Int, alpha: Bool = false, noise: Bool = false) throws -> String {
        let url = directory.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
        ))
        if noise {
            let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt64.self, capacity: width * height / 2)
            var generator = SystemRandomNumberGenerator()
            for index in 0..<(width * height / 2) { pixels[index] = generator.next() }
        } else {
            context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url.path
    }

    private func message(_ content: String, thread: AgentThreadID = AgentThreadID(), role: AgentMessageRole = .assistant) -> AgentMessage {
        AgentMessage(threadId: thread, role: role, content: content)
    }

    private func request(_ message: AgentMessage, ref: String, maxPixel: Int? = nil) throws -> AgentMessageImageGetWire.Request {
        var params: [String: JSONValue] = [
            "thread_id": .string(message.threadId.value.uuidString),
            "message_id": .string(message.id.value.uuidString),
            "ref": .string(ref),
        ]
        if let maxPixel { params["max_pixel"] = .number(Double(maxPixel)) }
        return try AgentMessageImageGetWire.request(from: params)
    }

    private func code(_ block: () throws -> Any) -> (code: Int, detail: String?)? {
        do {
            _ = try block()
            return nil
        } catch let error as JSONRPCError {
            let data = error.data?.objectValue
            return (error.code, data?["missing"]?.stringValue ?? data?["reason"]?.stringValue)
        } catch {
            return (0, "\(error)")
        }
    }

    // MARK: Success

    /// The phone gets a downsampled image under the cap whose digest matches.
    func test_returnsDownsampledImageUnderTheCapWithDigest() throws {
        let path = try writeImage("big.png", width: 3_000, height: 1_500, noise: true)
        let msg = message("Saved the chart to \(path).")
        let result = try AgentMessageImageGetWire.load(try request(msg, ref: path, maxPixel: 1_024), message: msg)
        let decoded = try JSONDecoder().decode(AgentMessageImageGet.Result.self, from: JSONEncoder().encode(result))
        let data = try XCTUnwrap(Data(base64Encoded: decoded.dataBase64))
        XCTAssertLessThanOrEqual(data.count, AgentMessageImageGetWire.maxBytes, "same 256 KiB ceiling as agent.attachment.get")
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 1_024)
        XCTAssertEqual(decoded.mime, "image/jpeg")
        XCTAssertEqual(decoded.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "the bytes decode as an image")
    }

    func test_transparentImageIsPNGAndFileURLAndTildeRefsResolve() throws {
        let path = try writeImage("alpha.png", width: 300, height: 200, alpha: true)
        let fileRef = URL(fileURLWithPath: path).absoluteString
        let msg = message("Overlay: \(fileRef)")
        let result = try AgentMessageImageGetWire.load(try request(msg, ref: fileRef), message: msg)
        XCTAssertEqual(result.objectValue?["mime"]?.stringValue, "image/png", "transparency survives")
        XCTAssertEqual(result.objectValue?["width"]?.intValue, 300)

        let tildeMsg = message("See ~/alpha.png")
        let viaTilde = try AgentMessageImageGetWire.load(
            try request(tildeMsg, ref: "~/alpha.png"), message: tildeMsg, homeDirectory: directory.path
        )
        XCTAssertEqual(viaTilde.objectValue?["height"]?.intValue, 200)
    }

    // MARK: Refusals

    func test_refusesAMessageFromAnotherThreadOrAUserMessage() throws {
        let path = try writeImage("a.png", width: 10, height: 10)
        let msg = message("look \(path)")
        let wrongThread = AgentMessageImageGetWire.Request(threadID: AgentThreadID(), messageID: msg.id, ref: path, maxPixel: 512)
        XCTAssertEqual(code { try AgentMessageImageGetWire.load(wrongThread, message: msg) }?.detail, "message")
        XCTAssertEqual(code { try AgentMessageImageGetWire.load(try request(msg, ref: path), message: nil) }?.detail, "message")
        let user = message("look \(path)", role: .user)
        XCTAssertEqual(code { try AgentMessageImageGetWire.load(try request(user, ref: path), message: user) }?.code,
                       AgentMessageImageGetWire.notFoundCode, "only assistant messages are image sources")
    }

    /// WHY: the core containment rule — a read device must not be able to
    /// read an image the message never mentioned.
    func test_refusesAPathThatIsNotInTheMessage() throws {
        let shown = try writeImage("shown.png", width: 10, height: 10)
        let secret = try writeImage("secret.png", width: 10, height: 10)
        let msg = message("only \(shown)")
        let refused = code { try AgentMessageImageGetWire.load(try request(msg, ref: secret), message: msg) }
        XCTAssertEqual(refused?.code, AgentMessageImageGetWire.notFoundCode)
        XCTAssertEqual(refused?.detail, "ref")
    }

    func test_refusesMissingFilesNonImagesDirectoriesAndRemoteRefs() throws {
        let missing = directory.appendingPathComponent("gone.png").path
        let missingMsg = message("was at \(missing)")
        XCTAssertEqual(code { try AgentMessageImageGetWire.load(try request(missingMsg, ref: missing), message: missingMsg) }?.detail, "file")

        let text = directory.appendingPathComponent("notes.txt")
        try Data("secret".utf8).write(to: text)
        let textMsg = message("read \(text.path)")
        XCTAssertEqual(code { try AgentMessageImageGetWire.load(try request(textMsg, ref: text.path), message: textMsg) }?.code,
                       JSONRPCError.invalidParams.code, "a non-image extension is never served")

        let fake = directory.appendingPathComponent("fake.png")
        try Data("not really a png".utf8).write(to: fake)
        let fakeMsg = message("see \(fake.path)")
        XCTAssertEqual(code { try AgentMessageImageGetWire.load(try request(fakeMsg, ref: fake.path), message: fakeMsg) }?.detail, "not_image",
                       "bytes that do not decode as an image are refused, so a renamed file leaks nothing")

        let folder = directory.appendingPathComponent("dir.png", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderMsg = message("dir \(folder.path)")
        XCTAssertEqual(code { try AgentMessageImageGetWire.load(try request(folderMsg, ref: folder.path), message: folderMsg) }?.detail, "not_regular_file")

        let remoteMsg = message("web https://ex.com/a.png")
        XCTAssertEqual(code { try AgentMessageImageGetWire.load(try request(remoteMsg, ref: "https://ex.com/a.png"), message: remoteMsg) }?.code,
                       JSONRPCError.invalidParams.code, "the phone fetches web images itself")
    }

    func test_paramsAcceptOnlyContractPixelSizes() throws {
        let base: [String: JSONValue] = [
            "thread_id": .string(UUID().uuidString), "message_id": .string(UUID().uuidString), "ref": .string("/a.png"),
        ]
        XCTAssertEqual(try AgentMessageImageGetWire.request(from: base).maxPixel, AgentMessageImageGet.defaultMaxPixel)
        for allowed in AgentMessageImageGet.allowedMaxPixels {
            var params = base
            params["max_pixel"] = .number(Double(allowed))
            XCTAssertEqual(try AgentMessageImageGetWire.request(from: params).maxPixel, allowed)
        }
        var odd = base
        odd["max_pixel"] = .number(4_096)
        XCTAssertThrowsError(try AgentMessageImageGetWire.request(from: odd))
        var noRef = base
        noRef["ref"] = .string("  ")
        XCTAssertThrowsError(try AgentMessageImageGetWire.request(from: noRef))
    }

    // MARK: Admission and advertisement

    /// WHY: the phone calls this with a read-scoped device inside its
    /// read-only batch; it must never require write or count as a mutation.
    func test_isReadScopedBatchableAndNotAMutation() {
        XCTAssertEqual(AgentMessageImageGet.method, "agent.message.image.get")
        XCTAssertTrue(JSONRPCDispatcher.isReadOnlyBatchMethod("agent.message.image.get"))
        XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: "agent.message.image.get"), "read")
        XCTAssertTrue(JSONRPCDispatcher.isAuthorized(method: "agent.message.image.get", grantedCapabilities: "read"))
        XCTAssertFalse(JSONRPCDispatcher.hostMutationMethods.contains("agent.message.image.get"))
    }

    @MainActor
    func test_capabilityAdvertisedOnBothAuthoritiesNextToAttachmentGet() async throws {
        let payload = DirectHTTPServer.capabilitiesProjection(loopbackOnly: false)
            .authenticatedPayload(serverID: "host-1", bootEpoch: 42)
        let capabilities = try XCTUnwrap(payload["capabilities"] as? [String: Any])
        let agent = try XCTUnwrap(capabilities["agent"] as? [String: Any])
        XCTAssertEqual(agent["message_image_get_v1"] as? Bool, true)
        XCTAssertEqual(agent["attachment_get_v1"] as? Bool, true)
        let decoded = try JSONDecoder().decode(HostCapabilities.Agent.self, from: JSONSerialization.data(withJSONObject: agent))
        XCTAssertTrue(decoded.messageImageGetV1, "the treaty flag the iPhone gates on")

        let response = await JSONRPCDispatcher(router: FakeRouter()).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil
        ))
        XCTAssertEqual(response.result?.objectValue?["agent"]?.objectValue?["message_image_get_v1"], .bool(true))
    }

    func test_olderHostDecodesAsUnsupportedAndNotFoundMapsWithOrWithoutData() throws {
        let decoded = try JSONDecoder().decode(
            HostCapabilities.Agent.self,
            from: Data(#"{"providers":["codex"],"supports_stream_events":true,"supports_resume":true}"#.utf8)
        )
        XCTAssertFalse(decoded.messageImageGetV1)
        XCTAssertEqual(RemoteCodeError(code: AgentMessageImageGetWire.notFoundCode, message: "", data: nil).kind, .messageImageNotFound,
                       "rpc.batch error items carry no data; the code alone must say not found")
        XCTAssertEqual(RemoteCodeError(code: AgentMessageImageGetWire.notFoundCode, message: "", data: .object([
            "domain": .string("message_image"), "kind": .string("not_found"),
        ])).kind, .messageImageNotFound)
    }
}
