import AppKit
import CoreModel
import Persistence
import XCTest
@testable import AppShell

/// Titio's speech bubble on the pet (hub spec §9). The bubble is a glance on
/// top of the banner: it must stay short-lived, never pile up, never talk over
/// the inbox the user is already reading, and always open the exact message.
@MainActor
final class PetSpeechTests: XCTestCase {
    // MARK: Fixtures

    /// A manual clock and timer list, so TTLs are checked without sleeping.
    private final class ManualClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        private var timers: [(id: Int, at: Date, fire: @MainActor () -> Void)] = []
        private var cancelled: Set<Int> = []
        private var nextID = 0

        var pendingTimerCount: Int { timers.filter { !cancelled.contains($0.id) }.count }

        func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
            nextID += 1
            let id = nextID
            timers.append((id, now.addingTimeInterval(delay), fire))
            return { [weak self] in self?.cancelled.insert(id) }
        }

        @MainActor
        func advance(by seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            while let index = timers.firstIndex(where: { $0.at <= now }) {
                let timer = timers.remove(at: index)
                guard !cancelled.contains(timer.id) else { continue }
                timer.fire()
            }
        }
    }

    private struct Harness {
        let clock: ManualClock
        let model: PetViewModel
        let controller: PetSpeechController
        let box: Box
    }

    private final class Box {
        var inputs = PetSpeechSuppression.Inputs(
            speechEnabled: true, petEnabled: true, petVisible: true, popoverOpen: false, inboxIsKeyDesk: false
        )
        var presented: [PetSpeech] = []
        var dismissals: [Bool] = []
        var routes: [[String: String]] = []
        var spoken: [PetSpeech] = []
        var presentSucceeds = true
        var onClick: (() -> Void)?
        var announced: [PetSpeech] = []
    }

    private func harness() -> Harness {
        let clock = ManualClock()
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let box = Box()
        let controller = PetSpeechController(
            model: model,
            now: { clock.now },
            schedule: { delay, fire in clock.schedule(delay, fire) }
        )
        controller.inputs = { _ in box.inputs }
        controller.present = { speech, onClick in
            box.presented.append(speech)
            box.onClick = onClick
            return box.presentSucceeds
        }
        controller.dismiss = { box.dismissals.append($0) }
        controller.openRoute = { box.routes.append($0) }
        controller.onSpoke = { box.spoken.append($0) }
        controller.announce = { box.announced.append($0) }
        return Harness(clock: clock, model: model, controller: controller, box: box)
    }

    private let inboxBot = BotID()
    private let inboxConversation = BotConversationID()

    private func speech(_ urgency: TitioNoticeUrgency, _ text: String = "Hmm, looks like Build is done.") -> PetSpeech {
        PetSpeech(
            text: text,
            urgency: urgency,
            messageID: AgentMessageID(),
            botID: inboxBot,
            conversationID: inboxConversation
        )
    }

    // MARK: Queue and TTL

    func test_infoLeavesAfterSixSecondsAndAlertsOrDecisionsAfterTwelve() {
        // WHY: info is a glance (6 s); an alert or a decision must stay long
        // enough to be read and clicked (12 s). Both then leave on their own.
        let h = harness()
        h.controller.speak(speech(.info))
        XCTAssertNotNil(h.model.speech, "the bubble shows on the arrival turn")
        h.clock.advance(by: 5.9)
        XCTAssertNotNil(h.model.speech)
        h.clock.advance(by: 0.1)
        XCTAssertNil(h.model.speech, "info leaves at 6 s")
        XCTAssertEqual(h.box.dismissals, [true], "the TTL exit is the animated fade")

        for urgency in [TitioNoticeUrgency.alert, .decision] {
            h.controller.speak(speech(urgency))
            h.clock.advance(by: 11.9)
            XCTAssertNotNil(h.model.speech, "\(urgency) is still up before 12 s")
            h.clock.advance(by: 0.1)
            XCTAssertNil(h.model.speech, "\(urgency) leaves at 12 s")
        }
        XCTAssertEqual(h.clock.pendingTimerCount, 0, "no timer outlives its bubble")
    }

    func test_aNewBubbleIsAnnouncedToVoiceOver() {
        // WHY: the bubble lives in a non-activating panel that never takes
        // focus, so VoiceOver users never learned Titio spoke (banners are
        // suppressed while RemoteCode is frontmost).
        let h = harness()
        let decision = speech(.decision, "Preciso que você decida uma coisa.")
        h.controller.speak(decision)
        XCTAssertEqual(h.box.announced, [decision])
        h.box.inputs.inboxIsKeyDesk = true
        h.controller.speak(speech(.info))
        XCTAssertEqual(h.box.announced.count, 1, "a suppressed bubble is not announced either")
    }

    func test_theBubbleNeverExpiresUnderThePointer() {
        // WHY: the TTL fired mid-hover, so the bubble vanished as the user
        // reached for it. Hovering pauses it; leaving gives a short grace.
        let h = harness()
        h.controller.speak(speech(.info))
        h.clock.advance(by: 5)
        h.controller.setHovering(true)
        h.clock.advance(by: 20)
        XCTAssertNotNil(h.model.speech, "still up while the pointer is on it")
        h.controller.setHovering(false)
        h.clock.advance(by: PetSpeechController.hoverGrace - 0.1)
        XCTAssertNotNil(h.model.speech, "a short grace after the pointer leaves")
        h.clock.advance(by: 0.1)
        XCTAssertNil(h.model.speech)
    }

    func test_theNeedsYouChipAgreesInNumber() {
        // WHY: "1 need you" is wrong English in the pet popover and its tooltip.
        XCTAssertEqual(PetAttentionCountFormatter.needYouText(badgeText: "1"), "1 needs you")
        XCTAssertEqual(PetAttentionCountFormatter.needYouText(badgeText: "3"), "3 need you")
        XCTAssertEqual(PetAttentionCountFormatter.needYouText(badgeText: "99+"), "99+ need you")
    }

    func test_newerInfoReplacesOlderInfoShownOrWaiting() {
        // WHY: a burst of completions must not chain six bubbles; only the
        // latest info is worth a glance (all of them are in the inbox).
        let h = harness()
        let first = speech(.info, "first")
        let second = speech(.info, "second")
        h.controller.speak(first)
        h.clock.advance(by: 4)
        h.controller.speak(second)
        XCTAssertEqual(h.model.speech, second, "the newer info replaces the one showing")
        h.clock.advance(by: 5.9)
        XCTAssertEqual(h.model.speech, second, "the replacement gets a fresh 6 s")

        var queue = PetSpeechQueue()
        let decision = speech(.decision, "decide")
        let waitingInfo = speech(.info, "old info")
        let newerInfo = speech(.info, "new info")
        queue.enqueue(decision, now: h.clock.now)
        queue.enqueue(waitingInfo, now: h.clock.now)
        queue.enqueue(newerInfo, now: h.clock.now)
        XCTAssertEqual(queue.current, decision)
        XCTAssertEqual(queue.waiting, [newerInfo], "a waiting info is replaced, not queued twice")
    }

    func test_alertCutsAShowingInfoShortButAlertsAndDecisionsWaitTheirTurn() {
        // WHY: urgent things must not wait behind a "done" glance, but two
        // decisions must both be seen, in order.
        let h = harness()
        let info = speech(.info)
        let alert = speech(.alert, "failed")
        let decision = speech(.decision, "approve?")
        h.controller.speak(info)
        h.controller.speak(alert)
        XCTAssertEqual(h.model.speech, alert, "the alert replaces the info at once")
        h.controller.speak(decision)
        XCTAssertEqual(h.model.speech, alert, "a decision waits behind the alert")
        h.clock.advance(by: 12)
        XCTAssertEqual(h.model.speech, decision, "then shows with its own 12 s")
        h.clock.advance(by: 12)
        XCTAssertNil(h.model.speech)
        XCTAssertEqual(h.box.presented, [info, alert, decision])
    }

    func test_queueHoldsAtMostThreeAndDropsTheOldestWaiting() {
        // WHY: a storm of failures must not keep the pet talking for minutes;
        // the inbox already has every notice.
        var queue = PetSpeechQueue()
        let now = Date()
        let items = (0..<5).map { speech(.alert, "alert \($0)") }
        for item in items { queue.enqueue(item, now: now) }
        XCTAssertEqual(queue.count, PetSpeechQueue.maxCount)
        XCTAssertEqual(PetSpeechQueue.maxCount, 3)
        XCTAssertEqual(queue.current, items[0], "the bubble on screen is never yanked by the cap")
        XCTAssertEqual(queue.waiting, [items[3], items[4]], "the freshest waiting alerts survive")
    }

    func test_textIsOneClippedLineOfAtMostNinetyCharacters() {
        // WHY: the bubble is two lines at most; the host clips to 90 already,
        // and the bubble must hold that even for a caller that does not.
        let long = String(repeating: "palavra ", count: 30)
        let clipped = speech(.info, "linha um\nlinha dois " + long)
        XCTAssertLessThanOrEqual(clipped.text.count, PetSpeech.maxCharacters)
        XCTAssertEqual(PetSpeech.maxCharacters, 90)
        XCTAssertFalse(clipped.text.contains("\n"))
        XCTAssertTrue(clipped.text.hasSuffix("…"))
        XCTAssertEqual(speech(.info, "short").text, "short", "short text is untouched")
    }

    // MARK: Suppression

    func test_suppressionRulesEachSilenceTheBubble() {
        // WHY: the owner can turn speech off, a hidden or disabled pet cannot
        // speak, the open popover already shows the pet's card, and when the
        // inbox is the key desk the user is reading the message itself.
        let base = PetSpeechSuppression.Inputs(
            speechEnabled: true, petEnabled: true, petVisible: true, popoverOpen: false, inboxIsKeyDesk: false
        )
        XCTAssertNil(PetSpeechSuppression.reason(base))
        var cases: [(PetSpeechSuppression.Inputs, PetSpeechSuppression.Reason)] = []
        var input = base; input.speechEnabled = false; cases.append((input, .speechDisabled))
        input = base; input.petEnabled = false; cases.append((input, .petDisabled))
        input = base; input.petVisible = false; cases.append((input, .petHidden))
        input = base; input.popoverOpen = true; cases.append((input, .popoverOpen))
        input = base; input.inboxIsKeyDesk = true; cases.append((input, .inboxViewed))
        for (inputs, expected) in cases {
            XCTAssertEqual(PetSpeechSuppression.reason(inputs), expected)
            let h = harness()
            h.box.inputs = inputs
            h.controller.speak(speech(.decision))
            XCTAssertNil(h.model.speech, "\(expected) must keep the pet quiet")
            XCTAssertTrue(h.box.presented.isEmpty, "\(expected): nothing reaches the screen")
            XCTAssertEqual(h.controller.queue.count, 0, "\(expected): a silenced notice is not saved for later")
        }
    }

    func test_aRuleThatTurnsOnWhileSpeakingHidesTheBubbleAndItsQueue() {
        // WHY: opening the popover or turning speech off mid-bubble must not
        // leave a stale bubble (or a queued one) to pop up afterwards.
        let h = harness()
        h.controller.speak(speech(.alert))
        h.controller.speak(speech(.decision))
        h.box.inputs.popoverOpen = true
        h.controller.reevaluate()
        XCTAssertNil(h.model.speech)
        XCTAssertEqual(h.controller.queue.count, 0)
        XCTAssertEqual(h.box.dismissals.last, true)
        h.clock.advance(by: 30)
        XCTAssertEqual(h.box.presented.count, 1, "the queued decision never pops up after the rule hid it")
    }

    func test_aPetWindowThatCannotShowTheBubbleClearsTheQueue() {
        // WHY: fail loud and clean: if the window refuses (no screen), the
        // model must not claim a bubble is showing.
        let h = harness()
        h.box.presentSucceeds = false
        h.controller.speak(speech(.alert))
        XCTAssertNil(h.model.speech)
        XCTAssertEqual(h.controller.queue.count, 0)
        XCTAssertTrue(h.box.spoken.isEmpty, "no pounce for a bubble that never showed")
    }

    // MARK: Click route

    func test_clickOpensTheInboxAtThatMessageAndDismisses() throws {
        // WHY: the bubble is a shortcut to the exact message, through the same
        // route mapper a Titio banner click uses, and it goes away on click.
        let h = harness()
        let alert = speech(.alert)
        let waiting = speech(.decision)
        h.controller.speak(alert)
        h.controller.speak(waiting)
        try XCTUnwrap(h.box.onClick)()

        let route = try XCTUnwrap(h.box.routes.first)
        XCTAssertEqual(h.box.routes.count, 1)
        let intent = try XCTUnwrap(AppDelegate.routeFromNotification(userInfo: route))
        let bot = try XCTUnwrap(intent.bot, "the bubble opens a Bot conversation route")
        XCTAssertEqual(bot.botId, alert.botID)
        XCTAssertEqual(bot.conversationId, alert.conversationID)
        XCTAssertEqual(bot.messageId, alert.messageID, "it opens at the message the bubble spoke")
        XCTAssertNil(h.model.speech)
        XCTAssertEqual(h.controller.queue.count, 0, "opening the inbox makes the waiting bubbles redundant")
        XCTAssertEqual(h.box.dismissals, [false], "the click exit is immediate")

        h.clock.advance(by: 30)
        XCTAssertEqual(h.box.presented, [alert], "the old TTL timer is stale and shows nothing")
        try XCTUnwrap(h.box.onClick)()
        XCTAssertEqual(h.box.routes.count, 1, "a second click on a dismissed bubble routes nowhere")
    }

    func test_eachNewBubblePouncesOnce() {
        // WHY: the bubble pairs with the existing notificationPounce, once per
        // bubble that actually appears, never for a replaced waiting one.
        let h = harness()
        h.controller.speak(speech(.alert))
        h.controller.speak(speech(.decision))
        XCTAssertEqual(h.box.spoken.count, 1)
        h.clock.advance(by: 12)
        XCTAssertEqual(h.box.spoken.count, 2)
        XCTAssertEqual(PetCompanionDirector.speechCue(baseState: .idle)?.state, .notificationPounce)
        XCTAssertNil(PetCompanionDirector.speechCue(baseState: .approval),
                     "the pounce never covers a pose that already asks for the user")
        XCTAssertNil(PetCompanionDirector.speechCue(baseState: .sleeping))
    }

    // MARK: Window

    private func database() throws -> SQLiteDB {
        let directory = NSTemporaryDirectory() + "RC2PetSpeech-\(UUID().uuidString)"
        return try Bootstrap(channel: .debug, appSupportOverride: directory).run().1
    }

    func test_bubbleHasItsOwnNonActivatingWindowBesideThePet() throws {
        // WHY: inside the sprite window the bubble would be clipped; a key or
        // activating window would steal focus from whatever the user is typing.
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: try database()))
        )
        defer { controller.stop() }
        controller.show()
        let pet = try XCTUnwrap(controller.petPanelForTests)
        guard pet.isVisible else { throw XCTSkip("no screen to place the pet on") }
        let keyBefore = NSApp?.keyWindow

        XCTAssertTrue(controller.showSpeech(speech(.decision, "Preciso que você decida uma coisa"), reduceMotion: true, onClick: {}))
        let bubble = try XCTUnwrap(controller.speechPanelForTests)
        XCTAssertFalse(bubble === pet, "the bubble must not live in the sprite window")
        XCTAssertTrue(bubble.isVisible)
        XCTAssertTrue(bubble.styleMask.contains(.borderless))
        XCTAssertTrue(bubble.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(bubble.canBecomeKey, "showing or clicking the bubble never takes focus")
        XCTAssertFalse(bubble.canBecomeMain)
        XCTAssertFalse(bubble.isOpaque)
        XCTAssertEqual(bubble.level, .floating)
        XCTAssertTrue(bubble.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(bubble.identifier?.rawValue, "pet.speech")
        XCTAssertTrue(NSApp?.keyWindow === keyBefore, "the key window is unchanged")
        XCTAssertLessThanOrEqual(bubble.frame.width, PetSpeechSizing.maxWidth + 0.5, "max width ~260 pt")
        XCTAssertEqual(bubble.frame.intersection(pet.frame).width * bubble.frame.intersection(pet.frame).height, 0,
                       accuracy: 0.5, "placed beside the pet, not over it")
        if let screen = pet.screen ?? NSScreen.main {
            XCTAssertTrue(screen.visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(bubble.frame))
        }
        XCTAssertTrue(try XCTUnwrap(controller.speechHostingForTests).acceptsFirstMouse(for: nil),
                      "one click works even while another app is active")

        controller.openPopoverForTests()
        XCTAssertFalse(controller.isSpeechVisible, "the popover replaces the bubble")
        controller.closePopover()

        XCTAssertTrue(controller.showSpeech(speech(.info), reduceMotion: true, onClick: {}))
        controller.hide()
        XCTAssertFalse(controller.isSpeechVisible, "hiding the pet hides its bubble")
        XCTAssertFalse(controller.showSpeech(speech(.info), reduceMotion: true, onClick: {}),
                       "a hidden pet cannot speak")
    }

    func test_bubbleSizingKeepsTwoLinesWithinTheMaxWidthAndTheTailOnThePet() {
        // WHY: the bubble is a glance: never wider than ~260 pt, and its tail
        // must point at the pet even when the bubble is pushed by a screen edge.
        let long = String(repeating: "x", count: 90)
        XCTAssertLessThanOrEqual(
            PetSpeechSizing.textWidth(for: long, showsAccentDot: true)
                + PetSpeechSizing.horizontalPadding * 2 + PetSpeechSizing.accentDotSize + PetSpeechSizing.accentDotSpacing,
            PetSpeechSizing.maxWidth + 0.5
        )
        XCTAssertLessThan(PetSpeechSizing.textWidth(for: "Ok", showsAccentDot: false), 100, "short text gets a small bubble")
        let frame = CGRect(x: 100, y: 0, width: 200, height: 50)
        XCTAssertEqual(PetSpeechSizing.tailCenterX(anchorMidX: 160, bubbleFrame: frame), 60)
        XCTAssertEqual(PetSpeechSizing.tailCenterX(anchorMidX: 0, bubbleFrame: frame),
                       PetSpeechSizing.cornerRadius + PetSpeechSizing.tailWidth / 2,
                       "the tail stays clear of the rounded corner")
    }

    func test_motionMatchesThePopoverCardAndReducedMotionIsAPlainFade() throws {
        // WHY: the bubble shares the popover card's motion language: grow from
        // 0.96 toward the pet with a strong ease-out, leave faster. Reduced
        // motion must drop the scale (and the pounce), keeping only opacity.
        XCTAssertEqual(PetSpeechMotion.enterDuration, 0.18)
        XCTAssertEqual(PetSpeechMotion.exitDuration, 0.12)
        XCTAssertLessThan(PetSpeechMotion.exitDuration, PetSpeechMotion.enterDuration)
        XCTAssertEqual(PetSpeechMotion.enterScale, 0.96)
        XCTAssertEqual(PetSpeechMotion.enterCurve.c0x, 0.23)
        XCTAssertEqual(PetSpeechMotion.enterCurve.c0y, 1)
        XCTAssertEqual(PetSpeechMotion.enterCurve.c1x, 0.32)
        XCTAssertEqual(PetSpeechMotion.enterCurve.c1y, 1)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/Pet/PetSpeechPanel.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".scaleEffect(appeared || reduce ? 1 : PetSpeechMotion.enterScale"),
                      "no scale under reduced motion")
        XCTAssertTrue(source.contains(".background(.ultraThinMaterial, in: shape)"), "the popover card's material")
        XCTAssertTrue(source.contains("shape.stroke(Color.white.opacity(0.14), lineWidth: 1)"), "the popover card's hairline")
        XCTAssertTrue(source.contains(".lineLimit(2)"), "two lines and an ellipsis")
        XCTAssertEqual(PetSpeechSizing.cornerRadius, 16)
        let controller = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/Pet/PetController.swift"), encoding: .utf8)
        XCTAssertTrue(controller.contains("|| NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,\n                onClick: onClick"),
                      "the bubble honours the system reduced-motion setting as well as the pet's")
    }

    // MARK: Wiring

    func test_petControllerSpeaksHubNoticesAndRoutesTheClick() throws {
        // WHY: the hub's onSpeech reaches the pet through PetController, which
        // applies the owner's setting and opens the inbox on click.
        let directory = NSTemporaryDirectory() + "RC2PetSpeechController-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petSpeechEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }
        guard controller.windowControllerForTests.isVisible else { throw XCTSkip("no screen to place the pet on") }
        var routes: [[String: String]] = []
        controller.openSpeechRouteForTests = { routes.append($0) }

        let notice = TitioNoticeSpeech(
            text: "Ih, a tarefa Build falhou.",
            urgency: .alert,
            messageID: AgentMessageID(),
            botID: inboxBot,
            conversationID: inboxConversation
        )
        controller.speak(notice)
        XCTAssertNil(controller.modelForTests.speech, "petSpeechEnabled=false keeps the pet quiet")

        let settings = SettingsStore(db: context.db)
        settings.update { $0.petSpeechEnabled = true }
        NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        let deadline = Date().addingTimeInterval(2)
        while controller.modelForTests.settings.petSpeechEnabled == false, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        controller.speak(notice)
        XCTAssertEqual(controller.modelForTests.speech?.messageID, notice.messageID)
        XCTAssertTrue(controller.windowControllerForTests.isSpeechVisible)

        controller.speechControllerForTests.click()
        XCTAssertEqual(routes.first?["messageId"], notice.messageID.value.uuidString.lowercased())
        XCTAssertEqual(routes.first?["conversationId"], inboxConversation.value.uuidString.lowercased())
        XCTAssertNil(controller.modelForTests.speech)
        XCTAssertFalse(controller.windowControllerForTests.isSpeechVisible)
    }

    func test_appDelegateWiresTheHubSpeechToThePetAndUnwiresItOnStop() throws {
        // WHY: without this hook the hub posts notices but the pet never
        // speaks; a stopped pet must not keep receiving speech.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let delegate = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(delegate.contains("context.titioNoticeCenter.setOnSpeech { [weak controller] speech in"))
        XCTAssertTrue(delegate.contains("Task { @MainActor in controller?.speak(speech) }"))
        XCTAssertTrue(delegate.contains("context?.titioNoticeCenter.setOnSpeech(nil)"))
    }
}
