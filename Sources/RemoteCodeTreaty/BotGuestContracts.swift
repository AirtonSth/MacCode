import Foundation

// Live guest viewer (host capability `bot.guest_observe_v1`).
//
// - Read: `bot.guest.state` `{host_id, bot_id, observe: true, known_frame_id?}`
//   (read scope, batchable). Without `observe` the call is unchanged (cached
//   state, no Docker work). With it the host captures a fresh frame of the
//   bot's guest screen, at most one capture start per bot every
//   `min_interval_ms` (500 ms, so 1-2 fps). A call during a capture waits for
//   it (`coalesced`); a faster call gets the cached frame (`rate_limited`).
//   Nothing runs between calls: poll while the viewer is visible and stop when
//   it is not.
//   - Observe never mints a runtime grant and never clears an error. When the
//     state is `stopped`, `failed` or `reconnect_required` but the bot's
//     container runs (the bot's own run started it, or the Mac relaunched),
//     the outcome is `adoptable` and the state is unchanged: to watch and
//     drive it, call `bot.guest.start` with the `start` task of `task_catalog`
//     (a receipted write that reuses the running container).
//   - When the watched container is gone (stopped or removed) the grant ends:
//     the state becomes `stopped` (outcome `stopped`) and every client gets
//     `bot.guest.updated` `{bot_id, host_id, method: "bot.guest.state",
//     reason: "observe_stopped", status: "stopped", grant_invalidated: true,
//     controlled_by_user}`.
//   - Every frame gets a new `frame_id` and a higher `sequence`. A capture
//     that started on an older grant or frame is dropped (`stale_dropped`).
//   - `known_frame_id`: when it equals the current `frame.frame_id`, the
//     result's `frame` has no `png_base64` and `observe.frame_unchanged` is
//     true; keep the image already decoded for that frame id.
//   - `bot.guest.input` also accepts `before_frame_id` of one of the last 4
//     frames an observe replaced on the same grant, when it has the current
//     frame's pixel size, until an input settles a new frame.
//   The result is the usual guest state plus `controlled_by_user` (also
//   present without `observe`) and `observe` (`BotGuestObserveBlock`).
// - Write: `bot.guest.control` `{bot_id, action: "take" | "release"}`
//   (receipt ledger, needs `client_request_id`; the host binds `host_id`).
//   `take`: the user drives the bot's computer; the bot's act/exec steps are
//   refused until release, and the bot's open manual action on a thread that
//   does not run on the Mac becomes `taken` (as the Mac card's Take; its
//   `agent.manual_action.updated` is published before the call returns, so it
//   is in the receipt). `release` hands control back without answering the
//   request: a `taken` one becomes `open` again (with its
//   `agent.manual_action.updated`); answer it with
//   `agent.manual_action.resolve` continue/decline. (The Mac card's Devolver
//   with an open request continues it instead.) Control is in memory: a host
//   relaunch hands it back to the bot. Receipt status `completed`; readback =
//   guest state without `frame` + `controlled_by_user` + `control_action`.
//   Refusals are JSON-RPC errors, not receipts: `-32602` for an unknown
//   action, `-32092` when the guest is bound to another host. Event:
//   `bot.guest.updated` with `method: "bot.guest.control"` and `request_id`.
// - Events without `request_id` (never a receipt; older clients ignore them):
//   - `reason: "agent_step"` (`BotGuestAgentStepEvent`) after each bot act,
//     exec or guest browser act, sent only while some client observed that
//     bot in the last 5 s. No frame: observe again to see the new screen.
//   - `reason: "control"` `{bot_id, host_id?, controlled_by_user}` whenever
//     who drives the bot's computer changed, on the Mac or from any device
//     (a `bot.guest.control` call also gets its receipt event).
//   - `reason: "observe_stopped"` (above).
//   Do not keep only the latest `bot.guest.updated` per bot: these must not
//   replace a receipt event. Key receipt events by `request_id` and the
//   others by `reason`.

/// The `observe` block of a `bot.guest.state` result called with `observe: true`.
public struct BotGuestObserveBlock: Codable, Equatable, Sendable {
    /// `captured`, `coalesced`, `adoptable`, `rate_limited`, `not_running`,
    /// `stale_dropped`, `stopped` or `capture_failed`.
    public let outcome: String
    public let minIntervalMS: Int
    /// The capture error, for `capture_failed` (and a coalesced call that joined one).
    public let error: String?
    /// True when `known_frame_id` matched: `frame.png_base64` was left out.
    public let frameUnchanged: Bool?

    public init(outcome: String, minIntervalMS: Int, error: String? = nil, frameUnchanged: Bool? = nil) {
        self.outcome = outcome
        self.minIntervalMS = minIntervalMS
        self.error = error
        self.frameUnchanged = frameUnchanged
    }

    private enum CodingKeys: String, CodingKey {
        case outcome, error
        case minIntervalMS = "min_interval_ms"
        case frameUnchanged = "frame_unchanged"
    }
}

public enum BotGuestControl: RemoteCodeRPCContract {
    public static let method = "bot.guest.control"

    public struct Params: Codable, Equatable, Sendable {
        public let botID: String
        /// `take` or `release`.
        public let action: String
        public let clientRequestID: String

        public init(botID: String, action: String, clientRequestID: String) {
            self.botID = botID
            self.action = action
            self.clientRequestID = clientRequestID
        }

        private enum CodingKeys: String, CodingKey {
            case action
            case botID = "bot_id"
            case clientRequestID = "client_request_id"
        }
    }

    public struct Readback: Codable, Equatable, Sendable {
        public let hostID: String
        public let botID: String
        /// The guest status (`running`, `stopped`, ...); control does not change it.
        public let status: String
        public let controlledByUser: Bool
        /// `take` or `release`.
        public let controlAction: String

        private enum CodingKeys: String, CodingKey {
            case status
            case hostID = "host_id"
            case botID = "bot_id"
            case controlledByUser = "controlled_by_user"
            case controlAction = "control_action"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let requestID: String
        public let receiptID: String
        /// Always `completed`: a refused call is a JSON-RPC error (`-32602`
        /// unknown action, `-32092` guest bound to another host), not a receipt.
        public let status: String
        public let botID: String
        public let readback: Readback

        private enum CodingKeys: String, CodingKey {
            case status, readback
            case requestID = "request_id"
            case receiptID = "receipt_id"
            case botID = "bot_id"
        }
    }
}

/// `bot.guest.updated` with `reason: "agent_step"`. Not a receipt event: never
/// let it replace one (see the header).
public struct BotGuestAgentStepEvent: Codable, Equatable, Sendable {
    public static let reason = "agent_step"

    public let botID: String
    /// The paired host binding; absent when no client has read this bot's guest state.
    public let hostID: String?
    public let reason: String
    /// `act`, `exec` or `browser_act`.
    public let step: String
    /// Always true: the cached frame is older than this step.
    public let frameStale: Bool
    public let controlledByUser: Bool

    private enum CodingKeys: String, CodingKey {
        case reason, step
        case botID = "bot_id"
        case hostID = "host_id"
        case frameStale = "frame_stale"
        case controlledByUser = "controlled_by_user"
    }
}
