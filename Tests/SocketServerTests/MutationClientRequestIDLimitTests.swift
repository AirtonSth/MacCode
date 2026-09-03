import XCTest
@testable import SocketServer

@MainActor
final class MutationClientRequestIDLimitTests: XCTestCase {
    func test_validate_acceptsTrimmedUUIDHexDashAlnumUnderscoreWithinBounds() {
        // WHY: current iOS/macOS mutations use UUID client_request_id values.
        // The Stage 3 gate must keep those IDs while rejecting ledger bombs.
        let uuid = "8F3C1A2B-4D5E-6F70-8192-A3B4C5D6E7F8"
        XCTAssertEqual(MutationClientRequestID.validate(uuid), uuid)
        XCTAssertEqual(
            JSONRPCDispatcher.mutationClientRequestID(uuid),
            uuid
        )
        XCTAssertEqual(
            MutationClientRequestID.validate("  abcdefgh  "),
            "abcdefgh"
        )
        XCTAssertEqual(
            MutationClientRequestID.validate("id_with-Under1"),
            "id_with-Under1"
        )
        let maxID = String(repeating: "a", count: MutationClientRequestID.maximumLength)
        XCTAssertEqual(MutationClientRequestID.validate(maxID), maxID)
    }

    func test_validate_rejectsEmptyShortOversizedAndMalformed() {
        XCTAssertNil(MutationClientRequestID.validate(""))
        XCTAssertNil(MutationClientRequestID.validate("   "))
        XCTAssertNil(MutationClientRequestID.validate("short"))
        XCTAssertNil(MutationClientRequestID.validate("seven!!"))
        XCTAssertNil(
            MutationClientRequestID.validate(
                String(repeating: "a", count: MutationClientRequestID.maximumLength + 1)
            )
        )
        XCTAssertNil(MutationClientRequestID.validate("has.dotssss"))
        XCTAssertNil(MutationClientRequestID.validate("has space1"))
        XCTAssertNil(MutationClientRequestID.validate("slash/id12"))
        XCTAssertNil(MutationClientRequestID.validate("plus+sign1"))
        XCTAssertNil(JSONRPCDispatcher.mutationClientRequestID("too-big-\(String(repeating: "x", count: 200))"))
    }

    func test_mutationIdentity_rejectsOversizedAndMalformedBeforeClaim() async {
        // WHY: mutationIdentity is the claim gate. An oversized or
        // malformed ID must take the existing missing-id path (-32097)
        // so no receipt row is created.
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let context = MutationRequestContext(
            ownerFingerprint: "owner-1",
            hostId: "host-1",
            bootEpoch: 1
        )
        let rejected = [
            "short",
            String(repeating: "a", count: 129),
            "has.dotssss",
            "has space1",
            "slash/id12",
            "  padded  ",
        ]
        for id in rejected {
            let response = await dispatcher.dispatch(
                JSONRPCRequest(
                    jsonrpc: "2.0",
                    id: .number(1),
                    method: "workspace.create",
                    params: [
                        "client_request_id": .string(id),
                        "name": .string("n"),
                    ]
                ),
                mutationContext: context
            )
            XCTAssertEqual(
                response.error?.code,
                -32097,
                "malformed client_request_id \(id) must fail before claim"
            )
            XCTAssertNil(response.result, id)
        }

        let valid = await dispatcher.dispatch(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(2),
                method: "workspace.create",
                params: [
                    "client_request_id": .string("11111111-1111-4111-8111-111111111111"),
                    "name": .string("n"),
                ]
            ),
            mutationContext: context
        )
        XCTAssertNotEqual(
            valid.error?.code,
            -32097,
            "a UUID client_request_id must pass mutationIdentity"
        )
    }
}
