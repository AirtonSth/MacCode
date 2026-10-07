import Foundation
import SwiftUI
import CoreModel
import Persistence
import SocketServer
import Surfaces
import DesignSystemKit

// MARK: - Roster sections (pure)

/// How the Bots sidebar groups the roster. Nil when there are no teams: the
/// "My Bots" list then stays the flat roster it has always been.
struct BotRosterSections: Equatable {
    struct Team: Equatable {
        let team: BotTeam
        let bots: [BotDefinition]
    }

    let teams: [Team]
    /// Roster bots that belong to no team.
    let otherBots: [BotDefinition]

    /// `roster` is the visible roster (search and Show hidden applied); a bot
    /// appears under every team it belongs to, in the team's member order.
    static func make(
        roster: [BotDefinition],
        teams: [BotTeam],
        membersByTeam: [BotTeamID: [BotID]]
    ) -> BotRosterSections? {
        guard !teams.isEmpty else { return nil }
        let byID = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var inTeam = Set<BotID>()
        let sections = teams.map { team -> Team in
            let members = (membersByTeam[team.id] ?? []).compactMap { byID[$0] }
            members.forEach { inTeam.insert($0.id) }
            return Team(team: team, bots: members)
        }
        return BotRosterSections(teams: sections, otherBots: roster.filter { !inTeam.contains($0.id) })
    }
}

// MARK: - Controller

/// Bot teams and group conversations for the Mac Bots UI: the sidebar lists,
/// the selected group's room surface, sheets and the room inspector. Every
/// change goes through `BotTeamGroupService`, so paired devices see it too.
@MainActor
public final class BotTeamsGroupsController: ObservableObject {
    enum Sheet: Identifiable, Equatable {
        case team(BotTeamID?)
        case newGroup(teamID: BotTeamID?)
        case editGroup(BotGroupID)

        var id: String {
            switch self {
            case .team(let id): return "team.\(id?.value.uuidString ?? "new")"
            case .newGroup(let teamID): return "group.new.\(teamID?.value.uuidString ?? "")"
            case .editGroup(let id): return "group.edit.\(id.value.uuidString)"
            }
        }
    }

    enum PendingDelete: Equatable {
        case team(BotTeamID)
        case group(BotGroupID)
    }

    @Published private(set) var teams: [BotTeam] = []
    @Published private(set) var membersByTeam: [BotTeamID: [BotID]] = [:]
    /// Every group (hidden ones too: the sidebar shows them under Show
    /// hidden), pinned first then most recent.
    @Published private(set) var groups: [BotGroupConversation] = []
    /// Active participants per group, in participant order.
    @Published private(set) var participantsByGroup: [BotGroupID: [BotGroupParticipant]] = [:]
    /// A participant's private member thread, once its first turn created it.
    struct MemberThread: Equatable, Sendable {
        let threadID: AgentThreadID
        let provider: AgentProvider
        /// Locked execution target of the thread (nil before the lock).
        let target: ExecutionTarget?
    }
    @Published private(set) var memberThreads: [BotGroupID: [BotID: MemberThread]] = [:]
    /// Failed or interrupted turns of the selected group's last round that
    /// an active participant can retry.
    @Published private(set) var retryableTurns: [BotGroupID: [BotGroupTurn]] = [:]
    @Published private(set) var selectedGroupID: BotGroupID?
    /// The open group (hidden or not), published with the selection.
    @Published private(set) var selectedGroup: BotGroupConversation?
    @Published var collapsedTeamIDs: Set<BotTeamID> = [] {
        didSet { persistCollapsedTeams() }
    }
    @Published var isInspectorVisible = true {
        didSet { UserDefaults.standard.set(isInspectorVisible, forKey: Self.inspectorDefaultsKey) }
    }
    /// Presented by the sidebar roster (or the Bots window root).
    @Published var sheet: Sheet?
    /// Presented by the group room itself (the inspector's Edit…), which is
    /// on screen whenever the inspector is, sidebar collapsed or not.
    @Published var roomSheet: Sheet?
    @Published var pendingDelete: PendingDelete?
    /// The selected group's room, mounted as an embedded Agent App.
    @Published private(set) var roomVM: AgentAppViewModel?
    /// A participant's private member thread shown in place of the room.
    @Published private(set) var privateThreadBotID: BotID?
    @Published private(set) var privateThreadVM: AgentAppViewModel?

    static let selectedGroupDefaultsKey = "bots.selectedGroupID"
    static let collapsedTeamsDefaultsKey = "bots.collapsedTeamIDs"
    static let inspectorDefaultsKey = "bots.groupInspector"
    static let privateThreadReadOnlyMessage = "This is the bot's private thread. Write in the group."
    static let roomPlaceholder = "Message the group. @mention a bot to choose who answers…"

    private let context: AppContext
    private let routerProvider: () -> AppCommandRouter?
    /// Errors the user must see (the Bots alert).
    var onError: ((String) -> Void)?
    /// The selected group is gone (deleted here or on a paired device).
    var onSelectedGroupVanished: (() -> Void)?
    private var isRoomVisible = false
    private var roomThreadID: AgentThreadID?
    private var reloadGeneration: UInt64 = 0
    private var reloadTask: Task<Void, Never>?
    private var eventSubscription: UUID?
    /// Bumped on every reload so the room's mention list refreshes.
    private var participantsRevision: UInt64 = 0
    private(set) var reloadCountForTesting = 0

    init(context: AppContext, routerProvider: @escaping () -> AppCommandRouter?) {
        self.context = context
        self.routerProvider = routerProvider
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.selectedGroupDefaultsKey), let uuid = UUID(uuidString: raw) {
            selectedGroupID = BotGroupID(uuid)
        }
        if let raw = defaults.stringArray(forKey: Self.collapsedTeamsDefaultsKey) {
            collapsedTeamIDs = Set(raw.compactMap(UUID.init(uuidString:)).map(BotTeamID.init))
        }
        if defaults.object(forKey: Self.inspectorDefaultsKey) != nil {
            isInspectorVisible = defaults.bool(forKey: Self.inspectorDefaultsKey)
        }
        // The restored group's identity only (one row) so the room can mount
        // on this turn; the lists load off the main actor.
        if let id = selectedGroupID {
            selectedGroup = (try? context.botStore.group(id: id)) ?? nil
            if selectedGroup == nil {
                selectedGroupID = nil
                defaults.removeObject(forKey: Self.selectedGroupDefaultsKey)
            } else {
                loadParticipantsIfMissing(id)
            }
        }
        scheduleReload()
        let subscription = EventBus.shared.subscribeFromCurrent(
            filter: .kindPrefixes(["bot.team.updated", "bot.group.updated"])
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleReload() }
        }
        eventSubscription = subscription.id
    }

    deinit {
        reloadTask?.cancel()
        if let eventSubscription { EventBus.shared.unsubscribe(eventSubscription) }
    }

    private var service: BotTeamGroupService { context.botTeamGroupService }
    private var botStore: BotStore { context.botStore }

    func participants(of groupID: BotGroupID) -> [BotGroupParticipant] {
        participantsByGroup[groupID] ?? []
    }

    func bots(in groupID: BotGroupID, from roster: [BotDefinition]) -> [BotDefinition] {
        let byID = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return participants(of: groupID).compactMap { byID[$0.botID] }
    }

    // MARK: Loading

    private struct Snapshot {
        let teams: [BotTeam]
        let members: [BotTeamMember]
        let groups: [BotGroupConversation]
        let participants: [BotGroupID: [BotGroupParticipant]]
        let memberThreads: [BotGroupID: [BotID: MemberThread]]
        let retryable: [BotGroupID: [BotGroupTurn]]
    }

    private nonisolated static func read(
        _ store: BotStore,
        threads: AgentThreadRepository,
        selectedGroupID: BotGroupID?
    ) throws -> Snapshot {
        let groups = try store.listGroups(includeHidden: true)
        var participants: [BotGroupID: [BotGroupParticipant]] = [:]
        var memberThreads: [BotGroupID: [BotID: MemberThread]] = [:]
        for group in groups {
            participants[group.id] = try store.listGroupParticipants(groupID: group.id)
            for conversation in try store.listGroupMemberConversations(groupID: group.id) {
                guard let threadID = conversation.linkedAgentThreadID,
                      let thread = try threads.get(id: threadID) else { continue }
                memberThreads[group.id, default: [:]][conversation.botID] = MemberThread(
                    threadID: threadID,
                    provider: thread.provider,
                    target: thread.actorLockedAt != nil ? thread.executionTarget : nil
                )
            }
        }
        var retryable: [BotGroupID: [BotGroupTurn]] = [:]
        if let selectedGroupID, groups.contains(where: { $0.id == selectedGroupID }) {
            retryable[selectedGroupID] = try retryableTurns(
                store, groupID: selectedGroupID, active: Set((participants[selectedGroupID] ?? []).map(\.botID))
            )
        }
        return Snapshot(
            teams: try store.listTeams(),
            members: try store.listTeamMembers(),
            groups: groups,
            participants: participants,
            memberThreads: memberThreads,
            retryable: retryable
        )
    }

    /// The last round's failed or interrupted turns of bots still in the
    /// group (two reads, never the group's whole history).
    nonisolated static func retryableTurns(
        _ store: BotStore,
        groupID: BotGroupID,
        active: Set<BotID>
    ) throws -> [BotGroupTurn] {
        guard let last = try store.latestGroupTurn(groupID: groupID, states: BotGroupTurn.State.allCases) else {
            return []
        }
        return try store.listGroupTurns(groupID: groupID, roundID: last.roundID).filter {
            ($0.state == .failed || $0.state == .interrupted) && active.contains($0.botID)
        }
    }

    /// Synchronous read (small tables) right after a local edit, so the
    /// sidebar shows it on the same turn. Launch uses `scheduleReload`.
    func reload() {
        reloadGeneration &+= 1
        reloadTask?.cancel()
        reloadTask = nil
        do {
            apply(try Self.read(botStore, threads: context.threadRepo, selectedGroupID: selectedGroupID))
        } catch {
            onError?(Self.message(for: error))
        }
    }

    /// Coalesced, latest-wins refresh after a team or group event (a paired
    /// device's edit, a turn's attention change).
    func scheduleReload() {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        let store = botStore
        let threads = context.threadRepo
        let selected = selectedGroupID
        reloadTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.read(store, threads: threads, selectedGroupID: selected) }
            }.value
            guard let self, !Task.isCancelled, generation == self.reloadGeneration else { return }
            self.reloadTask = nil
            if case .success(let snapshot) = result { self.apply(snapshot) }
        }
    }

    /// Awaits the pending event-driven refresh (tests).
    func settleReloadForTesting() async {
        await reloadTask?.value
    }

    private func apply(_ snapshot: Snapshot) {
        reloadCountForTesting += 1
        participantsRevision &+= 1
        if teams != snapshot.teams { teams = snapshot.teams }
        let members = Dictionary(grouping: snapshot.members, by: \.teamID).mapValues { $0.map(\.botID) }
        if membersByTeam != members { membersByTeam = members }
        if groups != snapshot.groups { groups = snapshot.groups }
        if participantsByGroup != snapshot.participants { participantsByGroup = snapshot.participants }
        if memberThreads != snapshot.memberThreads { memberThreads = snapshot.memberThreads }
        if retryableTurns != snapshot.retryable { retryableTurns = snapshot.retryable }
        guard let selectedGroupID else { return }
        if let group = snapshot.groups.first(where: { $0.id == selectedGroupID }) {
            // Hidden or not, the open group keeps its room.
            if selectedGroup != group { selectedGroup = group }
            if isRoomVisible { syncRoom() }
        } else if (try? botStore.group(id: selectedGroupID)) ?? nil == nil {
            selectGroup(nil)
            onSelectedGroupVanished?()
        }
    }

    // MARK: Selection and the room

    /// Publishes the selection now; the room mounts on the same turn (cached
    /// transcript from the repo), and the read/attention clear runs after.
    func selectGroup(_ id: BotGroupID?) {
        if selectedGroupID != id {
            selectedGroupID = id
            closePrivateThread()
        }
        if selectedGroup?.id != id {
            selectedGroup = id.flatMap { id in groups.first { $0.id == id } ?? ((try? botStore.group(id: id)) ?? nil) }
        }
        if let id { loadParticipantsIfMissing(id) }
        if let id {
            UserDefaults.standard.set(id.value.uuidString.lowercased(), forKey: Self.selectedGroupDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedGroupDefaultsKey)
        }
        syncRoom()
        guard let id else { return }
        // After the open commits (the screen flips to the group on this turn).
        Task { @MainActor [weak self] in
            guard let self, self.selectedGroupID == id, self.isRoomVisible else { return }
            _ = try? self.service.select(groupID: id)
        }
    }

    /// The open group's participants are part of its identity (header,
    /// mentions, lead): one read when the list pass has not landed yet.
    private func loadParticipantsIfMissing(_ id: BotGroupID) {
        guard participantsByGroup[id] == nil,
              let participants = try? botStore.listGroupParticipants(groupID: id) else { return }
        participantsByGroup[id] = participants
        participantsRevision &+= 1
    }

    /// The Bots screen changed: the room exists only while the group screen shows.
    func setRoomVisible(_ visible: Bool) {
        guard isRoomVisible != visible else { return }
        isRoomVisible = visible
        syncRoom()
    }

    private func syncRoom() {
        guard isRoomVisible, let group = selectedGroup, let router = routerProvider() else {
            service.setViewing(nil, by: self)
            tearDownRoom()
            return
        }
        // A reply in the room on screen is read as it lands (no dot).
        service.setViewing(group.id, by: self)
        if roomThreadID == group.roomThreadID, roomVM != nil { return }
        tearDownRoom()
        let groupID = group.id
        let embedding = AgentAppEmbedding(
            pinnedThreadId: group.roomThreadID,
            sendInterceptor: { [weak self] text, attachments, _ in
                guard let self else { throw BotStoreError.notFound }
                return try self.sendToGroup(groupID, text: text, attachments: attachments)
            },
            composerPlaceholder: Self.roomPlaceholder
        )
        let vm = makeEmbeddedVM(threadID: group.roomThreadID, embedding: embedding, router: router)
        vm.mentionableBotsProvider = { [weak self] in
            guard let self else { return [] }
            let roster = (try? self.botStore.listCached()) ?? []
            return self.bots(in: groupID, from: roster)
        }
        vm.mentionableBotsRevisionProvider = { [weak self] in
            guard let self else { return 0 }
            return self.botStore.botsListRevision &+ self.participantsRevision
        }
        roomThreadID = group.roomThreadID
        roomVM = vm
    }

    private func tearDownRoom() {
        closePrivateThread()
        roomThreadID = nil
        guard let vm = roomVM else { return }
        roomVM = nil
        vm.dispose()
    }

    /// The group send: user line plus one waiting row per answering bot,
    /// written on this turn; the rows come back for the room to paint.
    func sendToGroup(_ groupID: BotGroupID, text: String, attachments: [AgentAttachment]) throws -> [AgentMessage] {
        let receipt = try service.send(
            groupID: groupID,
            text: text,
            submitKey: UUID().uuidString.lowercased(),
            attachments: attachments
        )
        guard receipt.roomMessages.isEmpty else { return receipt.roomMessages }
        // A replayed send: its rows are already written, read them back.
        let ids = [receipt.userMessageID] + receipt.turns.map(\.roomMessageID)
        return ids.compactMap { (try? context.messageRepo.get(id: $0)) ?? nil }
    }

    /// Opens a participant's private member thread (read-only; the bot's own
    /// runs, approvals and errors show there).
    func openPrivateThread(botID: BotID) {
        guard let group = selectedGroup, let router = routerProvider() else { return }
        guard let threadID = memberThreadID(groupID: group.id, botID: botID) else {
            onError?("This bot has not answered in this group yet.")
            return
        }
        closePrivateThread()
        let embedding = AgentAppEmbedding(
            pinnedThreadId: threadID,
            sendInterceptor: { _, _, _ in
                throw BotGroupOrchestrator.SendError.rejected(Self.privateThreadReadOnlyMessage)
            },
            composerPlaceholder: Self.privateThreadReadOnlyMessage
        )
        privateThreadVM = makeEmbeddedVM(threadID: threadID, embedding: embedding, router: router)
        privateThreadBotID = botID
    }

    func closePrivateThread() {
        privateThreadBotID = nil
        guard let vm = privateThreadVM else { return }
        privateThreadVM = nil
        vm.dispose()
    }

    /// Read from the last reload; a participant that left keeps no entry.
    func memberThreadID(groupID: BotGroupID, botID: BotID) -> AgentThreadID? {
        guard participants(of: groupID).contains(where: { $0.botID == botID }) else { return nil }
        return memberThreads[groupID]?[botID]?.threadID
    }

    private func makeEmbeddedVM(
        threadID: AgentThreadID,
        embedding: AgentAppEmbedding,
        router: AppCommandRouter
    ) -> AgentAppViewModel {
        let vm = AgentAppViewModel(
            workspaceID: BotsViewModel.botDeskWorkspaceID,
            cwd: context.appSupportDirectory.path,
            coordinator: context.coordinator,
            threadRepo: context.threadRepo,
            messageRepo: context.messageRepo,
            draftRepo: AgentThreadDraftRepository(db: context.db),
            attachmentStore: AgentAttachmentStore(
                root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
            ),
            queuedMessageRepo: context.queuedMessageRepo,
            providerSessionRepo: context.providerSessionRuntimeRepo,
            pendingCallbackRepo: context.providerPendingCallbackRepo,
            proposedPlanRepo: context.proposedPlanRepo,
            checkpointRepo: context.turnCheckpointRepo,
            promptHistoryStore: PromptHistoryStore(db: context.db),
            customModelStore: AgentCustomModelStore(repo: context.settingsRepo),
            planNotesStore: PlanNotesStore(db: context.db),
            initialThreadId: threadID,
            initialRoutingMode: .manual,
            orchestrationRuntime: context.orchestrationRuntime,
            embedding: embedding
        )
        vm.botNameProvider = { [weak self] botID in
            (try? self?.botStore.get(id: botID))??.name
        }
        vm.markThreadRead = { [weak router] id in
            try router?.markAgentThreadRead(thread: id)
        }
        return vm
    }

    /// A room row changed (waiting row → reply, or a failure row).
    func applyPeerMessage(messageID: AgentMessageID, threadID: AgentThreadID, terminalStatus: AgentRunStatus?) {
        roomVM?.applyPersistedBotPeerMessage(messageID: messageID, threadId: threadID, terminalStatus: terminalStatus)
        privateThreadVM?.applyPersistedBotPeerMessage(
            messageID: messageID, threadId: threadID, terminalStatus: terminalStatus
        )
    }

    // MARK: Edits

    func toggleCollapsed(_ teamID: BotTeamID) {
        if collapsedTeamIDs.contains(teamID) {
            collapsedTeamIDs.remove(teamID)
        } else {
            collapsedTeamIDs.insert(teamID)
        }
    }

    private func persistCollapsedTeams() {
        UserDefaults.standard.set(
            collapsedTeamIDs.map { $0.value.uuidString.lowercased() }.sorted(),
            forKey: Self.collapsedTeamsDefaultsKey
        )
    }

    @discardableResult
    func saveTeam(id: BotTeamID?, name: String, description: String, memberBotIDs: [BotID]) -> Bool {
        do {
            if let id {
                guard let current = try botStore.team(id: id) else { throw BotStoreError.notFound }
                let team = try service.updateTeam(
                    id: id, expectedRevision: current.revision, name: name, description: description
                )
                if Set(membersByTeam[id] ?? []) != Set(memberBotIDs) || (membersByTeam[id] ?? []) != memberBotIDs {
                    try service.setTeamMembers(id: id, expectedRevision: team.revision, botIDs: memberBotIDs)
                }
            } else {
                try service.createTeam(name: name, description: description, memberBotIDs: memberBotIDs)
            }
            reload()
            return true
        } catch {
            reload()
            onError?(Self.message(for: error))
            return false
        }
    }

    func deleteTeam(_ id: BotTeamID) {
        do {
            try service.deleteTeam(id: id)
            collapsedTeamIDs.remove(id)
        } catch {
            onError?(Self.message(for: error))
        }
        reload()
    }

    struct GroupDraft: Equatable {
        var title: String
        var teamID: BotTeamID?
        var participantBotIDs: [BotID]
        var policy: BotGroupPolicy
        var leadBotID: BotID?
        var maxAutoHops: Int
    }

    /// Creates the group and opens it. The sheet stays until the room exists.
    func createGroup(_ draft: GroupDraft, open: @escaping (BotGroupID) -> Void) async -> Bool {
        do {
            let group = try await service.createGroup(
                title: draft.title,
                teamID: draft.teamID,
                policy: draft.policy,
                leadBotID: draft.policy == .lead ? draft.leadBotID : nil,
                maxAutoHops: draft.maxAutoHops,
                participantBotIDs: draft.participantBotIDs
            )
            reload()
            open(group.id)
            return true
        } catch {
            onError?(Self.message(for: error))
            return false
        }
    }

    /// Settings and participants, each compare-and-set on the latest revision.
    /// A lead that is not yet a participant is applied after the participants.
    @discardableResult
    func saveGroup(id: BotGroupID, draft: GroupDraft) -> Bool {
        do {
            guard var group = try botStore.group(id: id) else { throw BotStoreError.notFound }
            let current = Set(try botStore.listGroupParticipants(groupID: id).map(\.botID))
            let wanted = draft.participantBotIDs
            let lead = draft.policy == .lead ? draft.leadBotID : nil
            let leadReadyNow = lead.map(current.contains) ?? true
            group = try service.updateGroup(id: id, expectedRevision: group.revision) { group in
                group.title = draft.title
                group.maxAutoHops = draft.maxAutoHops
                if leadReadyNow {
                    group.policy = draft.policy
                    group.leadBotID = lead
                } else if group.policy == .lead, let old = group.leadBotID, !wanted.contains(old) {
                    // The old lead leaves before the new one joins.
                    group.policy = .roundtable
                }
            }
            if Set(wanted) != current || (participantsByGroup[id] ?? []).map(\.botID) != wanted {
                group = try service.setGroupParticipants(id: id, expectedRevision: group.revision, botIDs: wanted)
            }
            if !leadReadyNow {
                group = try service.updateGroup(id: id, expectedRevision: group.revision) { group in
                    group.policy = draft.policy
                    group.leadBotID = lead
                }
            }
            reload()
            return true
        } catch {
            reload()
            onError?(Self.message(for: error))
            return false
        }
    }

    func setPolicy(_ policy: BotGroupPolicy, groupID: BotGroupID) {
        updateSelected(groupID) { group in
            group.policy = policy
            if policy == .lead, group.leadBotID == nil {
                group.leadBotID = self.participants(of: groupID).first?.botID
            }
        }
    }

    func setLead(_ botID: BotID, groupID: BotGroupID) {
        updateSelected(groupID) { $0.leadBotID = botID }
    }

    func setMaxAutoHops(_ hops: Int, groupID: BotGroupID) {
        let clamped = min(max(hops, 0), BotGroupConversation.maxAutoHopsCap)
        updateSelected(groupID) { $0.maxAutoHops = clamped }
    }

    func setPinned(_ pinned: Bool, groupID: BotGroupID) {
        updateSelected(groupID) { $0.pinned = pinned }
    }

    /// Like a hidden bot: off the sidebar unless Show hidden is on. An open
    /// hidden group keeps its room.
    func setHidden(_ hidden: Bool, groupID: BotGroupID) {
        updateSelected(groupID) { $0.hidden = hidden }
    }

    /// Retries the last round's failed or interrupted turns, in order. The
    /// first refusal stops the rest and is shown.
    func retryFailedTurns(groupID: BotGroupID) {
        for turn in retryableTurns[groupID] ?? [] {
            do {
                try service.retryTurn(groupID: groupID, turnID: turn.id)
            } catch {
                onError?(Self.message(for: error))
                break
            }
        }
        reload()
    }

    private func updateSelected(_ groupID: BotGroupID, _ mutate: @escaping (inout BotGroupConversation) -> Void) {
        do {
            guard let group = try botStore.group(id: groupID) else { throw BotStoreError.notFound }
            try service.updateGroup(id: groupID, expectedRevision: group.revision, mutate)
        } catch {
            onError?(Self.message(for: error))
        }
        reload()
    }

    func stop(groupID: BotGroupID) {
        do { try service.stop(groupID: groupID) } catch { onError?(Self.message(for: error)) }
    }

    func deleteGroup(_ id: BotGroupID) async {
        do {
            try await service.deleteGroup(id: id)
        } catch {
            onError?(Self.message(for: error))
        }
        reload()
    }

    nonisolated static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

// MARK: - BotsViewModel entry points

extension BotsViewModel {
    /// Opens a group's room: selection and screen publish on this turn.
    public func openGroup(_ id: BotGroupID) {
        teamsGroups.selectGroup(id)
        screen = .group
    }

    func beginCreateTeam() { teamsGroups.sheet = .team(nil) }
    func beginEditTeam(_ id: BotTeamID) { teamsGroups.sheet = .team(id) }
    func beginCreateGroup(teamID: BotTeamID? = nil) { teamsGroups.sheet = .newGroup(teamID: teamID) }
}

// MARK: - Sidebar

/// "New Team…" and "New Group…" (the My Bots "+" menu and the New Bot row's
/// context menu).
struct BotTeamsGroupsCreateButtons: View {
    @ObservedObject var vm: BotsViewModel

    var body: some View {
        Button("New Team…") { vm.beginCreateTeam() }
            .disabled(!vm.isControlPlaneActive)
            .accessibilityIdentifier("bots.roster.add.team")
        Button("New Group…") { vm.beginCreateGroup() }
            .disabled(!vm.isControlPlaneActive || vm.bots.isEmpty)
            .accessibilityIdentifier("bots.roster.add.group")
    }
}

/// Team sections, "Other Bots" and "Group Conversations" under My Bots.
/// Bot rows are the roster's own row (`row`), never a second implementation.
struct BotRosterTeamSections<Row: View>: View {
    @ObservedObject var vm: BotsViewModel
    @ObservedObject var teamsGroups: BotTeamsGroupsController
    let sections: BotRosterSections?
    let row: (BotDefinition) -> Row

    var body: some View {
        if let sections {
            ForEach(sections.teams, id: \.team.id) { section in
                teamSection(section)
            }
            if !sections.otherBots.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    sectionTitle("Other Bots")
                    ForEach(sections.otherBots, id: \.id) { bot in row(bot) }
                }
                .accessibilityIdentifier("bots.roster.otherBots")
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(DS.Font.caption)
            .foregroundColor(DS.Palette.textTertiary)
            .padding(.horizontal, DS.Space.sm)
    }

    private func teamSection(_ section: BotRosterSections.Team) -> some View {
        let collapsed = teamsGroups.collapsedTeamIDs.contains(section.team.id)
        return VStack(alignment: .leading, spacing: DS.Space.lg) {
            Button {
                withAnimation(DS.Motion.standard) { teamsGroups.toggleCollapsed(section.team.id) }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(section.team.name)
                        .font(DS.Font.caption)
                        .lineLimit(1)
                    Text("\(section.bots.count)")
                        .font(DS.Font.caption2)
                    Spacer(minLength: 0)
                }
                .foregroundColor(DS.Palette.textTertiary)
                .padding(.horizontal, DS.Space.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show \(section.team.name)" : "Hide \(section.team.name)")
            .accessibilityLabel(section.team.name)
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            .accessibilityIdentifier("bots.roster.team.\(section.team.id.value.uuidString.lowercased())")
            .contextMenu {
                Button("Edit Team…") { vm.beginEditTeam(section.team.id) }
                    .disabled(!vm.isControlPlaneActive)
                Button("New Group from Team…") { vm.beginCreateGroup(teamID: section.team.id) }
                    .disabled(!vm.isControlPlaneActive || section.bots.isEmpty)
                Divider()
                Button("Delete Team", role: .destructive) {
                    teamsGroups.pendingDelete = .team(section.team.id)
                }
            }
            if !collapsed {
                if section.bots.isEmpty {
                    Text(vm.searchText.isEmpty ? "No bots in this team" : "No matches")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .padding(.horizontal, DS.Space.md)
                } else {
                    ForEach(section.bots, id: \.id) { bot in row(bot) }
                }
            }
        }
    }
}

/// "Group Conversations": stacked participant avatars, title, attention dot.
struct BotGroupConversationsSection: View {
    @ObservedObject var vm: BotsViewModel
    @ObservedObject var teamsGroups: BotTeamsGroupsController

    var body: some View {
        let visible = filteredGroups
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Group Conversations")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .padding(.horizontal, DS.Space.sm)
                ForEach(visible, id: \.id) { group in groupRow(group) }
            }
            .accessibilityIdentifier("bots.groups")
        }
    }

    private var filteredGroups: [BotGroupConversation] {
        let shown = vm.showHidden ? teamsGroups.groups : teamsGroups.groups.filter { !$0.hidden }
        let query = vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return shown }
        return shown.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func dotColor(_ state: BotAttentionState) -> Color? {
        switch state {
        case .needsAttention: return DS.Palette.warning
        case .unreadActivity: return DS.Palette.accent
        case .working, .none: return nil
        }
    }

    private func groupRow(_ group: BotGroupConversation) -> some View {
        let selected = vm.screen == .group && teamsGroups.selectedGroupID == group.id
        let members = teamsGroups.bots(in: group.id, from: vm.bots)
        let names = members.map(\.name).joined(separator: ", ")
        let key = group.id.value.uuidString.lowercased()
        return Button {
            vm.openGroup(group.id)
        } label: {
            HStack(spacing: DS.Space.sm) {
                BotStackedAvatars(bots: members, size: 26)
                    .frame(width: BotsChrome.rosterAvatarSize, height: BotsChrome.rosterAvatarSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title)
                        .font(selected || group.unread ? DS.Font.bodyStrong : DS.Font.body)
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Text(names.isEmpty ? "No bots" : names)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if group.attentionState == .working {
                    DSBusySpinner(label: BotsChrome.statusTitle(for: .working), identifier: "bots.groups.busy.\(key)")
                } else if let color = dotColor(group.attentionState) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                if group.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(minHeight: BotsChrome.hitTarget)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(selected ? DS.Palette.accent.opacity(0.18) : Color.white.opacity(0.001))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(group.title) · \(BotsChrome.statusTitle(for: group.attentionState))")
        .accessibilityLabel(group.title)
        .accessibilityValue("\(group.hidden ? "Hidden. " : "")\(BotsChrome.statusTitle(for: group.attentionState)). \(names)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("bots.groups.row.\(key)")
        .contextMenu {
            Button(group.pinned ? "Unpin" : "Pin") { teamsGroups.setPinned(!group.pinned, groupID: group.id) }
                .disabled(!vm.isControlPlaneActive)
            Button(group.hidden ? "Unhide" : "Hide") { teamsGroups.setHidden(!group.hidden, groupID: group.id) }
                .disabled(!vm.isControlPlaneActive)
                .accessibilityIdentifier("bots.groups.menu.hide")
            Button("Edit Group…") { teamsGroups.sheet = .editGroup(group.id) }
                .disabled(!vm.isControlPlaneActive)
            Divider()
            Button("Delete Group", role: .destructive) { teamsGroups.pendingDelete = .group(group.id) }
        }
    }
}

/// Up to three overlapping participant avatars.
struct BotStackedAvatars: View {
    let bots: [BotDefinition]
    let size: CGFloat

    var body: some View {
        let shown = Array(bots.prefix(3))
        ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, bot in
                BotsAvatarView(name: bot.name, handle: bot.handle, symbol: bot.avatarSymbol, size: size)
                    .overlay(Circle().stroke(DS.Palette.surface, lineWidth: 1.5))
                    .offset(x: CGFloat(index) * size * 0.45, y: CGFloat(index % 2) * size * 0.25)
            }
        }
        .frame(
            width: size + CGFloat(max(shown.count - 1, 0)) * size * 0.45,
            height: size * (shown.count > 1 ? 1.25 : 1),
            alignment: .topLeading
        )
        .accessibilityHidden(true)
    }
}

/// Team/group sheets and delete confirmations. Attached once per window
/// (sidebar roster in the main shell, the root in the detached window).
struct BotTeamsGroupsSheets: ViewModifier {
    @ObservedObject var vm: BotsViewModel
    @ObservedObject var teamsGroups: BotTeamsGroupsController
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .sheet(item: $teamsGroups.sheet) { sheet in
                    BotTeamsGroupsSheetContent(vm: vm, teamsGroups: teamsGroups, sheet: sheet)
                }
                .confirmationDialog(
                    deleteTitle,
                    isPresented: Binding(
                        get: { teamsGroups.pendingDelete != nil },
                        set: { if !$0 { teamsGroups.pendingDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        let pending = teamsGroups.pendingDelete
                        teamsGroups.pendingDelete = nil
                        switch pending {
                        case .team(let id): teamsGroups.deleteTeam(id)
                        case .group(let id): Task { await teamsGroups.deleteGroup(id) }
                        case nil: break
                        }
                    }
                    .accessibilityIdentifier("bots.teamsGroups.delete.confirm")
                    Button("Cancel", role: .cancel) { teamsGroups.pendingDelete = nil }
                } message: {
                    Text(deleteMessage)
                }
        } else {
            content
        }
    }

    private var deleteTitle: String {
        switch teamsGroups.pendingDelete {
        case .team(let id): return "Delete \(teamsGroups.teams.first { $0.id == id }?.name ?? "this team")?"
        case .group(let id): return "Delete \(teamsGroups.groups.first { $0.id == id }?.title ?? "this group")?"
        case nil: return "Delete?"
        }
    }

    private var deleteMessage: String {
        switch teamsGroups.pendingDelete {
        case .team: return "The bots and their conversations stay."
        case .group: return "The group transcript and each bot's private thread for it are deleted. The bots stay."
        case nil: return ""
        }
    }
}

// MARK: - Sheets

struct BotTeamsGroupsSheetContent: View {
    @ObservedObject var vm: BotsViewModel
    @ObservedObject var teamsGroups: BotTeamsGroupsController
    let sheet: BotTeamsGroupsController.Sheet

    var body: some View {
        switch sheet {
        case .team(let id):
            BotTeamEditorSheet(vm: vm, teamsGroups: teamsGroups, teamID: id)
        case .newGroup(let teamID):
            BotGroupEditorSheet(vm: vm, teamsGroups: teamsGroups, mode: .create(teamID: teamID))
        case .editGroup(let id):
            BotGroupEditorSheet(vm: vm, teamsGroups: teamsGroups, mode: .edit(id))
        }
    }
}

struct BotTeamEditorSheet: View {
    @ObservedObject var vm: BotsViewModel
    @ObservedObject var teamsGroups: BotTeamsGroupsController
    let teamID: BotTeamID?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var members: [BotID] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text(teamID == nil ? "New Team" : "Edit Team")
                .font(DS.Font.title2.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            TextField("Team name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("bots.team.name")
            TextField("Description (optional)", text: $description)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("bots.team.description")
            Text("Members")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    if vm.bots.isEmpty {
                        Text("No bots yet").font(DS.Font.body).foregroundColor(DS.Palette.textTertiary)
                    }
                    ForEach(vm.bots, id: \.id) { bot in
                        Toggle(isOn: Binding(
                            get: { members.contains(bot.id) },
                            set: { on in
                                if on { if !members.contains(bot.id) { members.append(bot.id) } }
                                else { members.removeAll { $0 == bot.id } }
                            }
                        )) {
                            BotPickRow(bot: bot)
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("bots.team.member.\(bot.handle)")
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 320)
            Text("A bot can be in several teams.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(teamID == nil ? "Create Team" : "Save") {
                    if teamsGroups.saveTeam(id: teamID, name: name, description: description, memberBotIDs: members) {
                        dismiss()
                    }
                }
                .buttonStyle(BotsPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !vm.isControlPlaneActive)
                .accessibilityIdentifier("bots.team.save")
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 420)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let teamID, let team = teamsGroups.teams.first(where: { $0.id == teamID }) {
                name = team.name
                description = team.description
                members = teamsGroups.membersByTeam[teamID] ?? []
            }
        }
    }
}

struct BotPickRow: View {
    let bot: BotDefinition

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            BotsAvatarView(name: bot.name, handle: bot.handle, symbol: bot.avatarSymbol, size: 22)
            Text(bot.name).font(DS.Font.body).foregroundColor(DS.Palette.text)
            if !bot.title.isEmpty {
                Text(bot.title).font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary).lineLimit(1)
            }
        }
    }
}

extension BotGroupPolicy {
    var displayName: String {
        switch self {
        case .roundtable: return "Roundtable"
        case .lead: return "Lead"
        case .mentionsOnly: return "Mentions only"
        }
    }

    var caption: String {
        switch self {
        case .roundtable: return "Every bot answers each message, in order."
        case .lead: return "Only the lead answers unless you @mention someone."
        case .mentionsOnly: return "Only bots you @mention answer."
        }
    }
}

struct BotGroupEditorSheet: View {
    enum Mode: Equatable {
        case create(teamID: BotTeamID?)
        case edit(BotGroupID)
    }

    @ObservedObject var vm: BotsViewModel
    @ObservedObject var teamsGroups: BotTeamsGroupsController
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var selected: [BotID] = []
    @State private var policy: BotGroupPolicy = .roundtable
    @State private var lead: BotID?
    @State private var hops = BotGroupConversation.defaultMaxAutoHops
    @State private var teamID: BotTeamID?
    @State private var loaded = false
    @State private var saving = false

    private var cap: Int { BotGroupConversation.maxParticipants }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text(isCreate ? "New Group" : "Edit Group")
                .font(DS.Font.title2.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            TextField("Group title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("bots.group.title")
            HStack {
                Text("Participants")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer()
                Text("\(selected.count) of \(cap)")
                    .font(DS.Font.caption)
                    .foregroundColor(selected.count >= cap ? DS.Palette.warning : DS.Palette.textTertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    if let sections = BotRosterSections.make(
                        roster: vm.bots, teams: teamsGroups.teams, membersByTeam: teamsGroups.membersByTeam
                    ) {
                        ForEach(sections.teams, id: \.team.id) { section in
                            pickSection(section.team.name, bots: section.bots, team: section.team.id)
                        }
                        if !sections.otherBots.isEmpty {
                            pickSection("Other Bots", bots: sections.otherBots, team: nil)
                        }
                    } else {
                        pickSection("Bots", bots: vm.bots, team: nil)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 300)
            Picker("Who answers", selection: $policy) {
                ForEach(BotGroupPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("bots.group.policy")
            Text(policy.caption).font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary)
            if policy == .lead {
                Picker("Lead", selection: $lead) {
                    Text("Choose a lead").tag(BotID?.none)
                    ForEach(selectedBots, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("bots.group.lead")
            }
            Stepper(value: $hops, in: 0...BotGroupConversation.maxAutoHopsCap) {
                Text("Bot hand-offs per message: \(hops)")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
            }
            .accessibilityIdentifier("bots.group.hops")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreate ? "Create Group" : "Save") { save() }
                    .buttonStyle(BotsPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityIdentifier("bots.group.save")
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 460)
        .onAppear(perform: load)
        .onChange(of: selected) { ids in
            if let current = lead, !ids.contains(current) { lead = nil }
        }
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private var selectedBots: [BotDefinition] {
        let byID = Dictionary(vm.bots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.compactMap { byID[$0] }
    }

    private var canSave: Bool {
        !saving
            && vm.isControlPlaneActive
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selected.isEmpty
            && selected.count <= cap
            && (policy != .lead || lead.map(selected.contains) == true)
    }

    private func pickSection(_ name: String, bots: [BotDefinition], team: BotTeamID?) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text(name).font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary)
                Spacer()
                if let team, !bots.isEmpty {
                    Button("Add whole team") { addAll(bots, team: team) }
                        .buttonStyle(.link)
                        .font(DS.Font.caption)
                        .disabled(bots.allSatisfy { selected.contains($0.id) })
                        .accessibilityIdentifier("bots.group.addTeam.\(team.value.uuidString.lowercased())")
                }
            }
            ForEach(bots, id: \.id) { bot in
                Toggle(isOn: Binding(
                    get: { selected.contains(bot.id) },
                    set: { on in
                        if on {
                            if !selected.contains(bot.id), selected.count < cap { selected.append(bot.id) }
                        } else {
                            selected.removeAll { $0 == bot.id }
                        }
                    }
                )) {
                    BotPickRow(bot: bot)
                }
                .toggleStyle(.checkbox)
                .disabled(!selected.contains(bot.id) && selected.count >= cap)
                .accessibilityIdentifier("bots.group.participant.\(bot.handle)")
            }
        }
    }

    private func addAll(_ bots: [BotDefinition], team: BotTeamID) {
        for bot in bots where !selected.contains(bot.id) && selected.count < cap {
            selected.append(bot.id)
        }
        if isCreate, teamID == nil { teamID = team }
        if title.isEmpty, let name = teamsGroups.teams.first(where: { $0.id == team })?.name { title = name }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case .create(let seed):
            teamID = seed
            if let seed {
                let members = teamsGroups.membersByTeam[seed] ?? []
                let live = Set(vm.bots.map(\.id))
                selected = Array(members.filter(live.contains).prefix(cap))
                title = teamsGroups.teams.first { $0.id == seed }?.name ?? ""
            } else if let bot = vm.selectedBot {
                selected = [bot.id]
            }
        case .edit(let id):
            guard let group = teamsGroups.groups.first(where: { $0.id == id })
                    ?? ((try? vm.teamsGroupsStoreGroup(id)) ?? nil) else { return }
            title = group.title
            teamID = group.teamID
            policy = group.policy
            lead = group.leadBotID
            hops = group.maxAutoHops
            selected = teamsGroups.participants(of: id).map(\.botID)
        }
    }

    private func save() {
        let draft = BotTeamsGroupsController.GroupDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            teamID: teamID,
            participantBotIDs: selected,
            policy: policy,
            leadBotID: policy == .lead ? lead : nil,
            maxAutoHops: hops
        )
        switch mode {
        case .create:
            saving = true
            Task { @MainActor in
                let created = await teamsGroups.createGroup(draft) { id in vm.openGroup(id) }
                saving = false
                if created { dismiss() }
            }
        case .edit(let id):
            if teamsGroups.saveGroup(id: id, draft: draft) { dismiss() }
        }
    }
}

extension BotsViewModel {
    /// A hidden group (not in the sidebar list) still edits from its room.
    func teamsGroupsStoreGroup(_ id: BotGroupID) throws -> BotGroupConversation? {
        try teamsGroups.storeGroup(id)
    }
}

extension BotTeamsGroupsController {
    func storeGroup(_ id: BotGroupID) throws -> BotGroupConversation? {
        try botStore.group(id: id)
    }
}

// MARK: - Group screen

/// `BotsScreen.group`: the room is the shared Agent App surface (composer,
/// transcript, waiting rows, mentions); the inspector lists participants.
struct BotGroupRoomScreen: View {
    @ObservedObject var vm: BotsViewModel
    @ObservedObject var teamsGroups: BotTeamsGroupsController

    var body: some View {
        if let group = teamsGroups.selectedGroup {
            VStack(spacing: 0) {
                header(group)
                HStack(spacing: 0) {
                    main(group)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if teamsGroups.isInspectorVisible {
                        Rectangle().fill(DS.Palette.line).frame(width: 1).accessibilityHidden(true)
                        BotGroupInspector(vm: vm, teamsGroups: teamsGroups, group: group)
                            .frame(width: BotsChrome.desktopPaneWidth)
                    }
                }
            }
            .accessibilityIdentifier("bots.group")
            .sheet(item: $teamsGroups.roomSheet) { sheet in
                BotTeamsGroupsSheetContent(vm: vm, teamsGroups: teamsGroups, sheet: sheet)
            }
        } else {
            DSEmptyState(
                icon: "person.3",
                title: "Select a group",
                subtitle: "Group conversations show under My Bots."
            )
            .accessibilityIdentifier("bots.group.empty")
        }
    }

    private func header(_ group: BotGroupConversation) -> some View {
        let members = teamsGroups.bots(in: group.id, from: vm.bots)
        return HStack(spacing: DS.Space.md) {
            BotStackedAvatars(bots: members, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                    .accessibilityIdentifier("bots.group.header.title")
                Text("\(members.count) bots · \(group.policy.displayName)")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.lg)
            let retryable = teamsGroups.retryableTurns[group.id] ?? []
            if !retryable.isEmpty {
                Button(retryTitle(retryable)) { teamsGroups.retryFailedTurns(groupID: group.id) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .help("Run the bots whose last answer failed or was interrupted again")
                    .accessibilityIdentifier("bots.group.retry")
            }
            if group.attentionState == .working {
                Button("Stop") { teamsGroups.stop(groupID: group.id) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .help("Stop every bot answering in this group")
                    .accessibilityIdentifier("bots.group.stop")
            }
            DSIconButton(
                "sidebar.right",
                help: teamsGroups.isInspectorVisible ? "Hide inspector" : "Show inspector"
            ) {
                withAnimation(DS.Motion.standard) { teamsGroups.isInspectorVisible.toggle() }
            }
            .accessibilityIdentifier("bots.group.inspectorToggle")
        }
        .padding(.leading, BotsViewModel.deskIdentityLeadingPadding(shellSidebarCollapsed: vm.isShellSidebarCollapsed))
        .padding(.trailing, DS.Space.xl)
        .frame(height: 44)
        .dsBar(edge: .bottom)
    }

    private func retryTitle(_ turns: [BotGroupTurn]) -> String {
        guard turns.count == 1, let bot = vm.bots.first(where: { $0.id == turns[0].botID }) else {
            return "Retry \(turns.count) bots"
        }
        return "Retry \(bot.name)"
    }

    @ViewBuilder
    private func main(_ group: BotGroupConversation) -> some View {
        if let botID = teamsGroups.privateThreadBotID, let privateVM = teamsGroups.privateThreadVM {
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "lock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                    Text("Private thread · \(vm.bots.first { $0.id == botID }?.name ?? "Bot")")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                    Spacer()
                    Button("Back to group") { teamsGroups.closePrivateThread() }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("bots.group.private.back")
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.sm)
                .dsBar(edge: .bottom)
                AgentAppView(
                    vm: privateVM,
                    layout: AgentAppViewLayout(showsThreadRail: false, showsHeader: false, showsPlanSidebar: false)
                )
                .id(privateVM.selectedThreadId)
            }
            .accessibilityIdentifier("bots.group.private")
        } else if let roomVM = teamsGroups.roomVM {
            AgentAppView(
                vm: roomVM,
                layout: AgentAppViewLayout(showsThreadRail: false, showsHeader: false, showsPlanSidebar: false)
            )
            .id(group.roomThreadID)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bots.group.room")
        } else {
            AgentChatLoadingStatusStrip()
                .padding(DS.Space.lg)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

struct BotGroupInspector: View {
    @ObservedObject var vm: BotsViewModel
    @ObservedObject var teamsGroups: BotTeamsGroupsController
    let group: BotGroupConversation

    var body: some View {
        let members = teamsGroups.bots(in: group.id, from: vm.bots)
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                HStack {
                    Text("Participants").font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                    Spacer()
                    Button("Edit…") { teamsGroups.roomSheet = .editGroup(group.id) }
                        .buttonStyle(.link)
                        .disabled(!vm.isControlPlaneActive)
                        .accessibilityIdentifier("bots.group.inspector.edit")
                }
                ForEach(members, id: \.id) { bot in participantRow(bot) }
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline).accessibilityHidden(true)
                Text("Who answers").font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Picker("Who answers", selection: Binding(
                    get: { group.policy },
                    set: { teamsGroups.setPolicy($0, groupID: group.id) }
                )) {
                    ForEach(BotGroupPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(!vm.isControlPlaneActive)
                .accessibilityIdentifier("bots.group.inspector.policy")
                Text(group.policy.caption).font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary)
                if group.policy == .lead {
                    Picker("Lead", selection: Binding(
                        get: { group.leadBotID ?? members.first?.id ?? BotID() },
                        set: { teamsGroups.setLead($0, groupID: group.id) }
                    )) {
                        ForEach(members, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .disabled(!vm.isControlPlaneActive)
                    .accessibilityIdentifier("bots.group.inspector.lead")
                }
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline).accessibilityHidden(true)
                Stepper(value: Binding(
                    get: { group.maxAutoHops },
                    set: { teamsGroups.setMaxAutoHops($0, groupID: group.id) }
                ), in: 0...BotGroupConversation.maxAutoHopsCap) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hop budget: \(group.maxAutoHops)")
                            .font(DS.Font.bodyStrong)
                            .foregroundColor(DS.Palette.text)
                        Text("How many times bots may hand the floor to each other with @mentions per message.")
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!vm.isControlPlaneActive)
                .accessibilityIdentifier("bots.group.inspector.hops")
            }
            .padding(DS.Space.lg)
        }
        .background(DS.Palette.surface)
        .accessibilityIdentifier("bots.group.inspector")
    }

    private func participantRow(_ bot: BotDefinition) -> some View {
        let threadID = teamsGroups.memberThreadID(groupID: group.id, botID: bot.id)
        let memberThread = threadID == nil ? nil : teamsGroups.memberThreads[group.id]?[bot.id]
        let isLead = group.policy == .lead && group.leadBotID == bot.id
        return HStack(spacing: DS.Space.sm) {
            BotsAvatarView(name: bot.name, handle: bot.handle, symbol: bot.avatarSymbol, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.xs) {
                    Text(bot.name).font(DS.Font.body).foregroundColor(DS.Palette.text).lineLimit(1)
                    if isLead { DSPill("Lead", tone: .accent) }
                }
                DSPill(vm.groupRouteLabel(for: bot, memberThread: memberThread))
                    .accessibilityIdentifier("bots.group.inspector.route.\(bot.handle)")
            }
            Spacer(minLength: 0)
            Button("Open private thread") { teamsGroups.openPrivateThread(botID: bot.id) }
                .buttonStyle(.link)
                .font(DS.Font.caption)
                .disabled(threadID == nil)
                .help(threadID == nil ? "\(bot.name) has not answered here yet" : "Show \(bot.name)'s own thread for this group")
                .accessibilityIdentifier("bots.group.inspector.private.\(bot.handle)")
        }
    }
}
