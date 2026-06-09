import Foundation

/// Pure, synchronous helper that translates a selection of file paths into
/// the argument list passed to `git add`. Extracted from `DiffPanelViewModel`
/// so it can be tested without any UI or actor machinery.
///
/// Contract:
///   - Empty `selected` or `all` → returns nil (caller must treat as no-op / disabled).
///   - Non-empty intersection of selected ∩ all → returns those paths, shell-safe
///     (paths with spaces are not split; they are passed as individual elements in
///     the [String] array, so Process avoids any shell-quoting issues).
///   - Paths not present in `all` are silently dropped (stale selection guard).
public enum StagingHelper {

    /// Returns the validated path arguments for `git add`, or `nil` when the
    /// effective selection is empty (commit button should be disabled).
    ///
    /// - Parameters:
    ///   - selected: the paths the user has checked / highlighted.
    ///   - all: the full list of paths that actually have changes (from `GitSummary`).
    public static func pathArgs(selected: Set<String>, all: [String]) -> [String]? {
        let allSet = Set(all)
        let valid = selected.filter { allSet.contains($0) }.sorted()
        return valid.isEmpty ? nil : valid
    }
}
