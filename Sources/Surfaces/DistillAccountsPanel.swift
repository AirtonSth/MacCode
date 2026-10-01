import SwiftUI
import AgentRuntime
import DesignSystemKit

public enum DistillAccountsInstallState: Equatable {
    case unknown, installed, installing, failed(String)
}

public struct DistillAccountsPanelPresentation: Equatable {
    public let installState: DistillAccountsInstallState
    public let statuses: [DistillAccountStatus]
    public let busyProvider: DistillAccountProvider?
    public let signInURL: URL?
    public let lastError: String?

    public init(statuses: [DistillAccountStatus], busyProvider: DistillAccountProvider?, signInURL: URL?, lastError: String?, installState: DistillAccountsInstallState = .unknown) {
        self.installState = installState
        self.statuses = statuses
        self.busyProvider = busyProvider
        self.signInURL = signInURL
        self.lastError = lastError
    }
}

public struct DistillAccountsPanel: View {
    public let presentation: DistillAccountsPanelPresentation
    public let login: (DistillAccountProvider) -> Void
    public let logout: (DistillAccountProvider) -> Void
    public let cancel: () -> Void
    public let openAgain: (URL) -> Void
    public let dismissError: () -> Void
    public let retryInstall: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        presentation: DistillAccountsPanelPresentation,
        login: @escaping (DistillAccountProvider) -> Void,
        logout: @escaping (DistillAccountProvider) -> Void,
        cancel: @escaping () -> Void,
        openAgain: @escaping (URL) -> Void,
        dismissError: @escaping () -> Void,
        retryInstall: @escaping () -> Void = {}
    ) {
        self.presentation = presentation
        self.login = login
        self.logout = logout
        self.cancel = cancel
        self.openAgain = openAgain
        self.dismissError = dismissError
        self.retryInstall = retryInstall
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accounts").font(.system(size: 15, weight: .semibold))
                    Text("Models from connected accounts appear in Main and Worker.")
                        .font(.system(size: 12)).foregroundStyle(DS.Palette.textTertiary)
                }
                .padding(.horizontal, DS.Space.md)
                .padding(.top, DS.Space.md)
                .padding(.bottom, DS.Space.sm)
                installNotice
                ForEach(Array(DistillAccountProvider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline) }
                    row(provider)
                }
            }
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
            .accessibilityIdentifier("agent.accounts.card")
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: presentation.busyProvider)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: presentation.statuses)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: presentation.installState)
            if let error = presentation.lastError { errorRow(error) }
        }
    }

    private var isInstallFailed: Bool {
        if case .failed = presentation.installState { return true }
        return false
    }

    @ViewBuilder private var installNotice: some View {
        switch presentation.installState {
        case .installing:
            HStack(spacing: DS.Space.sm) {
                ProgressView().controlSize(.small)
                    .accessibilityIdentifier("agent.accounts.install.progress")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installing Distill…").font(.system(size: 12, weight: .medium))
                    Text("RemoteCode installs the latest Distill automatically.")
                        .font(.system(size: 11)).foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .padding(.horizontal, DS.Space.md).padding(.bottom, DS.Space.sm)
        case .failed(let message):
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Text(message).font(.system(size: 11)).foregroundStyle(DS.Palette.warning)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("agent.accounts.install.failed")
                Button("Retry", action: retryInstall).buttonStyle(.plain)
                    .accessibilityIdentifier("agent.accounts.install.retry")
            }
            .padding(.horizontal, DS.Space.md).padding(.bottom, DS.Space.sm)
        case .unknown, .installed:
            EmptyView()
        }
    }

    @ViewBuilder private func row(_ provider: DistillAccountProvider) -> some View {
        let status = presentation.statuses.first { $0.provider == provider }
        let busy = presentation.busyProvider == provider
        HStack(spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Palette.text)
                if busy {
                    Label("Waiting for the browser…", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11)).foregroundStyle(DS.Palette.textSecondary)
                } else if status?.connected == true {
                    Label(status?.email.map { "Connected · \($0)" } ?? "Connected", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(DS.Palette.success)
                } else {
                    Label("Not connected", systemImage: "circle")
                        .font(.system(size: 11)).foregroundStyle(DS.Palette.textTertiary)
                }
            }
            Spacer(minLength: 4)
            if busy {
                ProgressView().controlSize(.small).accessibilityLabel("Signing in")
                if let url = presentation.signInURL {
                    Button("Open again") { openAgain(url) }.buttonStyle(.plain)
                        .accessibilityIdentifier("agent.accounts.\(provider.rawValue).login")
                }
                Button("Cancel", action: cancel).buttonStyle(.plain)
                    .accessibilityIdentifier("agent.accounts.\(provider.rawValue).cancel")
            } else if status?.connected == true {
                Button("Log out") { logout(provider) }.buttonStyle(.plain).disabled(presentation.busyProvider != nil)
                    .accessibilityIdentifier("agent.accounts.\(provider.rawValue).logout")
            } else {
                Button("Log in") { login(provider) }.buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(presentation.busyProvider != nil || presentation.installState == .installing || isInstallFailed)
                    .accessibilityIdentifier("agent.accounts.\(provider.rawValue).login")
            }
        }
        .padding(.horizontal, DS.Space.md)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.warning)
            Text(error).font(.system(size: 11)).foregroundStyle(DS.Palette.text).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismissError) { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss account error")
        }
        .padding(DS.Space.sm)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control))
    }
}
