import CryptoKit
import CoreModel
import Darwin
import Foundation

public enum DistillDeliveryReceiptKeyFileProvider {
    public static func load(appSupportDirectory: String) -> Data? {
        let path = URL(fileURLWithPath: appSupportDirectory, isDirectory: true)
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
            .path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o077 == 0,
              let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return DistillAppliedReceipt.decodeReceiptKey(object["receipt_key"] as? String)
    }
}

public struct DistillDeferredChunkDescriptor: Codable, Sendable, Equatable {
    public let index: Int
    public let count: Int
    public let originalUTF8ByteOffset: Int
    public let originalUTF8ByteLength: Int
    public let aggregateOperationID: String

    public init(
        index: Int,
        count: Int,
        originalUTF8ByteOffset: Int,
        originalUTF8ByteLength: Int,
        aggregateOperationID: String
    ) {
        self.index = index
        self.count = count
        self.originalUTF8ByteOffset = originalUTF8ByteOffset
        self.originalUTF8ByteLength = originalUTF8ByteLength
        self.aggregateOperationID = aggregateOperationID
    }
}

public struct DistillDeferredMemberManifest: Codable, Sendable, Equatable {
    public let descriptor: DistillDeferredChunkDescriptor
    public let question: String?
    public let routeStage: TokenSaverRouteStage?
    public let recoveryConfirmations: [DistillRecoveryDeliveryConfirmation]
    public let accountingOutput: String
    public let memberToken: String

    public init(
        descriptor: DistillDeferredChunkDescriptor,
        question: String?,
        routeStage: TokenSaverRouteStage?,
        recoveryConfirmations: [DistillRecoveryDeliveryConfirmation],
        accountingOutput: String,
        memberToken: String
    ) {
        self.descriptor = descriptor
        self.question = question
        self.routeStage = routeStage
        self.recoveryConfirmations = recoveryConfirmations
        self.accountingOutput = accountingOutput
        self.memberToken = memberToken
    }
}

public enum DistillDeferredDelivery {
    public static let handoffDeadlineHeader = "X-RemoteCode-Handoff-Deadline-Unix-Milliseconds"
    public static let ordinaryTTLMilliseconds: UInt64 = 30_000
    public static let chunkDeadlineMilliseconds: UInt64 = 20_000
    public static let finalHandoffDeadlineNanoseconds: UInt64 = 250_000_000
    public static let finalHandoffDeadlineMilliseconds: UInt64 = 250

    public static func handoffDeadlineUnixMilliseconds(
        now: Date = Date()
    ) -> UInt64? {
        let milliseconds = now.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds >= 0,
              milliseconds <= Double(UInt64.max) else { return nil }
        let current = UInt64(milliseconds.rounded(.down))
        let (deadline, overflow) = current.addingReportingOverflow(finalHandoffDeadlineMilliseconds)
        return overflow ? nil : deadline
    }

    public static func isHandoffDeadlineValid(
        _ deadline: UInt64?,
        now: Date = Date()
    ) -> Bool {
        guard let deadline else { return false }
        let milliseconds = now.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds >= 0,
              milliseconds <= Double(UInt64.max) else { return false }
        return UInt64(milliseconds.rounded(.down)) < deadline
    }

    public static func handoffDeadline(headers: [String: String]) -> UInt64? {
        guard let raw = headers[handoffDeadlineHeader.lowercased()] else { return nil }
        guard let value = UInt64(raw), String(value) == raw else { return nil }
        return value
    }

    public static func memberTTLMilliseconds(chunkCount: Int) -> UInt64? {
        guard chunkCount > 0, let count = UInt64(exactly: chunkCount) else { return nil }
        let (scaled, multiplyOverflow) = count.multipliedReportingOverflow(by: chunkDeadlineMilliseconds)
        guard !multiplyOverflow else { return nil }
        let (ttl, addOverflow) = ordinaryTTLMilliseconds.addingReportingOverflow(scaled)
        return addOverflow ? nil : ttl
    }

    public static func recoveryConfirmations(_ response: DistillResponse) -> [DistillRecoveryDeliveryConfirmation] {
        guard let capability = response.originalHandle, !capability.isEmpty,
              let idempotencyKey = response.recoveryIdempotencyKey, !idempotencyKey.isEmpty else {
            return []
        }
        return [.init(capability: capability, idempotencyKey: idempotencyKey)]
    }

    /// Marker-free accounting bytes and the exact prefix handed to the provider.
    public static func providerVisiblePrefix(
        accountingOutput: String,
        recoveryConfirmations: [DistillRecoveryDeliveryConfirmation]
    ) -> String? {
        guard !accountingOutput.contains("[[rcd:"), !accountingOutput.contains("[[rc:") else { return nil }
        var result = accountingOutput
        if !result.hasSuffix("\n") { result.append("\n") }
        for confirmation in recoveryConfirmations {
            guard !confirmation.capability.isEmpty, !confirmation.idempotencyKey.isEmpty,
                  !confirmation.capability.contains("\n"), !confirmation.capability.contains("\r"),
                  !confirmation.capability.contains("[["), !confirmation.capability.contains("]]"),
                  !confirmation.idempotencyKey.contains("\n"), !confirmation.idempotencyKey.contains("\r") else { return nil }
            result.append("[[rc:\(confirmation.capability)]]\n")
        }
        return result
    }

    /// The provider already received the replacement before this work begins.
    /// A slow or unavailable ledger endpoint therefore must never hold the pipe,
    /// wrapper, or MCP response open beyond the delivery contract's small tail.
    static func awaitBestEffortHandoff(
        timeoutNanoseconds: UInt64 = finalHandoffDeadlineNanoseconds,
        operation: @escaping @Sendable () async -> Void
    ) async {
        await withCheckedContinuation { continuation in
            let gate = DistillDeferredContinuationGate()
            let operationTask = Task {
                await operation()
                gate.finish(.operation, continuation: continuation)
            }
            gate.installOperation(operationTask)
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                gate.finish(.timeout, continuation: continuation)
            }
            gate.installTimeout(timeoutTask)
        }
    }
}

private final class DistillDeferredContinuationGate: @unchecked Sendable {
    enum Winner { case operation, timeout }

    private let lock = NSLock()
    private var completed = false
    private var winner: Winner?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func installOperation(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = completed && winner == .timeout
        operationTask = task
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func installTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = completed && winner == .operation
        timeoutTask = task
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func finish(_ winner: Winner, continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        self.winner = winner
        let taskToCancel = winner == .timeout ? operationTask : timeoutTask
        lock.unlock()
        taskToCancel?.cancel()
        continuation.resume()
    }
}

/// Process-local HMAC authority. Its key is generated once per server instance and
/// is never exposed; tokens carry only content-free metadata/digests plus a MAC.
public final class DistillDeferredDeliveryAuthority: @unchecked Sendable {
    public struct Identity: Sendable, Equatable {
        public let provider: String
        public let threadID: String
        public let rootRunID: String?
        public let attemptID: String?
        public let invocationID: String
        public let operationID: String
        public let producerFamily: String

        public init(
            provider: String,
            threadID: String,
            rootRunID: String?,
            attemptID: String?,
            invocationID: String,
            operationID: String,
            producerFamily: String
        ) {
            self.provider = provider
            self.threadID = threadID.isEmpty ? "unscoped" : threadID
            self.rootRunID = rootRunID
            self.attemptID = attemptID
            self.invocationID = invocationID
            self.operationID = operationID
            self.producerFamily = producerFamily
        }

        var isComplete: Bool {
            !provider.isEmpty && !threadID.isEmpty && !invocationID.isEmpty
                && !operationID.isEmpty && !producerFamily.isEmpty
        }
    }

    private struct Payload {
        let version: String
        let identity: WireIdentity
        let routeStage: String?
        let originalSHA256: String
        let accountingOutputSHA256: String
        let recoveryConfirmationsSHA256: String
        let providerVisiblePrefixSHA256: String
        let issuedAtUnixMS: UInt64
        let expiresAtUnixMS: UInt64
        let chunk: DistillDeferredChunkDescriptor?
        let questionSHA256: String?
        let accountingOutputUTF8ByteCount: Int?
    }

    private struct WireIdentity: Equatable {
        let provider: String
        let threadID: String
        let rootRunID: String?
        let attemptID: String?
        let invocationID: String
        let operationID: String
        let producerFamily: String
    }

    public struct Verified: Sendable {
        public let identity: Identity
        public let routeStage: TokenSaverRouteStage?
        public let issuedAtUnixMS: UInt64
        public let expiresAtUnixMS: UInt64
        public let chunk: DistillDeferredChunkDescriptor?
    }

    private static let canonicalDomain = Data("io.remotecode.deferred-delivery".utf8)
    private let key: SymmetricKey?
    private let nowMilliseconds: @Sendable () -> UInt64

    public init(
        keyGenerator: @escaping @Sendable () -> Data = {
            Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        },
        nowMilliseconds: @escaping @Sendable () -> UInt64 = {
            UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        }
    ) {
        let bytes = keyGenerator()
        self.key = bytes.count == 32 ? SymmetricKey(data: bytes) : nil
        self.nowMilliseconds = nowMilliseconds
    }

    public func issue(
        identity: Identity,
        original: String,
        accountingOutput: String,
        recoveryConfirmations: [DistillRecoveryDeliveryConfirmation],
        providerVisiblePrefix: String,
        routeStage: TokenSaverRouteStage?,
        chunk: DistillDeferredChunkDescriptor? = nil,
        question: String? = nil
    ) -> String? {
        guard identity.isComplete, let key,
              !accountingOutput.contains("[[rcd:"),
              DistillDeferredDelivery.providerVisiblePrefix(
                accountingOutput: accountingOutput,
                recoveryConfirmations: recoveryConfirmations
              ).map({ Data($0.utf8) }) == Data(providerVisiblePrefix.utf8) else { return nil }
        let issued = nowMilliseconds()
        let ttl: UInt64
        if let chunk {
            guard chunk.index >= 0, chunk.index < chunk.count,
                  chunk.originalUTF8ByteOffset >= 0,
                  chunk.originalUTF8ByteLength >= 0,
                  !chunk.aggregateOperationID.isEmpty,
                  let memberTTL = DistillDeferredDelivery.memberTTLMilliseconds(chunkCount: chunk.count) else {
                return nil
            }
            ttl = memberTTL
        } else {
            ttl = DistillDeferredDelivery.ordinaryTTLMilliseconds
        }
        let (expires, overflow) = issued.addingReportingOverflow(ttl)
        guard !overflow else { return nil }
        let payload = Payload(
            version: chunk == nil ? "v1" : "member-v1",
            identity: wire(identity),
            routeStage: routeStage?.rawValue,
            originalSHA256: DistillSHA256.hex(Data(original.utf8)),
            accountingOutputSHA256: DistillSHA256.hex(Data(accountingOutput.utf8)),
            recoveryConfirmationsSHA256: confirmationsDigest(recoveryConfirmations, identity: identity),
            providerVisiblePrefixSHA256: DistillSHA256.hex(Data(providerVisiblePrefix.utf8)),
            issuedAtUnixMS: issued,
            expiresAtUnixMS: expires,
            chunk: chunk,
            questionSHA256: question.map { DistillSHA256.hex(Data($0.utf8)) },
            accountingOutputUTF8ByteCount: chunk == nil ? nil : accountingOutput.utf8.count
        )
        let data = encode(payload)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        return "\(payload.version).\(base64URL(data)).\(base64URL(mac))"
    }

    public func verify(
        token: String,
        identity: Identity,
        original: String,
        accountingOutput: String,
        recoveryConfirmations: [DistillRecoveryDeliveryConfirmation],
        providerVisiblePrefix: String,
        routeStage: TokenSaverRouteStage?,
        expectedChunk: DistillDeferredChunkDescriptor? = nil,
        question: String? = nil
    ) -> Verified? {
        guard let key else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let data = decodeBase64URL(parts[1]),
              let suppliedMAC = decodeBase64URL(parts[2]), suppliedMAC.count == 32 else { return nil }
        let expectedMAC = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        guard constantTimeEqual(suppliedMAC, expectedMAC),
              let payload = decode(data),
              payload.version == String(parts[0]),
              wireIdentityEqual(payload.identity, wire(identity)),
              payload.routeStage == routeStage?.rawValue,
              payload.originalSHA256 == DistillSHA256.hex(Data(original.utf8)),
              payload.accountingOutputSHA256 == DistillSHA256.hex(Data(accountingOutput.utf8)),
              payload.recoveryConfirmationsSHA256 == confirmationsDigest(recoveryConfirmations, identity: identity),
              payload.providerVisiblePrefixSHA256 == DistillSHA256.hex(Data(providerVisiblePrefix.utf8)),
              chunkEqual(payload.chunk, expectedChunk),
              payload.questionSHA256 == question.map({ DistillSHA256.hex(Data($0.utf8)) }),
              payload.accountingOutputUTF8ByteCount == (expectedChunk == nil ? nil : accountingOutput.utf8.count) else {
            return nil
        }
        let now = nowMilliseconds()
        guard payload.issuedAtUnixMS <= now, now < payload.expiresAtUnixMS else { return nil }
        return Verified(
            identity: identity,
            routeStage: routeStage,
            issuedAtUnixMS: payload.issuedAtUnixMS,
            expiresAtUnixMS: payload.expiresAtUnixMS,
            chunk: payload.chunk
        )
    }

    private func wire(_ identity: Identity) -> WireIdentity {
        WireIdentity(
            provider: identity.provider,
            threadID: identity.threadID,
            rootRunID: identity.rootRunID,
            attemptID: identity.attemptID,
            invocationID: identity.invocationID,
            operationID: identity.operationID,
            producerFamily: identity.producerFamily
        )
    }

    private func wireIdentityEqual(_ lhs: WireIdentity, _ rhs: WireIdentity) -> Bool {
        utf8Equal(lhs.provider, rhs.provider)
            && utf8Equal(lhs.threadID, rhs.threadID)
            && optionalUTF8Equal(lhs.rootRunID, rhs.rootRunID)
            && optionalUTF8Equal(lhs.attemptID, rhs.attemptID)
            && utf8Equal(lhs.invocationID, rhs.invocationID)
            && utf8Equal(lhs.operationID, rhs.operationID)
            && utf8Equal(lhs.producerFamily, rhs.producerFamily)
    }

    private func chunkEqual(
        _ lhs: DistillDeferredChunkDescriptor?,
        _ rhs: DistillDeferredChunkDescriptor?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.index == rhs.index
                && lhs.count == rhs.count
                && lhs.originalUTF8ByteOffset == rhs.originalUTF8ByteOffset
                && lhs.originalUTF8ByteLength == rhs.originalUTF8ByteLength
                && utf8Equal(lhs.aggregateOperationID, rhs.aggregateOperationID)
        default: return false
        }
    }

    private func utf8Equal(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8) == Data(rhs.utf8)
    }

    private func optionalUTF8Equal(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return utf8Equal(lhs, rhs)
        default: return false
        }
    }

    private func confirmationsDigest(
        _ values: [DistillRecoveryDeliveryConfirmation],
        identity: Identity
    ) -> String {
        var material = Data("io.remotecode.deferred-delivery.confirmations".utf8)
        appendUInt64(UInt64(values.count), to: &material)
        for value in values {
            appendOptionalField(value.capability, to: &material)
            appendOptionalField(value.idempotencyKey, to: &material)
            appendOptionalField(identity.rootRunID, to: &material)
            appendOptionalField(identity.invocationID, to: &material)
        }
        return DistillSHA256.hex(material)
    }

    private func encode(_ payload: Payload) -> Data {
        var data = Self.canonicalDomain
        appendOptionalField(payload.version, to: &data)
        appendOptionalField(payload.identity.provider, to: &data)
        appendOptionalField(payload.identity.threadID, to: &data)
        appendOptionalField(payload.identity.rootRunID, to: &data)
        appendOptionalField(payload.identity.attemptID, to: &data)
        appendOptionalField(payload.identity.invocationID, to: &data)
        if let chunk = payload.chunk {
            // member-v1 is a frozen wire contract. Aggregate identity precedes
            // the exact ordered member manifest; timestamps remain terminal.
            appendOptionalField(chunk.aggregateOperationID, to: &data)
            appendOptionalField(payload.identity.producerFamily, to: &data)
            appendOptionalField(payload.routeStage, to: &data)
            appendOptionalField(String(chunk.index), to: &data)
            appendOptionalField(String(chunk.count), to: &data)
            appendOptionalField(String(chunk.originalUTF8ByteOffset), to: &data)
            appendOptionalField(String(chunk.originalUTF8ByteLength), to: &data)
            appendOptionalField(payload.originalSHA256, to: &data)
            appendOptionalField(payload.questionSHA256, to: &data)
            appendOptionalField(payload.accountingOutputSHA256, to: &data)
            appendOptionalField(payload.accountingOutputUTF8ByteCount.map(String.init), to: &data)
            appendOptionalField(payload.recoveryConfirmationsSHA256, to: &data)
            appendOptionalField(payload.providerVisiblePrefixSHA256, to: &data)
        } else {
            appendOptionalField(payload.identity.operationID, to: &data)
            appendOptionalField(payload.identity.producerFamily, to: &data)
            appendOptionalField(payload.routeStage, to: &data)
            appendOptionalField(payload.originalSHA256, to: &data)
            appendOptionalField(payload.accountingOutputSHA256, to: &data)
            appendOptionalField(payload.recoveryConfirmationsSHA256, to: &data)
            appendOptionalField(payload.providerVisiblePrefixSHA256, to: &data)
        }
        appendUInt64(payload.issuedAtUnixMS, to: &data)
        appendUInt64(payload.expiresAtUnixMS, to: &data)
        return data
    }

    private func decode(_ data: Data) -> Payload? {
        guard data.starts(with: Self.canonicalDomain) else { return nil }
        var cursor = Self.canonicalDomain.count
        func field() -> String? { readOptionalField(data, cursor: &cursor) }
        guard let version = field(),
              let provider = field(), let threadID = field() else { return nil }
        let rootRunID = field()
        let attemptID = field()
        guard let invocationID = field() else { return nil }
        if version == "v1" {
            guard let operationID = field(), let producerFamily = field() else { return nil }
            let routeStage = field()
            guard let originalSHA256 = field(), let accountingOutputSHA256 = field(),
                  let confirmationsSHA256 = field(), let prefixSHA256 = field(),
                  let issued = readUInt64(data, cursor: &cursor),
                  let expires = readUInt64(data, cursor: &cursor), cursor == data.count else { return nil }
            return Payload(
                version: version,
                identity: WireIdentity(
                    provider: provider, threadID: threadID, rootRunID: rootRunID,
                    attemptID: attemptID, invocationID: invocationID,
                    operationID: operationID, producerFamily: producerFamily
                ),
                routeStage: routeStage,
                originalSHA256: originalSHA256,
                accountingOutputSHA256: accountingOutputSHA256,
                recoveryConfirmationsSHA256: confirmationsSHA256,
                providerVisiblePrefixSHA256: prefixSHA256,
                issuedAtUnixMS: issued,
                expiresAtUnixMS: expires,
                chunk: nil,
                questionSHA256: nil,
                accountingOutputUTF8ByteCount: nil
            )
        }
        guard version == "member-v1",
              let aggregateOperationID = field(), let producerFamily = field() else { return nil }
        let routeStage = field()
        guard let index = field().flatMap(Int.init),
              let count = field().flatMap(Int.init),
              let offset = field().flatMap(Int.init),
              let length = field().flatMap(Int.init),
              let originalSHA256 = field() else { return nil }
        let questionSHA256 = field()
        guard let accountingOutputSHA256 = field(),
              let byteCount = field().flatMap(Int.init),
              let confirmationsSHA256 = field(), let prefixSHA256 = field(),
              let issued = readUInt64(data, cursor: &cursor),
              let expires = readUInt64(data, cursor: &cursor), cursor == data.count else { return nil }
        return Payload(
            version: version,
            identity: WireIdentity(
                provider: provider, threadID: threadID, rootRunID: rootRunID,
                attemptID: attemptID, invocationID: invocationID,
                operationID: "\(aggregateOperationID).member.\(index)",
                producerFamily: producerFamily
            ),
            routeStage: routeStage,
            originalSHA256: originalSHA256,
            accountingOutputSHA256: accountingOutputSHA256,
            recoveryConfirmationsSHA256: confirmationsSHA256,
            providerVisiblePrefixSHA256: prefixSHA256,
            issuedAtUnixMS: issued,
            expiresAtUnixMS: expires,
            chunk: .init(
                index: index,
                count: count,
                originalUTF8ByteOffset: offset,
                originalUTF8ByteLength: length,
                aggregateOperationID: aggregateOperationID
            ),
            questionSHA256: questionSHA256,
            accountingOutputUTF8ByteCount: byteCount
        )
    }

    private func appendOptionalField(_ value: String?, to data: inout Data) {
        guard let value else { data.append(0); return }
        data.append(1)
        let bytes = Data(value.utf8)
        appendUInt64(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private func readOptionalField(_ data: Data, cursor: inout Int) -> String? {
        guard cursor < data.count else { return nil }
        let tag = data[cursor]
        cursor += 1
        if tag == 0 { return nil }
        guard tag == 1, let length = readUInt64(data, cursor: &cursor),
              length <= UInt64(data.count - cursor), let intLength = Int(exactly: length) else { return nil }
        let end = cursor + intLength
        defer { cursor = end }
        return String(data: data.subdata(in: cursor..<end), encoding: .utf8)
    }

    private func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func readUInt64(_ data: Data, cursor: inout Int) -> UInt64? {
        guard cursor <= data.count - 8 else { return nil }
        var value: UInt64 = 0
        for byte in data[cursor..<(cursor + 8)] { value = (value << 8) | UInt64(byte) }
        cursor += 8
        return value
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeBase64URL<S: StringProtocol>(_ text: S) -> Data? {
        var value = String(text).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
}
