import Foundation

public enum LibrarianForbidden {
    public static func handle(_ request: LibrarianRequest, function: LibrarianFunction) -> LibrarianHandlerOutput {
        LibrarianHandlerOutput(
            status: .refused,
            text: "",
            envelope: .refused(
                op: function.id,
                reason: "forbidden:\(function.id)",
                handle: request.handle
            ),
            stage: .verbatim,
            originalForSavings: request.input
        )
    }

    public static func exactOutputRefuse(_ request: LibrarianRequest) -> LibrarianHandlerOutput {
        LibrarianHandlerOutput(
            status: .refused,
            text: request.input,
            envelope: .refused(op: "distill_exact_rg", reason: "exact_output_not_distilled"),
            stage: .verbatim,
            originalForSavings: request.input
        )
    }
}
