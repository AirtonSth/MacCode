import CryptoKit
import Foundation

// Noise_IK_25519_ChaChaPoly_SHA256 (Noise Protocol Framework rev 34).
//   <- s
//   ...
//   -> e, es, s, ss
//   <- e, ee, se

public enum RelayNoise {
    public static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"
    public static let maxMessageLength = 65535
    public static let maxPlaintextChunk = 65519

    public static func prologue(serverId: String) -> Data {
        Data(("remotecode-relay/1\n" + serverId).utf8)
    }
}

public enum RelayNoiseError: Error, Equatable {
    case invalidKey, invalidMessage, decryptFailed, wrongState, messageTooLong, nonceExhausted
}

private let dhLength = 32
private let tagLength = 16

// MARK: - CipherState

private struct NoiseCipherState {
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0

    init(key: SymmetricKey? = nil) {
        self.key = key
    }

    var hasKey: Bool { key != nil }

    private func chaChaNonce() throws -> ChaChaPoly.Nonce {
        // 96-bit nonce: 4 zero bytes + 64-bit little-endian counter.
        var bytes = Data(count: 4)
        withUnsafeBytes(of: nonce.littleEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    mutating func encryptWithAD(_ ad: Data, _ plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        // 2^64-1 is reserved by the Noise spec.
        guard nonce != UInt64.max else { throw RelayNoiseError.nonceExhausted }
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: chaChaNonce(), authenticating: ad)
        nonce += 1
        return Data(sealed.ciphertext + sealed.tag) // zero-based indices
    }

    mutating func decryptWithAD(_ ad: Data, _ ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard nonce != UInt64.max else { throw RelayNoiseError.nonceExhausted }
        guard ciphertext.count >= tagLength else { throw RelayNoiseError.decryptFailed }
        do {
            let split = ciphertext.startIndex + (ciphertext.count - tagLength)
            let box = try ChaChaPoly.SealedBox(
                nonce: chaChaNonce(),
                ciphertext: ciphertext[ciphertext.startIndex..<split],
                tag: ciphertext[split...]
            )
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
            nonce += 1
            return plaintext
        } catch let error as RelayNoiseError {
            throw error
        } catch {
            throw RelayNoiseError.decryptFailed
        }
    }
}

// MARK: - SymmetricState

private struct NoiseSymmetricState {
    private(set) var h: Data
    private var ck: Data
    private var cipher = NoiseCipherState()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        // Name is longer than 32 bytes, so h = HASH(name).
        h = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        ck = h
    }

    private static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    // Noise HKDF(chaining_key, input_key_material, 2).
    private static func hkdf2(_ ck: Data, _ ikm: Data) -> (Data, Data) {
        let temp = hmac(ck, ikm)
        let out1 = hmac(temp, Data([0x01]))
        let out2 = hmac(temp, out1 + Data([0x02]))
        return (out1, out2)
    }

    mutating func mixHash(_ data: Data) {
        h = Data(SHA256.hash(data: h + data))
    }

    mutating func mixKey(_ ikm: Data) {
        let (newCK, tempK) = Self.hkdf2(ck, ikm)
        ck = newCK
        cipher = NoiseCipherState(key: SymmetricKey(data: tempK))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encryptWithAD(h, plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decryptWithAD(h, ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (NoiseCipherState, NoiseCipherState) {
        let (k1, k2) = Self.hkdf2(ck, Data())
        return (
            NoiseCipherState(key: SymmetricKey(data: k1)),
            NoiseCipherState(key: SymmetricKey(data: k2))
        )
    }
}

// MARK: - Handshake

public final class RelayNoiseHandshake {
    private enum Role { case initiator, responder }
    private enum Step { case writeFirst, readFirst, writeSecond, readSecond, complete, failed }

    private let role: Role
    private var symmetric = NoiseSymmetricState(protocolName: RelayNoise.protocolName)
    private let s: Curve25519.KeyAgreement.PrivateKey
    private let e: Curve25519.KeyAgreement.PrivateKey
    private var rs: Curve25519.KeyAgreement.PublicKey?
    private var re: Curve25519.KeyAgreement.PublicKey?
    private var step: Step

    /// Initiator (iPhone).
    public init(
        initiatorStatic: Curve25519.KeyAgreement.PrivateKey,
        responderStaticPublicKey: Data,
        prologue: Data,
        ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil
    ) throws {
        guard responderStaticPublicKey.count == dhLength,
              let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: responderStaticPublicKey)
        else { throw RelayNoiseError.invalidKey }
        role = .initiator
        s = initiatorStatic
        e = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
        rs = remote
        step = .writeFirst
        symmetric.mixHash(prologue)
        symmetric.mixHash(responderStaticPublicKey) // pre-message: <- s
    }

    /// Responder (Mac).
    public init(
        responderStatic: Curve25519.KeyAgreement.PrivateKey,
        prologue: Data,
        ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil
    ) {
        role = .responder
        s = responderStatic
        e = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
        step = .readFirst
        symmetric.mixHash(prologue)
        symmetric.mixHash(responderStatic.publicKey.rawRepresentation) // pre-message: <- s
    }

    public var remoteStaticPublicKey: Data? {
        guard role == .responder, let rs else { return nil }
        return rs.rawRepresentation
    }

    public var isComplete: Bool { step == .complete }

    public var handshakeHash: Data { symmetric.h }

    private func dh(
        _ priv: Curve25519.KeyAgreement.PrivateKey,
        _ pub: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        do {
            let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
            return secret.withUnsafeBytes { Data($0) }
        } catch {
            throw RelayNoiseError.invalidKey
        }
    }

    public func writeMessage(payload: Data = Data()) throws -> Data {
        switch (role, step) {
        case (.initiator, .writeFirst), (.responder, .writeSecond): break
        default: throw RelayNoiseError.wrongState
        }
        do {
            var out = Data()
            let ePub = e.publicKey.rawRepresentation
            out.append(ePub)
            symmetric.mixHash(ePub)
            if role == .initiator {
                guard let rs else { throw RelayNoiseError.wrongState }
                symmetric.mixKey(try dh(e, rs)) // es
                out.append(try symmetric.encryptAndHash(s.publicKey.rawRepresentation))
                symmetric.mixKey(try dh(s, rs)) // ss
                out.append(try symmetric.encryptAndHash(payload))
                step = .readSecond
            } else {
                guard let re, let rs else { throw RelayNoiseError.wrongState }
                symmetric.mixKey(try dh(e, re)) // ee
                symmetric.mixKey(try dh(e, rs)) // se
                out.append(try symmetric.encryptAndHash(payload))
                step = .complete
            }
            guard out.count <= RelayNoise.maxMessageLength else { throw RelayNoiseError.messageTooLong }
            return out
        } catch {
            step = .failed
            throw error
        }
    }

    public func readMessage(_ message: Data) throws -> Data {
        switch (role, step) {
        case (.initiator, .readSecond), (.responder, .readFirst): break
        default: throw RelayNoiseError.wrongState
        }
        do {
            guard message.count <= RelayNoise.maxMessageLength else { throw RelayNoiseError.messageTooLong }
            let m = Data(message) // zero-based indices
            let minimum = role == .responder ? dhLength + dhLength + tagLength + tagLength : dhLength + tagLength
            guard m.count >= minimum else { throw RelayNoiseError.invalidMessage }

            let reBytes = m.prefix(dhLength)
            guard let remoteEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: reBytes)
            else { throw RelayNoiseError.invalidKey }
            re = remoteEphemeral
            symmetric.mixHash(Data(reBytes))

            let payload: Data
            if role == .responder {
                symmetric.mixKey(try dh(s, remoteEphemeral)) // es
                let encryptedS = m.subdata(in: dhLength..<(dhLength + dhLength + tagLength))
                let sBytes = try symmetric.decryptAndHash(encryptedS)
                guard let remoteStatic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: sBytes)
                else { throw RelayNoiseError.invalidKey }
                rs = remoteStatic
                symmetric.mixKey(try dh(s, remoteStatic)) // ss
                payload = try symmetric.decryptAndHash(m.subdata(in: (dhLength + dhLength + tagLength)..<m.count))
                step = .writeSecond
            } else {
                symmetric.mixKey(try dh(e, remoteEphemeral)) // ee
                symmetric.mixKey(try dh(s, remoteEphemeral)) // se
                payload = try symmetric.decryptAndHash(m.subdata(in: dhLength..<m.count))
                step = .complete
            }
            return payload
        } catch {
            step = .failed
            throw error
        }
    }

    public func split() throws -> RelayNoiseTransport {
        guard step == .complete else { throw RelayNoiseError.wrongState }
        let (c1, c2) = symmetric.split()
        // c1 = initiator -> responder, c2 = responder -> initiator.
        return role == .initiator
            ? RelayNoiseTransport(send: c1, receive: c2)
            : RelayNoiseTransport(send: c2, receive: c1)
    }
}

// MARK: - Transport

public final class RelayNoiseTransport {
    private var sendCipher: NoiseCipherState
    private var receiveCipher: NoiseCipherState

    fileprivate init(send: NoiseCipherState, receive: NoiseCipherState) {
        sendCipher = send
        receiveCipher = receive
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= RelayNoise.maxPlaintextChunk else { throw RelayNoiseError.messageTooLong }
        return try sendCipher.encryptWithAD(Data(), plaintext)
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        guard ciphertext.count <= RelayNoise.maxMessageLength else { throw RelayNoiseError.messageTooLong }
        return try receiveCipher.decryptWithAD(Data(), ciphertext)
    }
}
