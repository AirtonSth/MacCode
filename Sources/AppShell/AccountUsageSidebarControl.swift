import Foundation
import SwiftUI
import CoreModel
import AgentRuntime
import DesignSystemKit

/// Pure copy for the sidebar's provider account-usage control
/// (Claude + Codex + Grok quota and token totals). No UI state.
public enum AccountUsageDisplay {
    public static let providers: [AgentProvider] = [.claude, .codex, .grok]

    public static func subtitle(signedIn: Bool, usedTokens: Int) -> String {
        guard signedIn else { return "Sign in to track Claude + Codex + Grok usage" }
        return usedTokens > 0
            ? "Used \(formatTokenCount(usedTokens)) in Claude + Codex + Grok"
            : "No provider usage recorded yet"
    }

    /// Session caption. When the provider reported no live session window,
    /// the weekly figure is shown under an explained label instead of a bare
    /// "Session used 0%".
    public static func sessionCaption(
        effectiveSessionUsedPercent: Double?,
        effectiveWeeklyUsedPercent: Double?,
        currentSessionTokens: Int = 0,
        currentSessionLimitTokens: Int = 0
    ) -> String {
        if let sessionPercent = effectiveSessionUsedPercent {
            return "Session used \(formatPercent(sessionPercent / 100.0))"
        }
        if let weeklyPercent = effectiveWeeklyUsedPercent {
            return "Week used \(formatPercent(weeklyPercent / 100.0)) (no session data)"
        }
        guard currentSessionLimitTokens > 0 else { return "Session usage not loaded" }
        let progress = currentSessionTokens > 0
            ? min(max(Double(currentSessionTokens) / Double(currentSessionLimitTokens), 0), 1)
            : 0
        return "Session used \(formatPercent(progress))"
    }

    public static func weeklyCaption(effectiveWeeklyUsedPercent: Double?) -> String {
        guard let weeklyPercent = effectiveWeeklyUsedPercent else { return "Weekly usage not loaded" }
        return "Weekly used \(formatPercent(weeklyPercent / 100.0))"
    }

    public static func providerTitle(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .distill: return "Distill"
        }
    }

    public static func formatTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            let whole = Double(value) / 1_000_000.0
            return String(format: whole >= 10 ? "%.0fM" : "%.1fM", whole)
        }
        if value >= 1_000 {
            let whole = Double(value) / 1_000.0
            return String(format: whole >= 10 ? "%.0fK" : "%.1fK", whole)
        }
        return "\(value)"
    }

    static func formatPercent(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}

/// Sidebar footer control for provider account usage. Signed out, it opens the
/// account window; signed in, it shows the cached figures at once and asks the
/// host to refresh them while the details popover is open.
struct AccountUsageSidebarControl: View {
    @ObservedObject var vm: SidebarViewModel
    let onOpenAccount: () -> Void
    @State private var showsDetails = false

    var body: some View {
        let signedIn = vm.privateAccountUser != nil
        let subtitle = AccountUsageDisplay.subtitle(
            signedIn: signedIn,
            usedTokens: vm.accountUsageSnapshot.usedTokens
        )
        Button {
            guard signedIn else {
                onOpenAccount()
                return
            }
            if !showsDetails {
                vm.refreshAccountUsageForDetails()
            }
            showsDetails.toggle()
        } label: {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Account usage")
                        .font(DS.Font.bodyStrong)
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(signedIn ? "Show Claude, Codex and Grok account usage" : "Sign in to track account usage")
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            details
        }
        .accessibilityLabel("Account usage")
        .accessibilityValue(subtitle)
        .accessibilityIdentifier("sidebar.accountUsage")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.xs) {
                Text("Account usage")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: 0)
                if vm.accountUsageIsRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                        .frame(width: 12, height: 12)
                        .accessibilityLabel("Refreshing usage data")
                        .accessibilityIdentifier("sidebar.accountUsage.refreshSpinner")
                }
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(SidebarRootView.accountUsageLastUpdatedLabel(
                        vm.accountUsageLastUpdated,
                        now: timeline.date
                    ))
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
                }
                .accessibilityIdentifier("sidebar.accountUsage.lastUpdated")
            }
            ForEach(AccountUsageDisplay.providers, id: \.self) { provider in
                providerRow(provider)
            }
        }
        .padding(DS.Space.md)
        .frame(width: 300, alignment: .leading)
        .background(DS.Palette.surface)
        .accessibilityIdentifier("sidebar.accountUsage.details")
    }

    private func providerRow(_ provider: AgentProvider) -> some View {
        let usage = vm.accountUsageSnapshot.providers.first { $0.provider == provider }
            ?? ProviderTokenUsage(provider: provider)
        return VStack(alignment: .leading, spacing: 2) {
            Text(AccountUsageDisplay.providerTitle(provider))
                .font(DS.Font.captionStrong)
                .foregroundColor(DS.Palette.text)
            Text(AccountUsageDisplay.sessionCaption(
                effectiveSessionUsedPercent: usage.effectiveSessionUsedPercent(),
                effectiveWeeklyUsedPercent: usage.effectiveWeeklyUsedPercent(),
                currentSessionTokens: usage.currentSessionTokens,
                currentSessionLimitTokens: usage.currentSessionLimitTokens
            ))
            .font(DS.Font.caption)
            .foregroundColor(DS.Palette.textSecondary)
            .monospacedDigit()
            Text(AccountUsageDisplay.weeklyCaption(
                effectiveWeeklyUsedPercent: usage.effectiveWeeklyUsedPercent()
            ))
            .font(DS.Font.caption)
            .foregroundColor(DS.Palette.textSecondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.accountUsage.provider.\(provider.rawValue)")
    }
}
