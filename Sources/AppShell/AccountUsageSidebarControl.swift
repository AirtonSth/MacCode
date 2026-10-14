import Foundation
import SwiftUI
import CoreModel
import AgentRuntime
import DesignSystemKit

/// Pure copy for the sidebar's provider account-usage control
/// (Claude + Codex + Grok quota). No UI state.
public enum AccountUsageDisplay {
    public static let providers: [AgentProvider] = [.claude, .codex, .grok]

    static let signedOutPrompt = "Sign in to track Claude, Codex and Grok usage"

    public static func usage(for provider: AgentProvider, in snapshot: ProviderUsageSnapshot) -> ProviderTokenUsage {
        snapshot.providers.first { $0.provider == provider } ?? ProviderTokenUsage(provider: provider)
    }

    /// Ring fill (0...1): the live session percent, else the weekly percent —
    /// the same rule as the iOS rings (AccountUsageWidgetDigest "today").
    /// nil means not loaded; the ring must never draw it as 0%.
    public static func ringProgress(_ usage: ProviderTokenUsage, now: Date = Date()) -> Double? {
        (usage.effectiveSessionUsedPercent(now: now) ?? usage.effectiveWeeklyUsedPercent(now: now))
            .map { min(max($0 / 100.0, 0), 1) }
    }

    /// "Claude session 12%", "Codex week 42%" or "Grok not loaded".
    static func ringCaption(_ usage: ProviderTokenUsage, now: Date = Date()) -> String {
        let title = providerTitle(usage.provider)
        if let session = usage.effectiveSessionUsedPercent(now: now) {
            return "\(title) session \(formatPercent(session / 100.0))"
        }
        if let weekly = usage.effectiveWeeklyUsedPercent(now: now) {
            return "\(title) week \(formatPercent(weekly / 100.0))"
        }
        return "\(title) not loaded"
    }

    /// VoiceOver value for the rings: every listed provider (never Distill).
    public static func ringsAccessibilityValue(
        signedIn: Bool,
        snapshot: ProviderUsageSnapshot,
        now: Date = Date()
    ) -> String {
        guard signedIn else { return signedOutPrompt }
        return providers.map { ringCaption(usage(for: $0, in: snapshot), now: now) }.joined(separator: ", ")
    }

    /// Hover tooltip for the rings: one line per provider, outer ring first.
    public static func ringsHelp(
        signedIn: Bool,
        snapshot: ProviderUsageSnapshot,
        now: Date = Date()
    ) -> String {
        guard signedIn else { return signedOutPrompt }
        let lines = providers.map { ringCaption(usage(for: $0, in: snapshot), now: now) }
        return (["Account usage"] + lines + ["Click for details"]).joined(separator: "\n")
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

    static func formatPercent(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}

/// Sidebar footer control for provider account usage: compact concentric rings
/// left of the Insomnia toggle. Signed out, it opens the account window; signed
/// in, it shows the cached figures at once and asks the host to refresh them
/// while the details popover is open.
struct AccountUsageSidebarControl: View {
    @ObservedObject var vm: SidebarViewModel
    let onOpenAccount: () -> Void
    @State private var showsDetails = false

    var body: some View {
        let signedIn = vm.privateAccountUser != nil
        let snapshot = vm.accountUsageSnapshot
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
            // A coarse tick lets an expired session/week window drop out of the
            // ring even when no new snapshot arrives.
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                AccountUsageRings(progress: AccountUsageDisplay.providers.map { provider in
                    signedIn
                        ? AccountUsageDisplay.ringProgress(
                            AccountUsageDisplay.usage(for: provider, in: snapshot),
                            now: timeline.date
                        )
                        : nil
                })
            }
            .frame(width: 20, height: 20)
            .frame(width: 24, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(AccountUsageDisplay.ringsHelp(signedIn: signedIn, snapshot: snapshot))
        // .top opens over the sidebar list, not over the Insomnia toggle beside the rings.
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            details
        }
        .accessibilityLabel("Account usage")
        .accessibilityValue(AccountUsageDisplay.ringsAccessibilityValue(signedIn: signedIn, snapshot: snapshot))
        .accessibilityHint(signedIn ? "Shows session and weekly limits" : "Opens your account")
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
            Text("Each ring shows the session limit used, or the weekly limit when no session is live. Outer to inner: Claude, Codex, Grok. A faint ring has no data yet.")
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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
        let usage = AccountUsageDisplay.usage(for: provider, in: vm.accountUsageSnapshot)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.xs) {
                Circle()
                    .fill(AccountUsageRings.color(for: provider))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(AccountUsageDisplay.providerTitle(provider))
                    .font(DS.Font.captionStrong)
                    .foregroundColor(DS.Palette.text)
            }
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

/// Concentric provider quota rings, restored from the removed Token Saver rings
/// without the Token Saver slot. Fixed order outer → inner (Claude, Codex, Grok)
/// so a color never changes position; same colors as the iOS rings.
struct AccountUsageRings: View {
    /// Fill per ring in `AccountUsageDisplay.providers` order; nil = not loaded.
    let progress: [Double?]

    /// Geometry slots outer → inner at a 34pt reference side. Line widths taper
    /// inward so the outer ring stays dominant.
    private static let ringSlots: [(inset: CGFloat, lineWidth: CGFloat)] = [
        (2.0, 4.0),
        (7.4, 3.0),
        (12.2, 2.2)
    ]

    static func color(for provider: AgentProvider) -> Color {
        switch provider {
        case .claude: return Color(nsColor: .systemOrange)
        case .codex: return Color(nsColor: .systemBlue)
        case .grok: return Color(nsColor: .systemPurple)
        case .distill: return Color(hex: 0x6E56CF)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let side = max(min(proxy.size.width, proxy.size.height), 1)
            let scale = max(side / 34.0, 0.1)
            ZStack {
                ForEach(Array(AccountUsageDisplay.providers.enumerated()), id: \.element) { index, provider in
                    let slot = Self.ringSlots[min(index, Self.ringSlots.count - 1)]
                    let value = index < progress.count ? progress[index] : nil
                    AccountUsageRing(
                        progress: value ?? 0,
                        color: Self.color(for: provider),
                        inset: slot.inset * scale,
                        lineWidth: slot.lineWidth * scale,
                        dimmed: value == nil
                    )
                }
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        // The owning Button carries the label and per-provider value.
        .accessibilityHidden(true)
    }
}

private struct AccountUsageRing: View {
    let progress: Double
    let color: Color
    let inset: CGFloat
    let lineWidth: CGFloat
    var dimmed: Bool = false

    var body: some View {
        ZStack {
            AccountUsageRingShape(progress: 1)
                .stroke(
                    color.opacity(dimmed ? 0.08 : 0.18),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            // Not loaded: faint track only — never paint a made-up fill.
            if !dimmed {
                AccountUsageRingShape(progress: progress)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
            }
        }
        .padding(inset)
    }
}

private struct AccountUsageRingShape: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bounded = min(max(progress, 0), 1)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(-88),
            endAngle: .degrees((360 * bounded) - 88),
            clockwise: false
        )
        return path
    }
}
