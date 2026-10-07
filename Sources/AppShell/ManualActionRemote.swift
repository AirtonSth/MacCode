import CoreModel
import Foundation
import Persistence
import SocketServer

/// Paired-device side of manual actions (`agent.manual_action.*`). The store
/// transition is the same single winner the Mac card uses, so a card, a phone
/// and parallel calls resolve a request once and the bot gets one follow-up.
extension AppCommandRouter {
    public func listManualActions(thread: AgentThreadID) throws -> [ManualActionSnapshot] {
        guard let ctx = context, let stored = try ctx.threadRepo.get(id: thread) else { return [] }
        return manualActionStore.all(threadID: thread).map { manualActionSnapshot($0, thread: stored) }
    }

    public func pendingManualActions(for threads: [AgentThread]) -> [AgentThreadID: ManualActionSnapshot] {
        guard !threads.isEmpty else { return [:] }
        let open = manualActionStore.openByThread()
        guard !open.isEmpty else { return [:] }
        var pending: [AgentThreadID: ManualActionSnapshot] = [:]
        for thread in threads {
            if let request = open[thread.id] { pending[thread.id] = manualActionSnapshot(request, thread: thread) }
        }
        return pending
    }

    public func resolveManualAction(
        thread: AgentThreadID,
        id: UUID,
        resolution: ManualActionResolution,
        note: String?
    ) async throws -> ManualActionResolveOutcome {
        guard let ctx = context,
              let stored = try ctx.threadRepo.get(id: thread),
              let current = manualActionStore.all(threadID: thread).first(where: { $0.id == id }) else {
            throw DefiniteMutationRejection(ManualActionWire.refusal(
                code: ManualActionWire.notFoundCode, kind: "not_found",
                message: "This manual action is not on this thread."
            ))
        }
        let control = botComputerControl
        let changed: ManualActionRequest
        var followUpText: String?
        do {
            switch resolution {
            case .take:
                guard stored.executionTarget != .mac else {
                    throw DefiniteMutationRejection(ManualActionWire.refusal(
                        code: ManualActionWire.takeUnavailableCode, kind: "take_unavailable",
                        message: "This bot runs on the Mac; there is no bot computer to take."
                    ))
                }
                // Control is in-memory only: after a restart a taken request is the bot's again (as on the Mac card).
                if current.state == .taken, !control.isControlledByUser(current.botID) {
                    var reopened = current
                    reopened.state = .open
                    try manualActionStore.upsert(reopened)
                }
                guard let taken = try manualActionStore.take(id: id, control: control) else {
                    throw stateConflict(id: id, thread: thread)
                }
                changed = taken
            case .continue, .decline:
                let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
                let kept = resolution == .continue && !(trimmed?.isEmpty ?? true) ? trimmed : nil
                let state: ManualActionState = resolution == .continue ? .continued : .declined
                guard let resolved = try manualActionStore.resolve(id: id, state: state, note: kept, control: control) else {
                    throw stateConflict(id: id, thread: thread)
                }
                changed = resolved
                followUpText = resolution == .continue
                    ? ManualActionRequest.continueFollowUp(kind: resolved.kind, note: kept)
                    : ManualActionRequest.declineFollowUp
            }
        } catch let rejection as DefiniteMutationRejection {
            throw rejection
        } catch {
            // The store write failed before anything changed (the request stays open).
            throw DefiniteMutationRejection(ManualActionWire.refusal(
                code: -32000, kind: "store_unavailable",
                message: "Manual action could not be saved: \(error.localizedDescription)"
            ))
        }
        // Every Mac card refreshes, and the observer publishes agent.manual_action.updated
        // synchronously, inside this call, so the ledger puts it in the receipt.
        postManualActionStateChanged(changed)
        var followUp: ManualActionResolveOutcome.FollowUp?
        if let followUpText {
            // Same follow-up text and send path as the Mac card and Mac-execution approvals.
            do {
                followUp = .sent(try await sendAgentMessage(
                    thread: thread, text: followUpText,
                    provider: nil, model: nil, permissionMode: nil, reasoningEffort: nil
                ))
            } catch {
                followUp = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
        }
        let latest = manualActionStore.all(threadID: thread)
        let changedNow = latest.first(where: { $0.id == id }) ?? changed
        return ManualActionResolveOutcome(
            manualAction: manualActionSnapshot(changedNow, thread: stored),
            pending: latest.last(where: { $0.state.isOpen }).map { manualActionSnapshot($0, thread: stored) },
            followUp: followUp
        )
    }

    /// Mac card and RPC changes arrive here through `.manualActionStateChanged`;
    /// a new request through `handleManualActionRequested`.
    func publishManualActionUpdated(thread: AgentThreadID, requestID: UUID) {
        guard let ctx = context, let stored = try? ctx.threadRepo.get(id: thread) else { return }
        let all = manualActionStore.all(threadID: thread)
        guard let changed = all.first(where: { $0.id == requestID }) else { return }
        EventBus.shared.publish(kind: .agentManualActionUpdated, payload: ManualActionWire.updatedEvent(
            thread: thread,
            manualAction: manualActionSnapshot(changed, thread: stored),
            pending: all.last(where: { $0.state.isOpen }).map { manualActionSnapshot($0, thread: stored) }
        ))
    }

    private func postManualActionStateChanged(_ request: ManualActionRequest) {
        var info: [String: Any] = [BotHostNotificationKey.request: request]
        if let threadID = request.threadID { info[BotHostNotificationKey.threadID] = threadID }
        NotificationCenter.default.post(name: .manualActionStateChanged, object: nil, userInfo: info)
    }

    private func stateConflict(id: UUID, thread: AgentThreadID) -> DefiniteMutationRejection {
        let state = manualActionStore.all(threadID: thread).first(where: { $0.id == id })?.state
        return DefiniteMutationRejection(ManualActionWire.refusal(
            code: ManualActionWire.stateConflictCode, kind: "state_conflict",
            message: "This manual action was already answered.", state: state
        ))
    }

    private func manualActionSnapshot(_ request: ManualActionRequest, thread: AgentThread) -> ManualActionSnapshot {
        var shown = request
        if shown.state == .taken, !botComputerControl.isControlledByUser(shown.botID) { shown.state = .open }
        let botName = (try? context?.botStore.get(id: request.botID))??.name
        return ManualActionSnapshot(request: shown, botName: botName, canTake: thread.executionTarget != .mac)
    }
}
