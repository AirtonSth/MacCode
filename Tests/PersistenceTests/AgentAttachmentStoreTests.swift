import CryptoKit
import XCTest
@testable import CoreModel
@testable import Persistence

final class AgentAttachmentStoreTests: XCTestCase {
    func test_stageAcceptsExact25MBAndRejectsNextByteForDataAndFiles() throws {
        // WHY: iOS and the host must enforce the same inclusive boundary. The
        // host is authoritative because paired clients are not trusted to cap it.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-attachment-size-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentAttachmentStore(root: root.appendingPathComponent("managed", isDirectory: true))
        let exact = Data(repeating: 0x41, count: AgentAttachmentStore.maximumSizeBytes)

        let accepted = try store.stage(
            data: exact,
            displayName: "exact.bin",
            kind: .file,
            mimeType: "application/octet-stream"
        )
        XCTAssertEqual(accepted.sizeBytes, AgentAttachmentStore.maximumSizeBytes)

        XCTAssertThrowsError(try store.stage(
            data: exact + Data([0x42]),
            displayName: "too-large.bin",
            kind: .file,
            mimeType: "application/octet-stream"
        )) { error in
            XCTAssertEqual(
                error as? AgentAttachmentResolverError,
                .exceedsMaximumSize("too-large.bin", AgentAttachmentStore.maximumSizeBytes)
            )
        }

        let oversizedFile = root.appendingPathComponent("oversized.dat")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: oversizedFile.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversizedFile)
        try handle.truncate(atOffset: UInt64(AgentAttachmentStore.maximumSizeBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try store.stage(path: oversizedFile.path)) { error in
            XCTAssertEqual(
                error as? AgentAttachmentResolverError,
                .exceedsMaximumSize("oversized.dat", AgentAttachmentStore.maximumSizeBytes)
            )
        }
    }

    func test_stageCopiesIntoContentAddressedPrivateStorage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-attachment-store-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("incoming/Quarterly Plan.png")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("private-image-payload".utf8)
        try bytes.write(to: source)
        let expectedHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let storeRoot = root.appendingPathComponent("managed", isDirectory: true)
        let store = AgentAttachmentStore(root: storeRoot)

        let first = try store.stage(path: source.path)
        let second = try store.stage(path: source.path)

        XCTAssertNotEqual(first.id, expectedHash,
                          "the client id must identify this attachment reference, not expose the shared blob digest")
        XCTAssertEqual(first.sha256, expectedHash)
        XCTAssertEqual(first.sizeBytes, bytes.count)
        XCTAssertEqual(first.displayName, "Quarterly Plan.png")
        XCTAssertEqual(first.kind, .image)
        XCTAssertTrue(first.path.hasPrefix(storeRoot.path + "/"),
                      "provider-visible paths must point at managed app storage, never the original private picker path")
        XCTAssertEqual(first.path, second.path,
                       "identical content must deduplicate to one durable provider reference")
        XCTAssertNotEqual(first.id, second.id,
                          "each staged attachment occurrence needs independent metadata identity")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.path)), bytes)

        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.path)), bytes,
                       "relaunch/retry must not depend on the user leaving the original picked file in place")
    }

    func test_stageDeduplicatesIdenticalBytesAcrossFilenameExtensions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-attachment-cross-extension-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let textSource = incoming.appendingPathComponent("payload.txt")
        let imageSource = incoming.appendingPathComponent("payload.png")
        let bytes = Data("same-content-addressed-payload".utf8)
        try bytes.write(to: textSource)
        try bytes.write(to: imageSource)
        let store = AgentAttachmentStore(root: root.appendingPathComponent("managed", isDirectory: true))

        let textAttachment = try store.stage(path: textSource.path)
        let imageAttachment = try store.stage(path: imageSource.path)
        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: store.root,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }

        XCTAssertNotEqual(textAttachment.id, imageAttachment.id,
                          "deduplicated bytes must not collapse independent attachment metadata")
        XCTAssertEqual(textAttachment.sha256, imageAttachment.sha256)
        XCTAssertEqual(textAttachment.path, imageAttachment.path,
                       "content identity must not be partitioned by source filename extension")
        XCTAssertEqual(textAttachment.displayName, "payload.txt")
        XCTAssertEqual(textAttachment.kind, .file)
        XCTAssertEqual(textAttachment.mimeType, "text/plain")
        XCTAssertEqual(imageAttachment.displayName, "payload.png")
        XCTAssertEqual(imageAttachment.kind, .image)
        XCTAssertEqual(imageAttachment.mimeType, "image/png")
        XCTAssertEqual(storedFiles.count, 1,
                       "identical bytes must occupy one managed blob regardless of extension")

        let relaunchedStore = AgentAttachmentStore(root: store.root)
        for expected in [textAttachment, imageAttachment] {
            let resolved = try relaunchedStore.resolveClientReference(AgentAttachment(
                id: expected.id,
                path: "",
                displayName: "client metadata must not override host state",
                kind: expected.kind == .image ? .file : .image,
                mimeType: "application/octet-stream",
                sha256: expected.sha256,
                sizeBytes: expected.sizeBytes
            ))
            XCTAssertEqual(resolved.displayName, expected.displayName)
            XCTAssertEqual(resolved.kind, expected.kind)
            XCTAssertEqual(resolved.mimeType, expected.mimeType)
        }
    }

    func test_stageRejectsDirectoryBeforeCreatingMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-attachment-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AgentAttachmentStore(root: root.appendingPathComponent("managed", isDirectory: true))

        XCTAssertThrowsError(try store.stage(path: root.path)) { error in
            XCTAssertEqual(error as? AgentAttachmentResolverError, .notReadableFile(root.path))
        }
    }

    func test_validatedForRetryAcceptsOnlyUnchangedManagedBlob() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-attachment-retry-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        let store = AgentAttachmentStore(root: root.appendingPathComponent("managed", isDirectory: true))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("durable retry bytes".utf8).write(to: source)
        let attachment = try store.stage(path: source.path)

        XCTAssertEqual(try store.validatedForRetry(attachment), attachment)

        try Data("tampered".utf8).write(to: URL(fileURLWithPath: attachment.path), options: .atomic)
        XCTAssertThrowsError(try store.validatedForRetry(attachment),
                             "a mutated managed blob must never be silently re-sent under stale metadata")
    }

    func test_validatedForRetryRejectsReadableFileOutsideManagedRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-attachment-retry-root-\(UUID().uuidString)", isDirectory: true)
        let outside = root.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside)
        let store = AgentAttachmentStore(root: root.appendingPathComponent("managed", isDirectory: true))
        let attachment = try XCTUnwrap(AgentAttachmentResolver.resolve(paths: [outside.path]).first)

        XCTAssertThrowsError(try store.validatedForRetry(attachment),
                             "retry must not trust an arbitrary persisted absolute path outside app-managed storage")
    }

    func test_stageUploadedBytesReturnsResolvableOpaqueReferenceAndExactBytesAfterRelaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-attachment-upload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0x00, 0x7f, 0xff, 0x10, 0x20])
        let firstStore = AgentAttachmentStore(root: root)
        let staged = try firstStore.stage(
            data: bytes,
            displayName: "exact.bin",
            kind: .file,
            mimeType: "application/octet-stream"
        )
        let reference = AgentAttachment(
            id: staged.id,
            path: "",
            displayName: staged.displayName,
            kind: staged.kind,
            mimeType: staged.mimeType,
            sha256: staged.sha256,
            sizeBytes: staged.sizeBytes
        )

        let relaunched = try AgentAttachmentStore(root: root).resolveClientReference(reference)

        XCTAssertEqual(relaunched.id, staged.id)
        XCTAssertEqual(relaunched.sha256, staged.sha256)
        XCTAssertEqual(relaunched.sizeBytes, bytes.count)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: relaunched.path)), bytes,
                       "upload/relaunch resolution must preserve exact bytes without a client path")
    }

    func test_resolveClientReferenceSupportsLegacyDigestIDAndSidecarAfterUpgrade() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-attachment-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("legacy durable bytes".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".metadata", isDirectory: true),
            withIntermediateDirectories: true
        )
        try bytes.write(to: root.appendingPathComponent(digest))
        try Data(#"{"displayName":"legacy.txt","kind":"file","mimeType":"text/plain"}"#.utf8)
            .write(to: root.appendingPathComponent(".metadata/\(digest).json"))

        let resolved = try AgentAttachmentStore(root: root).resolveClientReference(AgentAttachment(
            id: digest,
            path: "",
            displayName: "client-name-must-not-win.txt",
            kind: .image,
            mimeType: "image/png",
            sha256: digest,
            sizeBytes: bytes.count
        ))

        XCTAssertEqual(resolved.id, digest)
        XCTAssertEqual(resolved.sha256, digest)
        XCTAssertEqual(resolved.displayName, "legacy.txt")
        XCTAssertEqual(resolved.kind, .file)
        XCTAssertEqual(resolved.mimeType, "text/plain")
    }

    func test_stageRepairsCorruptExistingDigestBeforeReturningReference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-attachment-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expected = Data("authoritative exact bytes".utf8)
        try expected.write(to: source)
        let store = AgentAttachmentStore(root: root.appendingPathComponent("managed", isDirectory: true))
        let first = try store.stage(path: source.path)
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: first.path), options: .atomic)

        let repaired = try store.stage(path: source.path)

        XCTAssertEqual(repaired.sha256, first.sha256)
        XCTAssertEqual(repaired.sizeBytes, expected.count)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: repaired.path)), expected,
                       "a digest-named file is not trusted until its bytes hash correctly")
    }

    func test_resolveClientReferenceRejectsMalformedOrUnknownOpaqueID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-attachment-reference-\(UUID().uuidString)", isDirectory: true)
        let store = AgentAttachmentStore(root: root)
        let malformed = AgentAttachment(id: "../../secret", path: "", displayName: "secret", kind: .file, mimeType: "text/plain")
        let unknown = AgentAttachment(id: String(repeating: "a", count: 64), path: "", displayName: "unknown.txt", kind: .file, mimeType: "text/plain")

        XCTAssertThrowsError(try store.resolveClientReference(malformed))
        XCTAssertThrowsError(try store.resolveClientReference(unknown))
    }
}
