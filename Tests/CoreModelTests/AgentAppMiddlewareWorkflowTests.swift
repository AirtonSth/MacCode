import XCTest
@testable import CoreModel

final class AgentAppMiddlewareWorkflowTests: XCTestCase {
    private enum DefiniteSendFailure: Error, AgentAppMiddlewareSendFailure {
        case rejected

        var agentAppMiddlewareSendFailureDisposition: AgentAppMiddlewareSendFailureDisposition {
            .definite
        }
    }

    func test_managedProviderCannotDowngradeMissingDelegationScopeIntoRootLaunch() {
        // WHY: a provider process is managed by the host even when inherited
        // environment propagation is partial. Missing proof must fail closed
        // instead of creating an unrelated root that escapes the Subagents tree.
        let runID = UUID().uuidString
        let threadID = UUID().uuidString
        let capability = String(repeating: "a", count: 64)

        XCTAssertTrue(AgentDelegationCapabilityTransport.permitsAgentAppLaunch(
            middlewareEnabled: false,
            parentRunID: nil,
            parentThreadID: nil,
            parentCapability: nil
        ))
        XCTAssertTrue(AgentDelegationCapabilityTransport.permitsAgentAppLaunch(
            middlewareEnabled: true,
            parentRunID: runID,
            parentThreadID: threadID,
            parentCapability: capability
        ))
        XCTAssertFalse(AgentDelegationCapabilityTransport.permitsAgentAppLaunch(
            middlewareEnabled: true,
            parentRunID: runID,
            parentThreadID: threadID,
            parentCapability: nil
        ))
        XCTAssertFalse(AgentDelegationCapabilityTransport.permitsAgentAppLaunch(
            middlewareEnabled: true,
            parentRunID: runID,
            parentThreadID: threadID,
            parentCapability: String(repeating: "A", count: 64)
        ))
        XCTAssertFalse(AgentDelegationCapabilityTransport.permitsAgentAppLaunch(
            middlewareEnabled: true,
            parentRunID: "not-a-run-id",
            parentThreadID: threadID,
            parentCapability: capability
        ))
    }

    func test_timeoutPolicyUsesTurnTimeoutUnlessCallerExplicitlyOverridesIt() {
        // WHY: starting an Agent App turn can legitimately take longer than
        // the one-shot rc2 default; the middleware must not abandon the RPC
        // before the host has persisted and admitted the child run.
        XCTAssertEqual(
            AgentAppMiddlewareTimeoutPolicy.receiveTimeoutMS(
                explicitGlobalTimeoutMS: nil,
                turnTimeoutMS: 120_000
            ),
            120_000
        )
        XCTAssertEqual(
            AgentAppMiddlewareTimeoutPolicy.receiveTimeoutMS(
                explicitGlobalTimeoutMS: 30_000,
                turnTimeoutMS: 120_000
            ),
            30_000
        )
    }

    func test_execute_routesHeadlessTurnThroughAgentAppAndReturnsFinalAssistantMessage() throws {
        // WHY: a delegated provider must traverse the same Agent App RPC path as
        // a visible turn so persistence and usage events
        // are owned by the host instead of a parallel raw-CLI implementation.
        let workspaceID = UUID()
        let threadID = UUID()
        let runID = UUID()
        let parentRunID = UUID()
        let parentThreadID = UUID()
        let parentCapability = String(repeating: "a", count: 64)
        var calls: [(String, [String: AgentAppRPCValue])] = []
        var threadPolls = 0

        let output = try AgentAppMiddlewareWorkflow.execute(
            request: AgentAppMiddlewareRequest(
                provider: .grok,
                prompt: "bounded worker task",
                workspaceID: workspaceID.uuidString,
                title: "Subagent · Grok",
                model: "grok-4.5",
                permissionMode: .autoAcceptEdits,
                reasoningEffort: .high,
                parentRunID: parentRunID.uuidString,
                parentThreadID: parentThreadID.uuidString,
                subagentNodeID: "nested.grok.42.abc",
                parentCapability: parentCapability,
                runtimeProfile: .samGrokWorkerV1
            ),
            maxPolls: 5,
            call: { method, params in
                calls.append((method, params))
                switch method {
                case "agent.thread.create":
                    return .object(["id": .object(["value": .string(threadID.uuidString)])])
                case "agent.message.send":
                    return .object([
                        "status": .string("started"),
                        "run_id": .object(["value": .string(runID.uuidString)])
                    ])
                case "agent.thread.list":
                    threadPolls += 1
                    return .array([
                        .object([
                            "id": .object(["value": .string(threadID.uuidString)]),
                            "active_run_id": threadPolls == 1
                                ? .object(["value": .string(runID.uuidString)])
                                : .null
                        ])
                    ])
                case "agent.message.list":
                    return .array([
                        .object(["role": .string("user"), "content": .string("bounded worker task")]),
                        .object(["role": .string("assistant"), "content": .string("worker result")])
                    ])
                default:
                    XCTFail("unexpected RPC \(method)")
                    return .null
                }
            },
            wait: {}
        )

        XCTAssertEqual(output.threadID, threadID.uuidString)
        XCTAssertEqual(output.runID, runID.uuidString)
        XCTAssertEqual(output.response, "worker result")
        XCTAssertEqual(
            calls.map(\.0),
            [
                "agent.thread.create",
                "agent.message.send",
                "agent.thread.list",
                "agent.thread.list",
                "agent.message.list"
            ]
        )
        XCTAssertEqual(calls[0].1["workspace_id"], .string(workspaceID.uuidString))
        XCTAssertEqual(calls[0].1["provider"], .string("grok"))
        XCTAssertEqual(calls[0].1["permission_mode"], .string("auto_accept_edits"))
        XCTAssertEqual(calls[0].1["reasoning_effort"], .string("high"))
        XCTAssertEqual(calls[0].1["parent_run_id"], .string(parentRunID.uuidString))
        XCTAssertEqual(calls[0].1["parent_thread_id"], .string(parentThreadID.uuidString))
        XCTAssertEqual(calls[0].1["subagent_node_id"], .string("nested.grok.42.abc"))
        XCTAssertEqual(
            calls[0].1[AgentDelegationCapabilityTransport.rpcParameterKey],
            .string(parentCapability)
        )
        XCTAssertEqual(calls[0].1["runtime_profile"], .string("sam-grok-worker-v1"))
        XCTAssertEqual(calls[1].1["text"], .string("bounded worker task"))
        XCTAssertEqual(calls[1].1["parent_run_id"], .string(parentRunID.uuidString))
        XCTAssertEqual(calls[1].1["parent_thread_id"], .string(parentThreadID.uuidString))
        XCTAssertEqual(calls[1].1["subagent_node_id"], .string("nested.grok.42.abc"))
        XCTAssertEqual(
            calls[1].1[AgentDelegationCapabilityTransport.rpcParameterKey],
            .string(parentCapability)
        )
        XCTAssertEqual(calls[1].1["runtime_profile"], .string("sam-grok-worker-v1"))
    }

    func test_execute_resolvesSelectedWorkspaceWhenNestedScopeDoesNotProvideOne() throws {
        // WHY: `remote-code agent-app ...` must also work from a normal terminal,
        // not only from a provider process carrying receipt metadata.
        let workspaceID = UUID()
        let threadID = UUID()

        let output = try AgentAppMiddlewareWorkflow.execute(
            request: AgentAppMiddlewareRequest(
                provider: .codex,
                prompt: "review",
                workspaceID: nil,
                model: "gpt-5.6-sol",
                permissionMode: .supervised,
                reasoningEffort: .medium
            ),
            maxPolls: 2,
            call: { method, _ in
                switch method {
                case "agent.state.current":
                    return .object(["selected_workspace_id": .string(workspaceID.uuidString)])
                case "agent.thread.create":
                    return .object(["id": .string(threadID.uuidString)])
                case "agent.message.send":
                    return .object(["status": .string("started")])
                case "agent.thread.list":
                    return .array([.object(["id": .string(threadID.uuidString), "active_run_id": .null])])
                case "agent.message.list":
                    return .array([.object(["role": .string("assistant"), "content": .string("reviewed")])])
                default:
                    XCTFail("unexpected RPC \(method)")
                    return .null
                }
            },
            wait: {}
        )

        XCTAssertEqual(output.response, "reviewed")
    }

    func test_executeRejectsPartialNestedContextBeforeCreatingThread() {
        // WHY: a partially propagated controller context must never silently
        // create an unparented root that disappears from the Subagents tree.
        var calls = 0

        XCTAssertThrowsError(
            try AgentAppMiddlewareWorkflow.execute(
                request: AgentAppMiddlewareRequest(
                    provider: .grok,
                    prompt: "task",
                    workspaceID: UUID().uuidString,
                    model: "grok-4.5",
                    parentRunID: UUID().uuidString
                ),
                maxPolls: 1,
                call: { _, _ in
                    calls += 1
                    return .null
                },
                wait: {}
            )
        ) { error in
            XCTAssertEqual(error as? AgentAppMiddlewareError, .invalidNestedContext)
        }

        XCTAssertEqual(calls, 0)
    }

    func test_executeRejectsRuntimeProfileWithoutCompleteNestedContext() {
        // WHY: a closed provider runtime profile may only be selected through
        // a host-validated parent receipt, never by a standalone CLI caller.
        var calls = 0

        XCTAssertThrowsError(
            try AgentAppMiddlewareWorkflow.execute(
                request: AgentAppMiddlewareRequest(
                    provider: .grok,
                    prompt: "task",
                    workspaceID: UUID().uuidString,
                    model: "grok-4.5",
                    runtimeProfile: .samGrokWorkerV1
                ),
                maxPolls: 1,
                call: { _, _ in
                    calls += 1
                    return .null
                },
                wait: {}
            )
        ) { error in
            XCTAssertEqual(error as? AgentAppMiddlewareError, .invalidNestedContext)
        }
        XCTAssertEqual(calls, 0)
    }

    func test_executeReconcilesAcceptedTurnWhenSendAckConnectionCloses() throws {
        // WHY: a provider turn is a non-idempotent mutation. If the socket
        // closes after the host accepted it, retrying would run the subagent
        // twice; persisted thread state is the authoritative reconciliation.
        let threadID = UUID()
        var sendCalls = 0
        var threadListCalls = 0
        var messageListCalls = 0
        var waits = 0

        let output = try AgentAppMiddlewareWorkflow.execute(
            request: AgentAppMiddlewareRequest(
                provider: .grok,
                prompt: "task",
                workspaceID: UUID().uuidString,
                model: "grok-4.5"
            ),
            maxPolls: 3,
            call: { method, _ in
                switch method {
                case "agent.thread.create":
                    return .object(["id": .object(["value": .string(threadID.uuidString)])])
                case "agent.message.send":
                    sendCalls += 1
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
                case "agent.thread.list":
                    threadListCalls += 1
                    if threadListCalls == 1 {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
                    }
                    return .array([
                        .object([
                            "id": .object(["value": .string(threadID.uuidString)]),
                            "active_run_id": .null
                        ])
                    ])
                case "agent.message.list":
                    messageListCalls += 1
                    if messageListCalls == 1 {
                        return .array([
                            .object(["role": .string("user"), "content": .string("task")])
                        ])
                    }
                    return .array([
                        .object(["role": .string("user"), "content": .string("task")]),
                        .object(["role": .string("assistant"), "content": .string("done")])
                    ])
                default:
                    XCTFail("unexpected RPC \(method)")
                    return .null
                }
            },
            wait: { waits += 1 }
        )

        XCTAssertEqual(output.response, "done")
        XCTAssertEqual(sendCalls, 1)
        XCTAssertEqual(threadListCalls, 3)
        XCTAssertEqual(messageListCalls, 2)
        XCTAssertEqual(waits, 2)
    }

    func test_executeSurfacesDefiniteSendRejectionAndDeletesOnlyItsEmptyThread() {
        // WHY: a host rejection cannot become a one-hour orphan-thread poll.
        // The middleware may compensate only the exact thread it just created,
        // after proving that no run or message was durably accepted.
        let workspaceID = UUID()
        let threadID = UUID()
        var calls: [(String, [String: AgentAppRPCValue])] = []
        var waits = 0

        XCTAssertThrowsError(
            try AgentAppMiddlewareWorkflow.execute(
                request: AgentAppMiddlewareRequest(
                    provider: .grok,
                    prompt: "task",
                    workspaceID: workspaceID.uuidString,
                    model: "grok-4.5"
                ),
                maxPolls: 36_000,
                call: { method, params in
                    calls.append((method, params))
                    switch method {
                    case "agent.thread.create":
                        return .object(["id": .string(threadID.uuidString)])
                    case "agent.message.send":
                        throw DefiniteSendFailure.rejected
                    case "agent.thread.list":
                        return .array([
                            .object([
                                "id": .string(threadID.uuidString),
                                "active_run_id": .null
                            ])
                        ])
                    case "agent.message.list":
                        return .array([])
                    case "agent.thread.delete":
                        return .bool(true)
                    default:
                        XCTFail("unexpected RPC \(method)")
                        return .null
                    }
                },
                wait: { waits += 1 }
            )
        ) { error in
            XCTAssertEqual(error as? DefiniteSendFailure, .rejected)
        }

        XCTAssertEqual(
            calls.map(\.0),
            [
                "agent.thread.create",
                "agent.message.send",
                "agent.thread.list",
                "agent.message.list",
                "agent.thread.delete"
            ]
        )
        XCTAssertEqual(calls.last?.1, ["thread_id": .string(threadID.uuidString)])
        XCTAssertEqual(waits, 0)
    }

    func test_executeDoesNotDeleteDefiniteFailureWhenDurableMessageExists() {
        // WHY: compensation must fail safe if the host persisted any evidence,
        // even when it also returned a definite rejection to the CLI.
        let threadID = UUID()
        var deleted = false

        XCTAssertThrowsError(
            try AgentAppMiddlewareWorkflow.execute(
                request: AgentAppMiddlewareRequest(
                    provider: .claude,
                    prompt: "task",
                    workspaceID: UUID().uuidString,
                    model: "sonnet"
                ),
                maxPolls: 2,
                call: { method, _ in
                    switch method {
                    case "agent.thread.create":
                        return .object(["id": .string(threadID.uuidString)])
                    case "agent.message.send":
                        throw DefiniteSendFailure.rejected
                    case "agent.thread.list":
                        return .array([
                            .object([
                                "id": .string(threadID.uuidString),
                                "active_run_id": .null
                            ])
                        ])
                    case "agent.message.list":
                        return .array([
                            .object(["role": .string("user"), "content": .string("task")])
                        ])
                    case "agent.thread.delete":
                        deleted = true
                        return .bool(true)
                    default:
                        return .null
                    }
                },
                wait: {}
            )
        ) { error in
            XCTAssertEqual(error as? DefiniteSendFailure, .rejected)
        }

        XCTAssertFalse(deleted)
    }

    func test_executeFailsLoudWhenTurnFinishesWithoutAssistantOutput() {
        // WHY: a failed child must not be reported as successful merely because
        // the provider process stopped; orchestrators need an explicit blocker.
        let threadID = UUID()

        XCTAssertThrowsError(
            try AgentAppMiddlewareWorkflow.execute(
                request: AgentAppMiddlewareRequest(
                    provider: .claude,
                    prompt: "task",
                    workspaceID: UUID().uuidString,
                    model: "sonnet"
                ),
                maxPolls: 1,
                call: { method, _ in
                    switch method {
                    case "agent.thread.create":
                        return .object(["id": .string(threadID.uuidString)])
                    case "agent.message.send":
                        return .object(["status": .string("started")])
                    case "agent.thread.list":
                        return .array([.object(["id": .string(threadID.uuidString), "active_run_id": .null])])
                    case "agent.message.list":
                        return .array([.object(["role": .string("user"), "content": .string("task")])])
                    default:
                        return .null
                    }
                },
                wait: {}
            )
        ) { error in
            XCTAssertEqual(error as? AgentAppMiddlewareError, .missingAssistantResponse)
        }
    }
}
