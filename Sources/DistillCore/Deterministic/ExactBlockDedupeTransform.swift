import Foundation

/// Exact-only, deterministic command-output candidate for the shared runtime wrapper.
///
/// The HTTP service remains the authority for store-before-loss: scoped requests get
/// byte-exact recovery before this candidate is delivered, while unscoped requests
/// fail open because this model-readable pointer is not machine-expandable.
public enum ExactBlockDedupeTransform {
    public static func commandOutput(for request: DistillRequest) -> String? {
        guard request.mode == .commandOutput else { return nil }

        let result = DistillBlockDeduper.dedupeExact(request.input)
        guard result.dedupedBlocks > 0,
              result.nearDedupedBlocks == 0,
              result.output.utf8.count < request.input.utf8.count,
              result.output.count <= request.maxOutputCharacters else {
            return nil
        }
        return result.output
    }
}
