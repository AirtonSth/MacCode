import Foundation

protocol PetAnimationTimer: AnyObject {
    var isValid: Bool { get }
    func invalidate()
}

@MainActor
protocol PetAnimationScheduling: AnyObject {
    func schedule(
        interval: TimeInterval,
        handler: @escaping @MainActor () -> Void
    ) -> any PetAnimationTimer
}

private final class FoundationPetAnimationTimer: PetAnimationTimer {
    private let timer: Timer
    var isValid: Bool { timer.isValid }

    init(timer: Timer) {
        self.timer = timer
    }

    func invalidate() { timer.invalidate() }
}

@MainActor
final class FoundationPetAnimationScheduler: PetAnimationScheduling {
    func schedule(
        interval: TimeInterval,
        handler: @escaping @MainActor () -> Void
    ) -> any PetAnimationTimer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { handler() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return FoundationPetAnimationTimer(timer: timer)
    }
}

/// One-timer state player for the packaged Pet atlas.
///
/// Policy changes never create a second timer: the current token is invalidated
/// before scheduling. Paused policies project the manifest's canonical frame.
@MainActor
final class PetAnimationController {
    private static let idleRestDelayRange: ClosedRange<TimeInterval> = 6...12

    private let atlas: PetAtlas
    private let scheduler: any PetAnimationScheduling
    private var timer: (any PetAnimationTimer)?
    private var derivedTerminalState: PetAnimationState?
    private var isIdleResting = false

    private var isVisible = true
    private var isScreenLocked = false
    private var animationsEnabled = true
    private var reducedMotion = false

    private(set) var currentState: PetAnimationState = .idle
    private(set) var currentFrameIndex = 0
    private(set) var currentFrame: PetAtlasFrame?

    var onFrame: ((PetAtlasFrame) -> Void)?
    var onError: ((Error) -> Void)?
    var timerIsRunning: Bool { timer?.isValid == true }

    convenience init(atlas: PetAtlas) throws {
        try self.init(atlas: atlas, scheduler: FoundationPetAnimationScheduler())
    }

    init(atlas: PetAtlas, scheduler: any PetAnimationScheduling) throws {
        self.atlas = atlas
        self.scheduler = scheduler
        try atlas.activate(.idle)
        currentFrame = try atlas.canonicalFrame(for: .idle)
        currentFrameIndex = currentFrame?.index ?? 0
    }

    deinit {
        timer?.invalidate()
    }

    func setState(
        _ state: PetAnimationState,
        derivedTerminalState: PetAnimationState? = nil
    ) throws {
        let previous = currentState
        stopTimer()
        isIdleResting = false
        currentState = state
        self.derivedTerminalState = derivedTerminalState
        try atlas.activate(state, adjacent: [previous])

        guard let row = atlas.manifest.row(for: state) else {
            throw PetAtlasError.invalidManifest("missing row for \(state.rawValue)")
        }
        currentFrameIndex = shouldAnimate ? 0 : row.canonicalFrame
        try publishCurrentFrame()
        if shouldAnimate {
            scheduleTimer(for: row)
        }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        reconcilePolicy()
    }

    func setScreenLocked(_ locked: Bool) {
        isScreenLocked = locked
        reconcilePolicy()
    }

    func setAnimationsEnabled(_ enabled: Bool) {
        animationsEnabled = enabled
        reconcilePolicy()
    }

    func setReducedMotion(_ reduced: Bool) {
        reducedMotion = reduced
        reconcilePolicy()
    }

    func stop() {
        stopTimer()
    }

    private var shouldAnimate: Bool {
        isVisible
            && !isScreenLocked
            && animationsEnabled
            && !reducedMotion
    }

    private func reconcilePolicy() {
        stopTimer()
        isIdleResting = false
        guard let row = atlas.manifest.row(for: currentState) else { return }
        if shouldAnimate {
            scheduleTimer(for: row)
        } else {
            currentFrameIndex = row.canonicalFrame
            do {
                try publishCurrentFrame()
            } catch {
                onError?(error)
            }
        }
    }

    private func scheduleTimer(for row: PetAtlasManifest.Row) {
        if currentState == .idle {
            scheduleIdleRest(for: row)
        } else {
            scheduleFrameTimer(for: row)
        }
    }

    private func scheduleFrameTimer(for row: PetAtlasManifest.Row) {
        stopTimer()
        timer = scheduler.schedule(interval: 1.0 / Double(row.fps)) { [weak self] in
            self?.tick()
        }
    }

    private func scheduleIdleRest(for row: PetAtlasManifest.Row) {
        stopTimer()
        isIdleResting = true
        currentFrameIndex = row.canonicalFrame
        timer = scheduler.schedule(interval: Double.random(in: Self.idleRestDelayRange)) { [weak self] in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard shouldAnimate,
              let row = atlas.manifest.row(for: currentState) else {
            reconcilePolicy()
            return
        }

        if currentState == .idle, isIdleResting {
            isIdleResting = false
            currentFrameIndex = min(row.canonicalFrame + 1, row.frames - 1)
            publishCurrentFrameOrStop()
            scheduleFrameTimer(for: row)
            return
        }

        let last = row.frames - 1
        if currentFrameIndex < last {
            currentFrameIndex += 1
            publishCurrentFrameOrStop()
            if currentFrameIndex == last, row.mode == .onceHold {
                stopTimer()
            }
            return
        }

        switch row.mode {
        case .loop:
            currentFrameIndex = currentState == .idle ? row.canonicalFrame : 0
            publishCurrentFrameOrStop()
            if currentState == .idle {
                scheduleIdleRest(for: row)
            }
        case .onceHold:
            stopTimer()
        case .onceThenWaiting:
            transitionAfterOnce(to: .waiting)
        case .onceThenDerived:
            transitionAfterOnce(to: derivedTerminalState ?? atlas.manifest.fallbackState)
        }
    }

    private func transitionAfterOnce(to state: PetAnimationState) {
        do {
            try setState(state)
        } catch {
            stopTimer()
            onError?(error)
        }
    }

    private func publishCurrentFrame() throws {
        let frame = try atlas.frame(state: currentState, index: currentFrameIndex)
        currentFrame = frame
        onFrame?(frame)
    }

    private func publishCurrentFrameOrStop() {
        do {
            try publishCurrentFrame()
        } catch {
            stopTimer()
            onError?(error)
        }
    }
}
