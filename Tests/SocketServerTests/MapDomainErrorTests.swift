import XCTest
@testable import SocketServer
import AgentRuntime
import Persistence
import CoreModel

/// T026 -- stable JSON-RPC error codes for known domain errors.
///
/// Why this matters: clients classify and display errors by code+data.domain.
/// A silent regression (new case, code drift, wrong data key) surfaces as a raw
/// Swift dump on iOS instead of a user-readable message.
@MainActor
final class MapDomainErrorTests: XCTestCase {

    // MARK: AgentProviderAdapterError

    func test_sessionNotFound_yields_32010_agentDomain() {
        let tid = AgentThreadID()
        let err = AgentProviderAdapterError.sessionNotFound(tid)

        let rpcErr = JSONRPCDispatcher.mapDomainError(err, method: "agent.message.send")

        XCTAssertEqual(rpcErr.code, -32010,
                       "session-not-found must use code -32010 so iOS can show a reconnect prompt, not a raw dump")
        guard case .object(let data) = rpcErr.data else {
            return XCTFail("data must be an object so the client can read domain+kind without parsing message text")
        }
        XCTAssertEqual(data["domain"], .string("agent"),
                       "domain field must be 'agent' so client can route to the agent error handler")
        XCTAssertEqual(data["kind"], .string("session_not_found"))
    }

    func test_unsupportedOperation_yields_32010_unsupportedKind() {
        let err = AgentProviderAdapterError.unsupported("rollback_during_run")

        let rpcErr = JSONRPCDispatcher.mapDomainError(err, method: "agent.thread.rollback")

        XCTAssertEqual(rpcErr.code, -32010)
        guard case .object(let data) = rpcErr.data else { return XCTFail() }
        XCTAssertEqual(data["domain"], .string("agent"))
        XCTAssertEqual(data["kind"], .string("unsupported"),
                       "unsupported-operation must carry kind='unsupported' so iOS can show a feature-not-available banner")
        XCTAssertEqual(data["detail"], .string("rollback_during_run"),
                       "detail must echo the operation string so diagnostics identify which call failed")
    }

    // MARK: PersistenceDataError

    func test_corruptProviderEventLog_yields_32011_persistenceDomain() {
        let err = PersistenceDataError.corruptProviderEventLog("missing event id")

        let rpcErr = JSONRPCDispatcher.mapDomainError(err, method: "agent.thread.read")

        XCTAssertEqual(rpcErr.code, -32011,
                       "persistence errors must use code -32011 so iOS distinguishes DB corruption from network/auth failures")
        guard case .object(let data) = rpcErr.data else { return XCTFail() }
        XCTAssertEqual(data["domain"], .string("persistence"))
        // detail must be non-empty so diagnostics have context
        if case .string(let detail) = data["detail"] {
            XCTAssertFalse(detail.isEmpty, "detail must contain the corruption description")
        } else {
            XCTFail("data.detail must be a string")
        }
    }

    func test_corruptCheckpoint_yields_32011() {
        let err = PersistenceDataError.corruptCheckpoint("invalid files_json for turn abc")

        let rpcErr = JSONRPCDispatcher.mapDomainError(err, method: "agent.checkpoint.diff")

        XCTAssertEqual(rpcErr.code, -32011)
    }

    // MARK: CocoaError file-not-found

    func test_cocoaFileNotFound_yields_32012_filesystemDomain() {
        let err = CocoaError(.fileNoSuchFile)

        let rpcErr = JSONRPCDispatcher.mapDomainError(err, method: "fs.workspace.read")

        XCTAssertEqual(rpcErr.code, -32012,
                       "missing-file errors must use code -32012 so iOS can show a 'file not found' message instead of a generic alert")
        guard case .object(let data) = rpcErr.data else { return XCTFail() }
        XCTAssertEqual(data["domain"], .string("filesystem"))
        XCTAssertEqual(data["kind"], .string("not_found"))
    }

    func test_cocoaFileReadNotFound_yields_32012() {
        let err = CocoaError(.fileReadNoSuchFile)
        let rpcErr = JSONRPCDispatcher.mapDomainError(err, method: "fs.workspace.read")
        XCTAssertEqual(rpcErr.code, -32012)
    }

    // MARK: Heuristic missing-binary detection

    func test_missingBinaryHeuristic_yields_32012_binaryDomain() {
        struct FakeMissingBinary: Error, CustomStringConvertible {
            var description: String { "MissingBinary: codex executable not found at /usr/local/bin/codex" }
        }

        let rpcErr = JSONRPCDispatcher.mapDomainError(FakeMissingBinary(), method: "agent.message.send")

        XCTAssertEqual(rpcErr.code, -32012,
                       "binary-not-found heuristic must yield -32012 so iOS can show an 'install the CLI' prompt")
        guard case .object(let data) = rpcErr.data else { return XCTFail() }
        XCTAssertEqual(data["domain"], .string("binary"),
                       "binary errors must declare domain='binary' so the client can link to the install guide")
    }

    // MARK: Unknown error fallback (UX-005 / todo-ux/cross-platform line 21)

    /// WHY: iOS displays the JSON-RPC error message verbatim in the UI. Before
    /// UX-005 the fallback was `String(describing: error)`, which leaks Swift
    /// type names and internal state to users. The fix pins the fallback to a
    /// safe generic message; the verbose description is logged server-side only.
    func test_unknownError_yields_32000_withGenericSafeMessage() {
        struct RandomError: Error, CustomStringConvertible {
            var description: String { "something_unexpected_internal" }
        }

        let rpcErr = JSONRPCDispatcher.mapDomainError(RandomError(), method: "workspace.create")

        XCTAssertEqual(rpcErr.code, -32000,
                       "unclassified errors must fall back to -32000 so the iOS generic error handler is exercised rather than silently ignored")
        // Contract pin: iOS must receive this exact string so both platforms
        // can match on it and the copy is coordinated.
        XCTAssertEqual(rpcErr.message, "An unexpected error occurred on the host.",
                       "fallback message must be the pinned safe string — never a Swift debug dump")
        XCTAssertFalse(rpcErr.message.contains("something_unexpected_internal"),
                       "internal error description must NOT appear in the user-facing message")
    }
}
