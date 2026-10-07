import Foundation

/// What `RemoteCodeDistillService` does with an argv that none of its live
/// modes (Chrome host, subagent telemetry, Agent App middleware, MCP servers,
/// provider proxy) claimed.
///
/// Token Saver was removed on 2026-10-06. Machines upgraded from older builds
/// can still hold symlinks to this binary: PATH command wrappers such as `rg`,
/// a `distill` CLI link, or Grok hook files that run `distill hook …`. None of
/// them may break the user's shell or a provider turn, so a leftover basename
/// runs the real command and a stale hook exits quietly.
public enum RemoteCodeServiceFallbackArgv {
    public static let serviceProgramName = "RemoteCodeDistillService"
    public static let legacyDistillProgramName = "distill"

    public enum Route: Equatable, Sendable {
        /// A stale `distill hook …` from an old Grok hook file: exit 0 with no
        /// output so the provider keeps the original tool input and output.
        case legacyHookNoOp
        /// Run the next executable with this basename on `PATH` that is not
        /// this binary, or exit 127 when there is none.
        case passthrough(command: String, arguments: [String])
        /// The service binary itself was called with arguments no mode accepts.
        case usage
    }

    public static func route(programName: String, arguments: [String]) -> Route {
        let name = (programName as NSString).lastPathComponent
        if name == legacyDistillProgramName {
            return legacyDistill(arguments)
        }
        if name == serviceProgramName {
            if arguments.first == "cli" {
                return legacyDistill(Array(arguments.dropFirst()))
            }
            return .usage
        }
        return .passthrough(command: name, arguments: arguments)
    }

    private static func legacyDistill(_ arguments: [String]) -> Route {
        if arguments.first == "hook" {
            return .legacyHookNoOp
        }
        return .passthrough(command: legacyDistillProgramName, arguments: arguments)
    }
}
