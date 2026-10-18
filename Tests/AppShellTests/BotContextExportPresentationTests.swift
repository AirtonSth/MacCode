import AgentRuntime
import AppKit
import CoreModel
import Foundation
import Persistence
import SocketServer
import SwiftUI
import XCTest
@testable import AppShell
@testable import Surfaces

@MainActor
final class BotContextExportPresentationTests: XCTestCase {
    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let vm: BotsViewModel
        let bot: BotDefinition
        let source: BotConversation
        let sourceThread: AgentThread
        let targetContext: BotContext
        let sourceRevision: Int64
        let targetRevision: Int64
    }

    private func fixture(_ label: String) throws -> Fixture {
        let parent = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]), isDirectory: true)
        let root = parent.appendingPathComponent("NativeExport-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let context = try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent("owned.sqlite").path,
            appSupportOverride: root.appendingPathComponent("support").path, privateAccountAPI: SilentWakeRecordingAPI(),
            performLaunchRunReconciliation: false, contextualSecretStore: InMemoryBotSecretStore())
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "Export target", cwd: workspaceRoot.path)
        let targetContext = BotContext.workspace(workspace.id)
        let bot = try context.botStore.create(name: "Export", title: "Export", description: "", soul: "", provider: .distill, model: "unused")
        let host = context.liveActivityHostIdentity.serverId
        let sourceGrant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .general, actions: [.read, .send, .export], expectedRevision: 0)
        let targetGrant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: targetContext, actions: [.read, .send], expectedRevision: 0)
        var sourceThread = AgentThread(title: "Source", provider: .distill, model: "unused")
        sourceThread.status = .completed
        let source = BotConversation(botID: bot.id, title: "Source", linkedAgentThreadID: sourceThread.id)
        try context.botStore.createContextualConversation(source, newThread: sourceThread, hostID: host, context: .general, policyRevision: sourceGrant.policyRevision)
        for text in ["first approved excerpt", "second approved excerpt"] {
            try context.messageRepo.append(AgentMessage(threadId: sourceThread.id, role: .assistant, content: text))
        }
        let vm = BotsViewModel(context: context, router: router, loadImmediately: false)
        router.botsViewModel = vm
        vm.openDesk(bot)
        vm.selectDeskThread(source.id)
        return Fixture(context: context, router: router, vm: vm, bot: bot, source: source, sourceThread: sourceThread,
            targetContext: targetContext, sourceRevision: sourceGrant.policyRevision, targetRevision: targetGrant.policyRevision)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func prepare(_ model: BotContextExportModel, target: BotContext) throws {
        XCTAssertNil(model.targetKey)
        XCTAssertTrue(model.selectedIDs.isEmpty)
        XCTAssertFalse(model.copied)
        XCTAssertEqual(model.rows.count, 2)
        model.toggle(model.rows[0])
        XCTAssertEqual(model.selectionCount, 1)
        model.chooseTarget(target.storageKey)
        XCTAssertEqual(model.targetKey, target.storageKey)
        model.preview()
    }

    /// Measures the shipped desk selection path (`selectDeskThread` through embedded history hydration)
    /// between two contextual conversations: one cold first selection, then warmed alternations.
    func testMeasureContextualDeskNavigationColdAndWarm() async throws {
        guard ProcessInfo.processInfo.environment["RC_CONTEXT_NAV_PROBE"] == "1" else {
            throw XCTSkip("set RC_CONTEXT_NAV_PROBE=1 to measure contextual desk navigation")
        }
        let f = try fixture("nav-perf")
        var secondThread = AgentThread(title: "Second", provider: .distill, model: "unused")
        secondThread.status = .completed
        let second = BotConversation(botID: f.bot.id, title: "Second", linkedAgentThreadID: secondThread.id)
        try f.context.botStore.createContextualConversation(second, newThread: secondThread,
            hostID: f.context.liveActivityHostIdentity.serverId, context: .general, policyRevision: f.sourceRevision)
        for index in 0..<40 {
            try f.context.messageRepo.append(AgentMessage(threadId: secondThread.id, role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "excerpt \(index) " + String(repeating: "x", count: 400)))
        }
        func select(_ conversation: BotConversation, thread: AgentThread) async throws -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            f.vm.selectDeskThread(conversation.id)
            let embedded = try XCTUnwrap(f.vm.deskAgentVM)
            await embedded.waitForMessageHistoryLoad()
            XCTAssertEqual(embedded.selectedThreadId, thread.id)
            XCTAssertFalse(embedded.messages.isEmpty, "navigation must land on hydrated canonical history")
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        let cold = try await select(second, thread: secondThread)
        var warm: [Double] = []
        for index in 0..<10 {
            warm.append(index.isMultiple(of: 2) ? try await select(f.source, thread: f.sourceThread) : try await select(second, thread: secondThread))
        }
        let sorted = warm.sorted()
        let report: [String: Any] = ["workload": "contextual desk selection to hydrated embedded history; two conversations (2 and 40 messages); in-process",
            "cold_ms": cold, "warm_ms": warm, "warm_median_ms": sorted[sorted.count / 2], "warm_max_ms": sorted.last ?? 0,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory, "os": ProcessInfo.processInfo.operatingSystemVersionString]
        let url = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]), isDirectory: true)
            .appendingPathComponent("context-navigation-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
        print("CONTEXT_NAV_REPORT: " + url.lastPathComponent)
        XCTAssertGreaterThanOrEqual(warm.count, 5)
    }

    func testCanonicalDeskSelectionHydratesEmbeddedAgentHistory() async throws {
        let f = try fixture("history")
        let expected = try f.context.messageRepo.list(threadId: f.sourceThread.id)
        XCTAssertEqual(expected.count, 2)
        let embedded = try XCTUnwrap(f.vm.deskAgentVM, "Canonical desk selection must mount its embedded Agent App model")
        await embedded.waitForMessageHistoryLoad()
        XCTAssertEqual(embedded.selectedThreadId, f.sourceThread.id)
        XCTAssertEqual(embedded.messages.map(\.id), expected.map(\.id), "Opening a contextual conversation must hydrate its canonical stored excerpts without provider execution")
        XCTAssertEqual(embedded.messages.map(\.content), expected.map(\.content), "Hydrated history must include the stored excerpt bodies, not only message shells")
    }

    private var openWindows: [NSWindow] = []

    override func tearDown() async throws {
        openWindows.removeAll()
        try await super.tearDown()
    }

    private func render(_ model: BotContextExportModel, name: String) throws -> NSBitmapImageRep {
        let size = CGSize(width: 640, height: 720)
        let hosting = NSHostingView(rootView: BotContextExportSheet(model: model).frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        openWindows.append(window)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("macos-export-\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
        }
        return bitmap
    }

    private func inkSamples(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(bitmap.pixelsHigh / 240, 1)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(bitmap.pixelsWide / 240, 1)) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent + c.greenComponent + c.blueComponent > 1.2 { count += 1 }
            }
        }
        return count
    }

    func testRealSheetRendersSelectionAndFrozenReviewFromRealModel() async throws {
        let f = try fixture("render")
        let model = try f.vm.makeContextExportModel { _ in }
        let selecting = try render(model, name: "selecting")
        try prepare(model, target: f.targetContext)
        await waitUntil { model.review != nil || model.errorMessage != nil }
        XCTAssertNotNil(model.review)
        let reviewed = try render(model, name: "review")
        XCTAssertGreaterThan(inkSamples(selecting), 50, "selection sheet must paint its excerpt rows")
        XCTAssertGreaterThan(inkSamples(reviewed), inkSamples(selecting) / 2, "review state must still paint content")
        XCTAssertNotEqual(selecting.representation(using: .png, properties: [:]), reviewed.representation(using: .png, properties: [:]),
                          "choosing an excerpt and target and previewing must visibly change the sheet")
    }

    func testRealPresentationReviewAndRevocationCannotCopyOrMutateConversations() async throws {
        let f = try fixture("revoke")
        var copies: [String] = []
        let model = try f.vm.makeContextExportModel { copies.append($0) }
        try prepare(model, target: f.targetContext)
        await waitUntil { model.review != nil || model.errorMessage != nil }
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.request["conversation_id"], .string(f.source.id.value.uuidString.lowercased()))
        XCTAssertEqual(review.request["target_context_key"], .string(f.targetContext.storageKey))
        XCTAssertEqual(review.request["target_policy_revision"], .number(Double(f.targetRevision)))
        XCTAssertEqual(review.request["message_ids"], .array([.string(model.rows[0].id)]))
        XCTAssertEqual(review.request["policy_revision"], .number(Double(f.sourceRevision)))
        model.chooseTarget("general:v1")
        model.toggle(model.rows[1])
        XCTAssertEqual(model.review, review)
        XCTAssertEqual(model.targetKey, f.targetContext.storageKey)
        XCTAssertEqual(model.selectedIDs, [model.rows[0].id])

        _ = try f.context.botStore.revokeContext(hostID: f.context.liveActivityHostIdentity.serverId, botID: f.bot.id,
            context: .general, expectedRevision: f.sourceRevision)
        let before = try f.context.botStore.listConversations(botID: f.bot.id)
        model.confirmAndCopy()
        await waitUntil { !model.isBusy || model.errorMessage != nil }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.review)
        XCTAssertFalse(model.copied)
        XCTAssertTrue(copies.isEmpty)
        XCTAssertEqual(try f.context.botStore.listConversations(botID: f.bot.id).map(\.id), before.map(\.id))
        XCTAssertEqual(try f.context.messageRepo.list(threadId: f.sourceThread.id).count, 2)
    }

    func testRealApprovedConfirmationCopiesReviewedSummaryOnce() async throws {
        let f = try fixture("confirm")
        var copies: [String] = []
        let model = try f.vm.makeContextExportModel { copies.append($0) }
        try prepare(model, target: f.targetContext)
        await waitUntil { model.review != nil || model.errorMessage != nil }
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.request["host_id"], .string(f.context.liveActivityHostIdentity.serverId))
        XCTAssertEqual(review.request["message_ids"], .array([.string(model.rows[0].id)]))
        model.confirmAndCopy()
        await waitUntil { model.copied || model.errorMessage != nil }
        XCTAssertTrue(model.copied, model.errorMessage ?? "Expected actual export confirmation")
        XCTAssertEqual(copies, [review.summary])
        model.confirmAndCopy()
        XCTAssertEqual(copies, [review.summary])
    }

    private func routeToDistill(_ f: Fixture) async throws {
        SettingsStore(db: f.context.db).update { $0.botsControlPlaneEnabled = true }
        _ = try await f.router.dispatchPairedBotRemote(method: "bot.routing.set", params: [
            "client_request_id": .string(UUID().uuidString.lowercased()),
            "bot_id": .string(f.bot.id.value.uuidString.lowercased()),
            "host_id": .string(f.context.liveActivityHostIdentity.serverId),
            "provider": .string("distill"), "provider_instance_id": .string("distill"),
            "model": .string("main-a"), "routing_mode": .string("explicit"),
        ])
    }

    func testContinueInDestinationCreatesNewConversationAndHoldsApprovedSummaryUnsent() async throws {
        let f = try fixture("continue")
        try await routeToDistill(f)
        let model = try f.vm.makeContextExportModel { _ in }
        try prepare(model, target: f.targetContext)
        await waitUntil { model.review != nil || model.errorMessage != nil }
        let review = try XCTUnwrap(model.review)
        model.continueInDestination()
        XCTAssertNil(model.continuedConversationID, "continuing must wait for the confirmed copy")
        model.confirmAndCopy()
        await waitUntil { model.copied || model.errorMessage != nil }
        XCTAssertTrue(model.copied, model.errorMessage ?? "export must confirm first")
        let before = try f.context.botStore.listConversations(botID: f.bot.id).map(\.id)
        model.continueInDestination()
        await waitUntil { model.continuedConversationID != nil || model.errorMessage != nil }
        let newID = try XCTUnwrap(model.continuedConversationID, model.errorMessage ?? "expected destination conversation")
        let conversations = try f.context.botStore.listConversations(botID: f.bot.id)
        XCTAssertEqual(conversations.count, before.count + 1, "exactly one new canonical conversation")
        let created = try XCTUnwrap(conversations.first { $0.id.value.uuidString.lowercased() == newID })
        XCTAssertNotEqual(created.id, f.source.id)
        let pin = try XCTUnwrap(try f.context.botStore.conversationContextPin(conversationID: created.id))
        XCTAssertEqual(pin.context, f.targetContext, "the new conversation is pinned to the reviewed destination")
        XCTAssertEqual(pin.policyRevision, f.targetRevision)
        let thread = try XCTUnwrap(created.linkedAgentThreadID)
        let queued = try f.context.queuedMessageRepo.list(threadId: thread)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued[0].text, review.summary, "the held text is exactly the reviewed summary")
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: queued[0].id.value.uuidString, db: f.context.db),
                      "the summary must stay held until the human sends it")
        XCTAssertTrue(try f.context.messageRepo.list(threadId: thread).isEmpty, "nothing is delivered or run")
        XCTAssertEqual(try f.context.messageRepo.list(threadId: f.sourceThread.id).count, 2, "source history is untouched")
        model.continueInDestination()
        await waitUntil { !model.isBusy }
        XCTAssertEqual(try f.context.botStore.listConversations(botID: f.bot.id).count, conversations.count, "no second conversation")
        XCTAssertEqual(try f.context.queuedMessageRepo.list(threadId: thread).count, 1, "no second queued copy")
    }

    func testContinueInDestinationRefusedWhenDestinationSendIsRevoked() async throws {
        let f = try fixture("continue-revoked")
        try await routeToDistill(f)
        let model = try f.vm.makeContextExportModel { _ in }
        try prepare(model, target: f.targetContext)
        await waitUntil { model.review != nil || model.errorMessage != nil }
        model.confirmAndCopy()
        await waitUntil { model.copied || model.errorMessage != nil }
        XCTAssertTrue(model.copied)
        _ = try f.context.botStore.revokeContext(hostID: f.context.liveActivityHostIdentity.serverId, botID: f.bot.id,
            context: f.targetContext, expectedRevision: f.targetRevision)
        let before = try f.context.botStore.listConversations(botID: f.bot.id).map(\.id)
        model.continueInDestination()
        await waitUntil { !model.isBusy && (model.errorMessage != nil || model.continuedConversationID != nil) }
        XCTAssertNil(model.continuedConversationID)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try f.context.botStore.listConversations(botID: f.bot.id).map(\.id), before,
                       "a revoked destination must not gain a conversation or queued text")
    }

    func testChangedSourceInvalidatesReviewWithoutCopy() async throws {
        let f = try fixture("source-change")
        var copies: [String] = []
        let model = try f.vm.makeContextExportModel { copies.append($0) }
        try prepare(model, target: f.targetContext)
        await waitUntil { model.review != nil || model.errorMessage != nil }
        XCTAssertNotNil(model.review)
        let secondThread = AgentThread(title: "Second source", provider: .distill, model: "unused")
        let second = BotConversation(botID: f.bot.id, title: "Second source", linkedAgentThreadID: secondThread.id)
        try f.context.botStore.createContextualConversation(second, newThread: secondThread,
            hostID: f.context.liveActivityHostIdentity.serverId, context: .general, policyRevision: f.sourceRevision)
        f.vm.selectDeskThread(second.id)
        model.confirmAndCopy()
        await waitUntil { !model.isBusy || model.errorMessage != nil }
        XCTAssertFalse(model.copied)
        XCTAssertTrue(copies.isEmpty)
        XCTAssertNil(model.review)
        XCTAssertNotNil(model.errorMessage)
    }
}
