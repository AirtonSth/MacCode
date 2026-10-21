import SwiftUI

/// Entry point for the Auto model guide. The guide edits the Distill Auto
/// profile, which lives behind `DistillAccountsController` in AppShell, so
/// AppShell installs the factory at launch and Surfaces only presents it.
public enum AgentAutoGuide {
    /// Builds the guide sheet body. `onClose` dismisses the hosting sheet.
    public static let title = "Auto profile"
    public static let subtitle = "How Auto picks a model for each turn. Changes apply to every Auto conversation."

    @MainActor public static var makeGuide: ((_ onClose: @escaping () -> Void) -> AnyView)?
}
