import CryptoKit
import Foundation
import XCTest
@testable import RemoteCodeTreaty

final class RelayNoiseTests: XCTestCase {
    private typealias Key = Curve25519.KeyAgreement.PrivateKey

    private func hex(_ s: String) -> Data {
        var data = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            data.append(UInt8(s[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private func key(_ h: String) throws -> Key { try Key(rawRepresentation: hex(h)) }

    private func pair(prologue: Data = Data("p".utf8)) throws -> (RelayNoiseHandshake, RelayNoiseHandshake, Key, Key) {
        let i = Key(), r = Key()
        let ini = try RelayNoiseHandshake(
            initiatorStatic: i, responderStaticPublicKey: r.publicKey.rawRepresentation, prologue: prologue)
        let resp = RelayNoiseHandshake(responderStatic: r, prologue: prologue)
        return (ini, resp, i, r)
    }

    private func complete() throws -> (RelayNoiseTransport, RelayNoiseTransport) {
        let (ini, resp, _, _) = try pair()
        _ = try resp.readMessage(ini.writeMessage())
        _ = try ini.readMessage(resp.writeMessage())
        return (try ini.split(), try resp.split())
    }

    // Vector: Noise_IK_25519_ChaChaPoly_SHA256 from cacophony.txt (mcginty/snow tests/vectors).
    func testCacophonyVector() throws {
        let prologue = hex("4a6f686e2047616c74")
        let initStatic = try key("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1")
        let initEph = try key("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a")
        let respStatic = try key("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893")
        let respEph = try key("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b")
        let remoteStatic = hex("31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62")
        XCTAssertEqual(respStatic.publicKey.rawRepresentation, remoteStatic)

        let msgs: [(String, String)] = [
            ("4c756477696720766f6e204d69736573",
             "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944718da798efbcd91528520204f904b9bd6c7413dccdc214d951e15253e39987f18146e8cd0873654207148333479d4d16c289f0294b29960a72f48e0b7bba2e89083169825e59642148d492020664ccf7"),
            ("4d757272617920526f746862617264",
             "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f1448088435361e70b2ed446e6c9ec387d1d6b3b840f194e373979d241b203c4acafccf5"),
            ("462e20412e20486179656b", "050e9f3c8fac16b68dbce8f8c4bfbf6617c897f9ada4aa29aa19c8"),
            ("4361726c204d656e676572", "344233a6cabb7141d80f3da2fedc311d9646bbb0f505afe403a667"),
            ("4a65616e2d426170746973746520536179",
             "62cdeeb172ad7ade7aa7d9e069da5790f12331bfa00177787a1d0810c67dc3b2b4"),
            ("457567656e2042f6686d20766f6e2042617765726b",
             "029bead1b40992327044d409d9a1f3ad8f36c3c452775d557e18bbeb2e8dfcead32d514024"),
        ]
        let ini = try RelayNoiseHandshake(
            initiatorStatic: initStatic, responderStaticPublicKey: remoteStatic,
            prologue: prologue, ephemeral: initEph)
        let resp = RelayNoiseHandshake(responderStatic: respStatic, prologue: prologue, ephemeral: respEph)

        let m0 = try ini.writeMessage(payload: hex(msgs[0].0))
        XCTAssertEqual(hexString(m0), msgs[0].1)
        XCTAssertEqual(try resp.readMessage(m0), hex(msgs[0].0))
        let m1 = try resp.writeMessage(payload: hex(msgs[1].0))
        XCTAssertEqual(hexString(m1), msgs[1].1)
        XCTAssertEqual(try ini.readMessage(m1), hex(msgs[1].0))

        let expectedHash = "0b0f68fb0c27e03ce9b97565995ed4838cc0581b762ef72b062f6a546419fad7"
        XCTAssertEqual(hexString(ini.handshakeHash), expectedHash)
        XCTAssertEqual(hexString(resp.handshakeHash), expectedHash)

        let ti = try ini.split(), tr = try resp.split()
        for (n, (payload, cipher)) in msgs.enumerated() where n >= 2 {
            let (sender, receiver) = n % 2 == 0 ? (ti, tr) : (tr, ti)
            let ct = try sender.encrypt(hex(payload))
            XCTAssertEqual(hexString(ct), cipher, "transport message \(n)")
            XCTAssertEqual(try receiver.decrypt(ct), hex(payload))
        }
    }

    func testRoundTripRandomKeys() throws {
        let (ini, resp, _, _) = try pair()
        XCTAssertEqual(try resp.readMessage(ini.writeMessage(payload: Data("hi".utf8))), Data("hi".utf8))
        XCTAssertEqual(try ini.readMessage(resp.writeMessage(payload: Data("yo".utf8))), Data("yo".utf8))
        XCTAssertTrue(ini.isComplete && resp.isComplete)
        XCTAssertEqual(ini.handshakeHash, resp.handshakeHash)
        let ti = try ini.split(), tr = try resp.split()
        let big = Data(repeating: 7, count: RelayNoise.maxPlaintextChunk)
        XCTAssertEqual(try tr.decrypt(ti.encrypt(big)), big)
        XCTAssertEqual(try ti.decrypt(tr.encrypt(Data("back".utf8))), Data("back".utf8))
        XCTAssertThrowsError(try ti.encrypt(Data(count: RelayNoise.maxPlaintextChunk + 1))) {
            XCTAssertEqual($0 as? RelayNoiseError, .messageTooLong)
        }
    }

    func testWrongResponderStaticKeyFails() throws {
        let i = Key(), real = Key(), other = Key()
        let ini = try RelayNoiseHandshake(
            initiatorStatic: i, responderStaticPublicKey: other.publicKey.rawRepresentation, prologue: Data())
        let resp = RelayNoiseHandshake(responderStatic: real, prologue: Data())
        XCTAssertThrowsError(try resp.readMessage(ini.writeMessage())) {
            XCTAssertEqual($0 as? RelayNoiseError, .decryptFailed)
        }
    }

    func testTamperedMessageOneFails() throws {
        let (ini, resp, _, _) = try pair()
        var m = try ini.writeMessage()
        m[40] ^= 1
        XCTAssertThrowsError(try resp.readMessage(m)) {
            XCTAssertEqual($0 as? RelayNoiseError, .decryptFailed)
        }
    }

    func testTamperedTransportFrameFails() throws {
        let (ti, tr) = try complete()
        var ct = try ti.encrypt(Data("secret".utf8))
        ct[0] ^= 1
        XCTAssertThrowsError(try tr.decrypt(ct)) {
            XCTAssertEqual($0 as? RelayNoiseError, .decryptFailed)
        }
    }

    func testReplayedTransportFrameFails() throws {
        let (ti, tr) = try complete()
        let ct = try ti.encrypt(Data("once".utf8))
        XCTAssertEqual(try tr.decrypt(ct), Data("once".utf8))
        XCTAssertThrowsError(try tr.decrypt(ct)) {
            XCTAssertEqual($0 as? RelayNoiseError, .decryptFailed)
        }
    }

    func testRemoteStaticPublicKeyAfterMessageOne() throws {
        let (ini, resp, i, _) = try pair()
        XCTAssertNil(resp.remoteStaticPublicKey)
        _ = try resp.readMessage(ini.writeMessage())
        XCTAssertEqual(resp.remoteStaticPublicKey, i.publicKey.rawRepresentation)
    }

    func testPrologueMismatchFails() throws {
        let i = Key(), r = Key()
        let ini = try RelayNoiseHandshake(
            initiatorStatic: i, responderStaticPublicKey: r.publicKey.rawRepresentation,
            prologue: RelayNoise.prologue(serverId: "a"))
        let resp = RelayNoiseHandshake(responderStatic: r, prologue: RelayNoise.prologue(serverId: "b"))
        XCTAssertThrowsError(try resp.readMessage(ini.writeMessage())) {
            XCTAssertEqual($0 as? RelayNoiseError, .decryptFailed)
        }
    }
}
