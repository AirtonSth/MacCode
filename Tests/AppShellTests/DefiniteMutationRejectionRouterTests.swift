import XCTest
@testable import AppShell
import CoreModel
import Persistence
@testable import SocketServer

/// WHY: C35. iPhone agent.* mutations go through the remote receipt ledger.
/// Refusals the real router makes before writing anything (send to a thread
/// deleted on the Mac, cancel of a queue item that already drained) used to
/// be stored as permanent `unknown` receipts and answered with -32095, so the
/// phone showed "couldn't confirm" and every same-id retry stayed unknown.
@MainActor
final class DefiniteMutationRejectionRouterTests: XCTestCase {
    private var temporaryDirectories: [String] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func test_sendToMissingThreadReturnsDomainErrorAndLeavesNoReceipt() async throws {
        let (context, router) = try make()
        let dispatcher = JSONRPCDispatcher(router: router)
        let params = mutationParams(requestId: "send-missing-thread", extra: [
            "thread_id": .string(UUID().uuidString),
            "text": .string("hello"),
        ])

        let first = await dispatcher.dispatch(request("agent.message.send", params), mutationContext: mutationContext)
        let retry = await dispatcher.dispatch(request("agent.message.send", params), mutationContext: mutationContext)

        XCTAssertNotNil(first.error)
        XCTAssertNotEqual(first.error?.code, -32095)
        XCTAssertEqual(retry.error?.code, first.error?.code)
        XCTAssertEqual(
            try context.commandReceiptRepo.status(
                method: "agent.message.send",
                clientRequestId: "send-missing-thread",
                ownerFingerprint: mutationContext.ownerFingerprint
            ),
            .absent
        )
    }

    func test_cancelOfDrainedQueueItemReturnsInvalidParamsAndLeavesNoReceipt() async throws {
        let (context, router) = try make()
        let dispatcher = JSONRPCDispatcher(router: router)
        let params = mutationParams(requestId: "cancel-drained", extra: [
            "queued_message_id": .string(UUID().uuidString),
        ])

        let first = await dispatcher.dispatch(request("agent.message.queue.cancel", params), mutationContext: mutationContext)
        let retry = await dispatcher.dispatch(request("agent.message.queue.cancel", params), mutationContext: mutationContext)

        XCTAssertEqual(first.error?.code, -32602)
        XCTAssertEqual(retry.error?.code, -32602)
        XCTAssertEqual(
            try context.commandReceiptRepo.status(
                method: "agent.message.queue.cancel",
                clientRequestId: "cancel-drained",
                ownerFingerprint: mutationContext.ownerFingerprint
            ),
            .absent
        )
    }

    private let mutationContext = MutationRequestContext(
        ownerFingerprint: "owner-c35",
        hostId: "host-c35",
        bootEpoch: 1
    )

    private func request(_ method: String, _ params: [String: JSONValue]) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: method, params: params)
    }

    private func mutationParams(requestId: String, extra: [String: JSONValue]) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "client_request_id": .string(requestId),
            "connection_id": .string("c35-connection"),
            "expected_host_id": .string(mutationContext.hostId),
            "expected_boot_epoch": .number(1),
        ]
        for (key, value) in extra { params[key] = value }
        return params
    }

    private func make() throws -> (AppContext, AppCommandRouter) {
        let directory = NSTemporaryDirectory() + "RC2DefiniteRejection-" + UUID().uuidString
        temporaryDirectories.append(directory)
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        return (context, router)
    }
}
