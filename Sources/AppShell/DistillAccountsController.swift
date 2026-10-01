import AppKit
import Combine
import Foundation
import AgentRuntime
import SocketServer

protocol DistillAccountManaging: Sendable {
    func statuses() -> [DistillAccountStatus]
    func login(_ provider: DistillAccountProvider, onURL: @escaping @Sendable (URL) -> Void) async throws
    func logout(_ provider: DistillAccountProvider) async throws
}

extension DistillAccounts: DistillAccountManaging {}

@MainActor
public final class DistillAccountsController: ObservableObject {
    @Published public private(set) var statuses: [DistillAccountStatus]
    @Published public private(set) var busyProvider: DistillAccountProvider?
    @Published public private(set) var lastError: String?
    @Published public private(set) var signInURL: URL?

    private let accounts: any DistillAccountManaging
    private let didChange: (DistillAccountProvider?, Bool) async -> Void
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(accounts: any DistillAccountManaging, didChange: @escaping (DistillAccountProvider?, Bool) async -> Void = { _, _ in }) {
        self.accounts = accounts
        self.didChange = didChange
        self.statuses = accounts.statuses()
    }

    public func refresh() { statuses = accounts.statuses() }
    public func dismissError() { lastError = nil }

    public func login(_ provider: DistillAccountProvider) {
        guard operation == nil else { return }
        begin(provider)
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await accounts.login(provider) { [weak self] url in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.signInURL = url
                        NSWorkspace.shared.open(url)
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                statuses = accounts.statuses()
                await didChange(provider, true)
                publishBusyChange(provider: provider, busy: true)
                finish(token: token)
            } catch {
                guard generation == token else { return }
                if !(error is CancellationError), (error as? DistillAccountError) != .cancelled {
                    lastError = error.localizedDescription
                }
                finish(token: token)
            }
        }
    }

    public func logout(_ provider: DistillAccountProvider) {
        guard operation == nil else { return }
        begin(provider)
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await accounts.logout(provider)
                guard generation == token else { return }
                statuses = accounts.statuses()
                await didChange(provider, true)
            } catch {
                guard generation == token else { return }
                lastError = error.localizedDescription
            }
            finish(token: token)
        }
    }

    public func cancel() {
        guard operation != nil else { return }
        let provider = busyProvider
        generation &+= 1
        operation?.cancel()
        operation = nil
        busyProvider = nil
        signInURL = nil
        publishBusyChange(provider: provider, busy: false)
    }

    private func begin(_ provider: DistillAccountProvider) {
        generation &+= 1
        busyProvider = provider
        lastError = nil
        signInURL = nil
        publishBusyChange(provider: provider, busy: true)
    }

    private func finish(token: UInt64) {
        guard generation == token else { return }
        let provider = busyProvider
        operation = nil
        busyProvider = nil
        signInURL = nil
        publishBusyChange(provider: provider, busy: false)
    }

    private func publishBusyChange(provider: DistillAccountProvider?, busy: Bool) {
        EventBus.shared.publish(kind: .agentProviderUpdated, payload: .object([
            "provider": .string(provider?.rawValue ?? "distill"),
            "distill_accounts_busy": .bool(busy)
        ]))
    }
}
