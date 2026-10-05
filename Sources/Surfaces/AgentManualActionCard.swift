import AppKit
import SwiftUI
import CoreModel
import Persistence
import DesignSystemKit

extension AgentAppViewModel {
    /// Header pill text; a pending manual action overrides the run status.
    public var statusLabel: String {
        openManualAction == nil ? status.rawValue : "Aguardando você"
    }

    func manualActionStoreDidChange() {
        refreshManualAction()
        guard manualActionStore != nil, manualActionObserver == nil else { return }
        manualActionObserver = NotificationCenter.default.addObserver(
            forName: .botManualActionRequested, object: nil, queue: .main
        ) { [weak self] note in
            guard let request = note.userInfo?[BotHostNotificationKey.request] as? ManualActionRequest else { return }
            MainActor.assumeIsolated { self?.manualActionRequested(request) }
        }
    }

    private func manualActionRequested(_ request: ManualActionRequest) {
        guard let threadID = request.threadID, threadID == selectedThreadId, let store = manualActionStore else { return }
        // The router persists too; upsert is idempotent and keeps the card independent of observer order.
        if store.all(threadID: threadID).first(where: { $0.id == request.id }) == nil {
            store.upsert(request)
        }
        refreshManualAction()
    }

    func refreshManualAction() {
        guard let store = manualActionStore, let threadID = selectedThreadId else {
            if openManualAction != nil { openManualAction = nil }
            if !resolvedManualActions.isEmpty { resolvedManualActions = [] }
            return
        }
        var open = store.open(threadID: threadID)
        // Control is in-memory only: after a restart a taken request is handed back to the bot.
        if var request = open, request.state == .taken, !botComputerControl.isControlledByUser(request.botID) {
            request.state = .open
            store.upsert(request)
            open = request
        }
        let resolved = store.all(threadID: threadID).filter { $0.state == .continued || $0.state == .declined }
        if openManualAction != open { openManualAction = open }
        if resolvedManualActions != resolved { resolvedManualActions = resolved }
    }

    public func takeManualControl() {
        guard let store = manualActionStore, var request = openManualAction else { return }
        request.state = .taken
        store.upsert(request)
        botComputerControl.take(request.botID)
        refreshManualAction()
    }

    public func continueManualAction(note: String?) async {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = (trimmed?.isEmpty ?? true) ? nil : trimmed
        await resolveManualAction(.continued, note: stored) {
            ManualActionRequest.continueFollowUp(kind: $0.kind, note: stored)
        }
    }

    public func declineManualAction() async {
        await resolveManualAction(.declined, note: nil) { _ in ManualActionRequest.declineFollowUp }
    }

    /// The store transition is the single winner: any later or parallel caller gets nil and stays silent.
    private func resolveManualAction(
        _ state: ManualActionState,
        note: String?,
        followUp: (ManualActionRequest) -> String
    ) async {
        guard let store = manualActionStore, let open = openManualAction,
              let resolved = store.resolve(id: open.id, state: state, note: note) else {
            refreshManualAction()
            return
        }
        botComputerControl.release(resolved.botID)
        botComputerControl.dismiss(resolved.id, as: state, note: note)
        refreshManualAction()
        await sendManualActionFollowUp(followUp(resolved))
    }

    /// Goes through the normal composer send path; the user's draft is put back afterwards.
    private func sendManualActionFollowUp(_ text: String) async {
        let draft = prompt
        let draftAttachments = attachments
        attachments = []
        prompt = text
        await send()
        if prompt.isEmpty { prompt = draft }
        attachments = draftAttachments
    }
}

struct AgentManualActionCard: View {
    @ObservedObject var vm: AgentAppViewModel
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if let request = vm.openManualAction {
                openCard(request)
            }
            ForEach(vm.resolvedManualActions) { request in
                resolvedRow(request)
            }
        }
        .accessibilityIdentifier("agent.manualAction")
    }

    private func openCard(_ request: ManualActionRequest) -> some View {
        let executesOnMac = vm.threads.first(where: { $0.id == vm.selectedThreadId })?.executionTarget == .mac
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: Self.symbol(request.kind))
                    .font(.system(size: 12))
                    .foregroundColor(DS.Palette.warning)
                Text("\(vm.botNameProvider(request.botID) ?? "Bot") aguarda você")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                Spacer(minLength: 0)
                Text(request.createdAt, style: .relative)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            Text(request.reason)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.text)
            if let ref = request.screenshotRef, FileManager.default.fileExists(atPath: ref),
               let image = NSImage(contentsOfFile: ref) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 120)
                    .cornerRadius(6)
            }
            TextField("Nota para o bot (opcional)", text: $note)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agent.manualAction.note")
            HStack(spacing: DS.Space.sm) {
                if !executesOnMac {
                    Button(request.state == .taken ? "Controle assumido" : "Assumir controle") {
                        vm.takeManualControl()
                    }
                    .disabled(request.state == .taken)
                    .accessibilityIdentifier("agent.manualAction.take")
                }
                Button("Pronto, continuar") {
                    let text = note
                    note = ""
                    Task { await vm.continueManualAction(note: text) }
                }
                .accessibilityIdentifier("agent.manualAction.continue")
                Button("Recusar") {
                    Task { await vm.declineManualAction() }
                }
                .accessibilityIdentifier("agent.manualAction.decline")
            }
        }
        .padding(DS.Space.sm)
        .background(DS.Palette.surface)
        .cornerRadius(8)
    }

    private func resolvedRow(_ request: ManualActionRequest) -> some View {
        let minutes = max(0, Int((request.resolvedAt ?? request.createdAt).timeIntervalSince(request.createdAt) / 60))
        let outcome = request.state == .declined ? "recusado" : "continuado"
        return HStack(spacing: DS.Space.sm) {
            Image(systemName: Self.symbol(request.kind))
                .font(.system(size: 10))
                .foregroundColor(DS.Palette.textTertiary)
            Text("Você assumiu por \(minutes) min · \(outcome)")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
    }

    static func symbol(_ kind: ManualActionKind) -> String {
        switch kind {
        case .login: return "person.badge.key"
        case .captcha: return "checkmark.shield"
        case .twoFactor: return "lock.shield"
        case .payment: return "creditcard"
        case .confirm: return "hand.raised"
        case .other: return "hand.point.up.left"
        }
    }
}
