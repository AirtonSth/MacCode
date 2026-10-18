import XCTest
@testable import SocketServer
import CoreModel

/// F7, lane M2: `headSequence` in the welcome of a real loopback `/v1/ws`.
/// A phone whose cursor is at or below the head it was told takes no snapshot
/// and trusts the replay to end at that head, so the Mac may state it only to
/// a durable socket of this boot whose cursor it accepted as sent. Every other
/// socket must look exactly as today: iPhones decode the welcome with an exact
/// key set and end the stream on an unknown key. `EventBus.shared` is one
/// counter for the whole test process and a socket close publishes a
/// diagnostic, so these tests assert relations between values of one welcome
/// and markers with unique names, never an absolute sequence read earlier.
@MainActor
final class ResumeHeadWelcomeTests: XCTestCase {
    private let log = FakeDurableEventLog()
    private static let hostId = "f7-head-host"
    private static let token = "resume.head.v1"
    private static let rotationNotice = "other.feature.v1"
    /// The welcome key set every client that did not ask decodes with exact-key checks.
    private static let legacyWelcomeKeys: Set<String> = [
        "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
        "serverTimeEpochMs", "heartbeatIntervalMs", "heartbeatTimeoutMs",
        "snapshotTimeoutMs", "currentSequence", "oldestReplaySequence", "capabilities",
    ]
    /// What a durable socket that did not ask gets today.
    private static let durableWelcomeKeys = legacyWelcomeKeys.union(["replayFromSequence"])

    override func setUp() {
        super.setUp()
        log.wire(EventBus.shared)
    }

    override func tearDown() {
        FakeDurableEventLog.unwire(EventBus.shared)
        EventBus.shared.clearPreviousBootReplayForTesting()
        super.tearDown()
    }

    // MARK: - Tests

    func test_liveWelcome_tellsTheHead_onlyToADurableSocketOfThisBootThatAsked() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        Self.publishMarker(unique("anchor"))
        let c = EventBus.shared.currentSeq

        // (a) The feature: durable, this host and boot, asking, cursor accepted as sent.
        let told = try await welcome(port: port, since: c, durable: true, resumeEpoch: 42, features: Self.token)
        XCTAssertEqual(Set(told.keys), Self.durableWelcomeKeys.union(["headSequence"]))
        XCTAssertEqual(int(told, "headSequence"), int(told, "currentSequence"),
                       "one welcome cannot name two heads")
        XCTAssertEqual(int(told, "replayFromSequence"), c, "the cursor the phone holds, unchanged")
        XCTAssertEqual(headCapabilityCount(told), 1)

        // (b) Not durable: its head was read before its subscription, so nothing is stated.
        let notDurable = try await welcome(port: port, since: c, features: Self.token)
        XCTAssertEqual(Set(notDurable.keys), Self.legacyWelcomeKeys)

        // (c) to (f): table M-1 seen from outside. Each is a way to show old data as current.
        let untold: [(why: String, since: Int64, epoch: Int64?)] = [
            ("(c) no envelope says which boot the cursor is from", c, nil),
            ("(d) another boot that left no clean record", c, 41),
            ("(e) a cursor above the head was clamped: not the one the phone holds", c + 1_000_000, 42),
            ("(f) a phone with no cursor has no state to call current", 0, 42),
        ]
        for row in untold {
            let object = try await welcome(
                port: port, since: row.since, durable: true, resumeEpoch: row.epoch, features: Self.token
            )
            XCTAssertEqual(Set(object.keys), Self.durableWelcomeKeys, row.why)
        }

        // (g) One header carries two features; each token gates only its own key.
        let both = try await welcome(
            port: port, since: c, durable: true, resumeEpoch: 42,
            features: "\(Self.rotationNotice), \(Self.token)"
        )
        XCTAssertEqual(Set(both.keys), Self.durableWelcomeKeys.union(["headSequence"]))
        XCTAssertEqual(int(both, "headSequence"), int(both, "currentSequence"))

        // (h) A shipped iPhone sends none of these headers: one more capability string, nothing else.
        let plain = try await welcome(port: port)
        XCTAssertEqual(Set(plain.keys), Self.legacyWelcomeKeys)
        XCTAssertEqual(headCapabilityCount(plain), 1,
                       "advertised on every welcome, once: a duplicate fails the host's own validator")
    }

    func test_durableWelcome_withoutTheToken_hasExactlyTodaysKeys() async throws {
        // The iOS head sends exactly request (1) below and ends the stream on an
        // unknown welcome key ("invalid stream welcome", terminal). No other test
        // pins the key set of a durable welcome.
        let (server, port) = try startServer()
        defer { server.stop() }
        Self.publishMarker(unique("anchor"))
        let belowHead = EventBus.shared.currentSeq
        Self.publishMarker(unique("later-1"))
        Self.publishMarker(unique("later-2"))
        let atHead = EventBus.shared.currentSeq

        for since in [atHead, belowHead] {
            // (1) Durable replay plus the identity extension: today's iPhone.
            let identity = try await welcome(
                port: port, since: since, durable: true, resumeEpoch: 42, welcomeFields: "identity.v1"
            )
            XCTAssertEqual(Set(identity.keys),
                           Self.durableWelcomeKeys.union(["apiVersion", "capabilitiesDigest"]), "since=\(since)")
            // (2) Another feature's token alone brings no head.
            let rotation = try await welcome(
                port: port, since: since, durable: true, resumeEpoch: 42, features: Self.rotationNotice
            )
            XCTAssertEqual(Set(rotation.keys), Self.durableWelcomeKeys, "since=\(since)")
            // (3) No opt-in header.
            let plain = try await welcome(port: port, since: since, durable: true, resumeEpoch: 42)
            XCTAssertEqual(Set(plain.keys), Self.durableWelcomeKeys, "since=\(since)")
            for object in [identity, rotation, plain] {
                XCTAssertEqual(headCapabilityCount(object), 1, "since=\(since)")
            }
            // Control: the same socket is told the head once it lists the token.
            let asked = try await welcome(
                port: port, since: since, durable: true, resumeEpoch: 42, features: Self.token
            )
            XCTAssertEqual(Set(asked.keys), Self.durableWelcomeKeys.union(["headSequence"]), "since=\(since)")
        }
    }

    func test_previousCleanBootCursor_isReplayedButToldNoHead() async throws {
        // A boot change must reach the reload on the phone even when the Mac can
        // replay across it: sequences of two boots are not comparable.
        let (server, port) = try startServer()
        defer { server.stop() }
        Self.publishMarker(unique("anchor"))
        let cursor = EventBus.shared.currentSeq
        Self.publishMarker(unique("old-boot-tail"))
        EventBus.shared.installPreviousBootReplay(EventBus.PreviousBootReplay(
            bootEpoch: 41,
            highWater: EventBus.shared.currentSeq,
            lostStreams: [:],
            minimumCursor: 0
        ))
        Self.publishMarker(unique("new-boot"))

        let previous = try await welcome(
            port: port, since: cursor, durable: true, resumeEpoch: 41, features: Self.token
        )
        XCTAssertEqual(int(previous, "replayFromSequence"), cursor, "the Mac replays the previous boot's cursor")
        XCTAssertNil(previous["headSequence"], "but it vouches for no head across a boot change")

        let current = try await welcome(
            port: port, since: EventBus.shared.currentSeq, durable: true, resumeEpoch: 42, features: Self.token
        )
        XCTAssertNotNil(current["headSequence"], "a cursor of this boot is told the head")
    }

    func test_eventPublishedAfterTheHeadWasRead_arrivesOnce_afterReplayComplete() async throws {
        // The phone took no snapshot on the strength of the head: an event
        // published right after it exists only on the stream.
        let late = unique("late")
        let (server, port) = try startServer(afterWelcome: Self.publishingOnce(late))
        defer { server.stop() }
        // The cursor must be above 0, or the Mac states no head at all.
        Self.publishMarker(unique("anchor"))
        let task = socket(
            port: port, since: EventBus.shared.currentSeq, durable: true, resumeEpoch: 42, features: Self.token
        )
        defer { task.cancel(with: .goingAway, reason: nil) }
        let first = try await next(task)
        let head = try XCTUnwrap(int(first, "headSequence"),
                                 "a durable socket of this boot that asked is told its head")
        let replayFrom = try XCTUnwrap(int(first, "replayFromSequence"))

        var collected = try await frames(task) { self.marker($0) == late }
        let completes = collected.indices.filter { collected[$0]["type"] as? String == "replayComplete" }
        XCTAssertEqual(completes.count, 1, "the marker is read after the one end marker")
        let complete = try XCTUnwrap(completes.first)
        XCTAssertEqual(int(collected[complete], "throughSequence"), head)
        XCTAssertFalse(collected.contains { $0["type"] as? String == "baselineRequired" })
        for (index, frame) in collected.enumerated() {
            guard let sequence = eventSequence(frame) else { continue }
            if index < complete {
                // Another test's socket can publish a close diagnostic between
                // this test's cursor read and its subscription: that is replay.
                XCTAssertTrue(sequence > replayFrom && sequence <= head, "replayed sequence \(sequence)")
                XCTAssertNotEqual(marker(frame), late, "published after the head was read: never inside the replay")
            } else {
                XCTAssertGreaterThan(sequence, head, "live events are above the head the welcome named")
            }
        }

        let after = unique("after")
        Self.publishMarker(after)
        collected += try await frames(task) { self.marker($0) == after }
        XCTAssertEqual(collected.filter { marker($0) == late }.count, 1,
                       "delivered once, not replayed and then sent again")
        let sequences = collected.compactMap(eventSequence)
        XCTAssertTrue(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 },
                      "sequences increase over the whole socket")
    }

    func test_headCountsSequencesTheSocketFilterDroppedAndTheBatcherCoalesced() async throws {
        // The head is the bus counter, not what a socket carried: a phone whose
        // cursor equals it must be able to conclude that nothing was published.
        let (server, port) = try startServer()
        defer { server.stop() }
        let suffix = UUID().uuidString.prefix(8)
        let shown = "t-f7-shown-\(suffix)", hidden = "t-f7-hidden-\(suffix)"
        let a = socket(
            port: port, since: EventBus.shared.currentSeq,
            filter: "cellular-safe", interest: shown,
            coalesceWindowMs: DirectHTTPServer.wsCoalescingWindowMaxMs
        )
        defer { a.cancel(with: .goingAway, reason: nil) }
        let aWelcome = try await next(a)
        XCTAssertEqual(aWelcome["type"] as? String, "welcome")

        let m1 = unique("m1")
        Self.publishMarker(m1)
        for text in ["a", "b", "c", "d", "e"] { delta(thread: shown, text: text) }
        var joined = ""
        var carried = try await frames(a) { frame in
            joined += self.deltaText(frame, thread: shown) ?? ""
            return joined.count >= 5
        }
        // How many frames carried the five deltas is a timing fact; their text is not.
        XCTAssertEqual(joined, "abcde")
        let m1Index = try XCTUnwrap(carried.firstIndex { marker($0) == m1 })
        let firstDelta = try XCTUnwrap(carried.firstIndex { deltaText($0, thread: shown) != nil })
        XCTAssertLessThan(m1Index, firstDelta)
        XCTAssertLessThanOrEqual(carried.filter { deltaText($0, thread: shown) != nil }.count, 5)
        let m1Sequence = try XCTUnwrap(eventSequence(carried[m1Index]))

        // Six events A's filter drops: by kind, by interest, and as a diagnostic.
        let beforeDropped = EventBus.shared.currentSeq
        for _ in 0..<3 {
            EventBus.shared.publish(kind: .agentProviderRuntimeEvent, payload: .object([
                "thread_id": .string(shown),
            ]))
        }
        for text in ["x", "y"] { delta(thread: hidden, text: text) }
        EventBus.shared.publish(kind: .diagnosticWSSlowClient, payload: .object([:]))
        let afterDropped = EventBus.shared.currentSeq

        let b = try await welcome(
            port: port, since: afterDropped, durable: true, resumeEpoch: 42, features: Self.token
        )
        let head = try XCTUnwrap(int(b, "headSequence"), "a durable socket of this boot that asked is told its head")
        XCTAssertEqual(head, int(b, "currentSequence"))
        XCTAssertGreaterThanOrEqual(head, m1Sequence + 11,
                                    "the five deltas and the six dropped events each took a sequence")
        let highestSentToA = try XCTUnwrap(carried.compactMap(eventSequence).max())
        XCTAssertGreaterThan(head, highestSentToA, "above every sequence the filtered socket was sent")

        let m2 = unique("m2")
        Self.publishMarker(m2)
        carried += try await frames(a) { self.marker($0) == m2 }
        let m2Sequence = try XCTUnwrap(carried.last.flatMap(eventSequence))
        XCTAssertGreaterThanOrEqual(m2Sequence, m1Sequence + 12)
        XCTAssertFalse(carried.compactMap(eventSequence).contains { $0 > beforeDropped && $0 <= afterDropped },
                       "none of the six reached A, yet the head counted them")
    }

    func test_replayBelowTheHead_endsAtTheHeadTheWelcomeNamed() async throws {
        // A cursor below the head is the usual case on a real Mac; the phone's
        // rule needs the end of the replay to be the head it was told.
        let (server, port) = try startServer()
        defer { server.stop() }
        // The cursor must be above 0, or the Mac states no head at all.
        Self.publishMarker(unique("anchor"))
        let c = EventBus.shared.currentSeq
        let m1 = unique("m1"), m2 = unique("m2")
        Self.publishMarker(m1)
        Self.publishMarker(m2)
        EventBus.shared.publish(kind: .agentProviderRuntimeEvent, payload: .object([
            "thread_id": .string("t-f7-replay"),
        ]))

        let task = socket(port: port, since: c, durable: true, resumeEpoch: 42, features: Self.token)
        defer { task.cancel(with: .goingAway, reason: nil) }
        let first = try await next(task)
        XCTAssertEqual(int(first, "replayFromSequence"), c)
        let head = try XCTUnwrap(int(first, "headSequence"), "a cursor below the head is told the head too")
        XCTAssertEqual(head, int(first, "currentSequence"))
        XCTAssertGreaterThanOrEqual(head, c + 3, "the event no socket is sent still took a sequence")

        let backlog = try await frames(task) { $0["type"] as? String == "replayComplete" }
        XCTAssertEqual(backlog.compactMap(marker).filter { $0 == m1 || $0 == m2 }, [m1, m2])
        XCTAssertFalse(backlog.contains { $0["type"] as? String == "baselineRequired" })
        XCTAssertEqual(backlog.last.flatMap { int($0, "throughSequence") }, head)
    }

    func test_socketThatWillGetABaseline_isToldNoHead() async throws {
        // A welcome cannot say "reload" and offer a head to compare with.
        let (server, port) = try startServer()
        defer { server.stop() }
        // The scenario of `test_durableSocket_logPrunedPastCursor_getsBaselineRequired`.
        let cursor = evictedRingCursor()
        log.prune(through: cursor)
        let task = socket(port: port, since: cursor, durable: true, resumeEpoch: 42, features: Self.token)
        defer { task.cancel(with: .goingAway, reason: nil) }
        let first = try await next(task)
        XCTAssertEqual(first["type"] as? String, "welcome")
        XCTAssertEqual(int(first, "replayFromSequence"), int(first, "currentSequence"),
                       "replayFromSequence == currentSequence announces the baseline")
        XCTAssertNil(first["headSequence"])
        let following = try await frames(task) { _ in true }
        XCTAssertEqual(following.first?["type"] as? String, "baselineRequired")

        let current = try await welcome(
            port: port, since: EventBus.shared.currentSeq, durable: true, resumeEpoch: 42, features: Self.token
        )
        XCTAssertNotNil(current["headSequence"], "the same request at a cursor the Mac can serve is told the head")
    }

    // MARK: - Helpers
    // (copied from DurableReplayWebSocketTests and WelcomeIdentityContractTests,
    // where they are file-private)

    private func startServer(
        afterWelcome: ((String) -> Void)? = nil
    ) throws -> (DirectHTTPServer, UInt16) {
        var lastError: Error?
        for _ in 0..<10 {
            let port = UInt16.random(in: 33000...44000)
            let server = DirectHTTPServer(
                port: port, loopbackOnly: true,
                dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                serverId: Self.hostId, bootEpoch: 42
            )
            server.afterWelcomeWriteForTests = afterWelcome
            do { try server.start(); return (server, port) } catch { lastError = error }
        }
        throw lastError ?? POSIXError(.EADDRINUSE)
    }

    /// `resumeEpoch` sends the resume envelope: this host's id and that boot epoch.
    private func socket(
        port: UInt16, since: Int64? = nil, durable: Bool = false,
        resumeEpoch: Int64? = nil, features: String? = nil,
        filter: String? = nil, interest: String? = nil,
        welcomeFields: String? = nil, coalesceWindowMs: Int? = nil
    ) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        if let since { request.setValue("\(since)", forHTTPHeaderField: "X-RC2-Since-Seq") }
        if durable { request.setValue("v1", forHTTPHeaderField: "X-RC2-Durable-Replay") }
        if let resumeEpoch {
            request.setValue(Self.hostId, forHTTPHeaderField: "X-RC2-Resume-Host-Id")
            request.setValue("\(resumeEpoch)", forHTTPHeaderField: "X-RC2-Resume-Boot-Epoch")
        }
        if let features { request.setValue(features, forHTTPHeaderField: "X-RC2-Client-Features") }
        if let filter { request.setValue(filter, forHTTPHeaderField: "X-RC2-WS-Filter") }
        if let interest { request.setValue(interest, forHTTPHeaderField: "X-RC2-WS-Interest-Threads") }
        if let welcomeFields { request.setValue(welcomeFields, forHTTPHeaderField: "X-RC2-Welcome-Fields") }
        if let coalesceWindowMs {
            request.setValue("\(coalesceWindowMs)", forHTTPHeaderField: "X-RC2-WS-Coalesce-Window-Ms")
        }
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1_024 * 1_024
        task.resume()
        return task
    }

    private func next(_ task: URLSessionWebSocketTask, seconds: Double = 10) async throws -> [String: Any] {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: data = Data()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Reads frames (skipping heartbeats) up to and including the first one `stop` accepts.
    private func frames(
        _ task: URLSessionWebSocketTask,
        until stop: ([String: Any]) -> Bool
    ) async throws -> [[String: Any]] {
        var collected: [[String: Any]] = []
        for _ in 0..<400 {
            let frame = try await next(task)
            if frame["type"] as? String == "heartbeat" { continue }
            collected.append(frame)
            if stop(frame) { return collected }
        }
        XCTFail("frame budget exhausted")
        return collected
    }

    /// The first frame of a new socket, which must be a welcome the strict decoder accepts.
    private func welcome(
        port: UInt16, since: Int64? = nil, durable: Bool = false,
        resumeEpoch: Int64? = nil, features: String? = nil, welcomeFields: String? = nil
    ) async throws -> [String: Any] {
        let task = socket(
            port: port, since: since, durable: durable,
            resumeEpoch: resumeEpoch, features: features, welcomeFields: welcomeFields
        )
        defer { task.cancel(with: .goingAway, reason: nil) }
        let object = try await next(task)
        XCTAssertEqual(object["type"] as? String, "welcome")
        XCTAssertNoThrow(try ConnectionTransportFrame.decodeStrict(
            JSONSerialization.data(withJSONObject: object)
        ), "the live welcome must pass the strict contract decoder")
        return object
    }

    private func unique(_ label: String) -> String {
        "f7-\(label)-\(UUID().uuidString)"
    }

    /// Nonisolated: the welcome hook publishes from a connection thread.
    nonisolated private static func publishMarker(_ name: String) {
        EventBus.shared.publish(kind: .workspaceUpdated, payload: .object([
            "workspace_id": .string("w-f7-head"), "name": .string(name),
        ]))
    }

    /// A welcome hook that publishes `name` on its first call only. The hook
    /// runs after the welcome was written and before the replay starts.
    nonisolated private static func publishingOnce(_ name: String) -> (String) -> Void {
        let first = FirstCall()
        return { _ in
            guard first.take() else { return }
            Self.publishMarker(name)
        }
    }

    /// One delta of one item; a turn id makes it coalesce on a cellular socket.
    private func delta(thread: String, text: String) {
        EventBus.shared.publish(kind: .agentItemDelta, payload: .object([
            "thread_id": .string(thread), "item_id": .string("i-\(thread)"),
            "turn_id": .string("turn-\(thread)"), "body_append": .string(text),
        ]))
    }

    /// The client saw through the returned cursor; then a gap long enough that
    /// the 2 MiB ring dropped everything up to the flood's tail.
    private func evictedRingCursor() -> Int64 {
        let suffix = UUID().uuidString.prefix(8)
        Self.publishMarker(unique("anchor"))
        let cursor = EventBus.shared.currentSeq
        delta(thread: "t-f7-gap-\(suffix)", text: "x")
        Self.publishMarker(unique("m1"))
        Self.publishMarker(unique("m2"))
        let flood = String(repeating: "x", count: 64 * 1_024)
        for _ in 0..<40 { delta(thread: "t-f7-flood-\(suffix)", text: flood) }
        Self.publishMarker(unique("m3"))
        delta(thread: "t-f7-ok-\(suffix)", text: "x")
        return cursor
    }

    private func marker(_ frame: [String: Any]) -> String? {
        (frame["payload"] as? [String: Any])?["name"] as? String
    }

    /// The text one `agent.item.delta` frame of `thread` appends.
    private func deltaText(_ frame: [String: Any], thread: String) -> String? {
        guard frame["kind"] as? String == "agent.item.delta",
              let payload = frame["payload"] as? [String: Any],
              payload["thread_id"] as? String == thread else { return nil }
        return payload["body_append"] as? String
    }

    private func int(_ frame: [String: Any], _ key: String) -> Int64? {
        (frame[key] as? NSNumber)?.int64Value
    }

    /// The sequence of an event frame; no other frame type moves a cursor.
    private func eventSequence(_ frame: [String: Any]) -> Int64? {
        frame["type"] as? String == "event" ? int(frame, "sequence") : nil
    }

    private func headCapabilityCount(_ welcome: [String: Any]) -> Int {
        (welcome["capabilities"] as? [String] ?? []).filter { $0 == Self.token }.count
    }
}

/// True for the first caller only; the welcome hook runs on a connection thread.
private final class FirstCall: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
