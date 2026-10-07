import CoreModel
import Foundation
import Persistence

/// `bot.guest.state` with `observe: true` (host capability `bot.guest_observe_v1`):
/// a paired viewer asks for a fresh frame of the bot's guest screen.
///
/// Nothing runs unless a viewer asks: there is no timer. Per bot, a capture
/// starts at most every `minimumInterval` (1-2 fps); a call that arrives while
/// one is in flight waits for it (`coalesced`), and a faster caller gets the
/// cached frame (`rate_limited`). A capture lands only on the runtime grant
/// and frame it started from, so a stop, rebuild or newer frame wins.
@MainActor
public final class BotGuestObserveCoordinator {
    public enum Outcome: String, Sendable {
        case captured
        case coalesced
        case rateLimited = "rate_limited"
        case notRunning = "not_running"
        case staleDropped = "stale_dropped"
        case stopped
        case captureFailed = "capture_failed"
    }

    public struct Observation: Equatable, Sendable {
        public let outcome: Outcome
        public let error: String?
    }

    public static let minimumInterval: TimeInterval = 0.5
    /// A viewer that observed within this window is watching: the host then
    /// publishes `bot.guest.updated` after the bot's act and exec steps.
    public static let watchWindow: TimeInterval = 5

    public typealias Capture = @MainActor (BotID) async throws -> BotRemoteControlAuthority.ObservedGuestFrame
    public typealias ContainerProbe = @MainActor (BotID) async -> Bool

    private let authority: BotRemoteControlAuthority
    private let capture: Capture
    private let isContainerRunning: ContainerProbe
    private let now: () -> Date
    private var lastCaptureStart: [BotID: Date] = [:]
    private var lastObserved: [BotID: Date] = [:]
    private var inFlight: [BotID: (token: UUID, task: Task<Observation, Never>)] = [:]

    public init(
        authority: BotRemoteControlAuthority,
        capture: @escaping Capture,
        isContainerRunning: @escaping ContainerProbe,
        now: @escaping () -> Date = Date.init
    ) {
        self.authority = authority
        self.capture = capture
        self.isContainerRunning = isContainerRunning
        self.now = now
    }

    /// The guest state after at most one capture, plus an `observe` block:
    /// `{outcome, min_interval_ms, error?}`.
    public func state(params: [String: Any]) async throws -> [String: Any] {
        // Bot and host binding are checked before any Docker work.
        let current = try authority.dispatch(method: "bot.guest.state", params: params)
        guard let raw = current["bot_id"] as? String,
              let uuid = UUID(uuidString: raw),
              let hostID = current["host_id"] as? String else { return current }
        let observation = await refresh(botID: BotID(uuid), hostID: hostID)
        var state = try authority.dispatch(method: "bot.guest.state", params: params)
        var observe: [String: Any] = [
            "outcome": observation.outcome.rawValue,
            "min_interval_ms": Int(Self.minimumInterval * 1_000),
        ]
        if let error = observation.error { observe["error"] = error }
        state["observe"] = observe
        return state
    }

    public func isWatching(_ botID: BotID) -> Bool {
        guard let last = lastObserved[botID] else { return false }
        return now().timeIntervalSince(last) < Self.watchWindow
    }

    private func refresh(botID: BotID, hostID: String) async -> Observation {
        let started = now()
        lastObserved[botID] = started
        if let running = inFlight[botID] {
            let joined = await running.task.value
            return Observation(outcome: .coalesced, error: joined.error)
        }
        if let last = lastCaptureStart[botID], started.timeIntervalSince(last) < Self.minimumInterval {
            return Observation(outcome: .rateLimited, error: nil)
        }
        lastCaptureStart[botID] = started
        let token = UUID()
        let task = Task { @MainActor [weak self] () -> Observation in
            guard let self else { return Observation(outcome: .notRunning, error: nil) }
            let observation = await self.captureFrame(botID: botID, hostID: hostID)
            // Only the capture that owns the handle clears it.
            if self.inFlight[botID]?.token == token { self.inFlight[botID] = nil }
            return observation
        }
        inFlight[botID] = (token, task)
        return await task.value
    }

    private func captureFrame(botID: BotID, hostID: String) async -> Observation {
        var target = authority.guestObserveTarget(botID: botID, hostID: hostID)
        if target == .adoptable {
            // The bot's own run (or a run from before a relaunch) may be using
            // the guest: show that screen instead of a stale "stopped".
            guard await isContainerRunning(botID),
                  let grantID = authority.adoptRunningGuest(botID: botID, hostID: hostID) else {
                return Observation(outcome: .notRunning, error: nil)
            }
            target = .running(grantID: grantID, frameID: nil)
        }
        guard case .running(let grantID, let frameID) = target else {
            return Observation(outcome: .notRunning, error: nil)
        }
        do {
            let frame = try await capture(botID)
            let applied = authority.applyObservedGuestFrame(
                botID: botID,
                grantID: grantID,
                expectedFrameID: frameID,
                frame: frame
            )
            return Observation(outcome: applied ? .captured : .staleDropped, error: nil)
        } catch BotComputerGuestError.notReady {
            authority.markObservedGuestStopped(botID: botID, grantID: grantID)
            return Observation(outcome: .stopped, error: nil)
        } catch {
            return Observation(outcome: .captureFailed, error: String(describing: error))
        }
    }
}
