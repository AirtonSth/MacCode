import CryptoKit
import Foundation

public enum DeferredDeliveryIdempotency {
    public static func requestID(
        for identity: DistillDeferredDeliveryAuthority.Identity
    ) -> UUID {
        var material = Data("io.remotecode.deferred-delivery.idempotency".utf8)
        for field in [
            identity.provider,
            identity.threadID,
            identity.rootRunID,
            identity.attemptID,
            identity.invocationID,
            identity.operationID,
            identity.producerFamily,
        ] {
            append(field, to: &material)
        }
        let digest = Data(SHA256.hash(data: material))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    private static func append(_ value: String?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}
