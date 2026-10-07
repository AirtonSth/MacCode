import Foundation
import Persistence
import SocketServer

/// C8: lets a client resume across a host restart with durable replay.
///
/// A clean quit records, after the last event-log flush, the last seq this
/// boot published and the newest lost live-only event per stream (the ring
/// dies with the process). The next boot consumes the record once: its
/// sequence continues above that high water, so no seq a client saw is
/// reused, and a cursor from the previous boot epoch can be replayed from the
/// event log. Without a record (crash, forced quit) previous-boot cursors
/// still get a baseline, as before. Any non-diagnostic event published after
/// the record clears it; diagnostics published after it (WebSocket close
/// records from the server shutdown) are in the event log and replay like
/// any other durable event.
enum DurableReplayResumeRecord {
    static let settingsKey = "event_bus.durable_resume.v1"

    private struct Stored: Codable, Equatable {
        let bootEpoch: UInt64
        let highWater: Int64
        let minimumCursor: Int64
        let threads: [String: Int64]
        let surfaces: [String: Int64]
    }

    /// Call after the final `flushEventPersistence()` of a clean quit.
    /// Returns false (and records nothing) while durable writes are pending.
    @discardableResult
    static func write(
        eventBus: EventBus,
        settings: SettingsRepository,
        bootEpoch: UInt64
    ) -> Bool {
        guard let state = eventBus.durableResumeState() else {
            try? settings.set(settingsKey, "")
            return false
        }
        var threads: [String: Int64] = [:]
        var surfaces: [String: Int64] = [:]
        for (stream, seq) in state.lostStreams {
            switch stream {
            case .thread(let id): threads[id] = seq
            case .surface(let id): surfaces[id] = seq
            }
        }
        let stored = Stored(
            bootEpoch: bootEpoch,
            highWater: state.highWater,
            minimumCursor: state.minimumCursor,
            threads: threads,
            surfaces: surfaces
        )
        guard let data = try? JSONEncoder().encode(stored),
              let json = String(data: data, encoding: .utf8),
              (try? settings.set(settingsKey, json)) != nil else { return false }
        eventBus.sealDurableResume {
            try? settings.set(settingsKey, "")
        }
        return true
    }

    /// Call at launch after the bus is seeded from the event log (this boot
    /// then continues above both the log and the record). Consumes the record
    /// whatever its outcome.
    @discardableResult
    static func restore(
        eventBus: EventBus,
        settings: SettingsRepository,
        bootEpoch: UInt64
    ) -> Bool {
        guard let json = try? settings.get(settingsKey), !json.isEmpty else { return false }
        try? settings.set(settingsKey, "")
        guard let data = json.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.bootEpoch &+ 1 == bootEpoch else {
            return false
        }
        var streams: [EventBus.StreamGap.Stream: Int64] = [:]
        for (id, seq) in stored.threads { streams[.thread(id)] = seq }
        for (id, seq) in stored.surfaces { streams[.surface(id)] = seq }
        eventBus.installPreviousBootReplay(EventBus.PreviousBootReplay(
            bootEpoch: stored.bootEpoch,
            highWater: stored.highWater,
            lostStreams: streams,
            minimumCursor: stored.minimumCursor
        ))
        return true
    }
}
