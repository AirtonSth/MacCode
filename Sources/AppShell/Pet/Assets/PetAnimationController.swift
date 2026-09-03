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
    private let atlas: PetAtlas
    private let scheduler: any PetAnimationScheduling
    private let idleActionProvider: () -> PetIdleMicroAction
    private let idleRestDelayProvider: () -> TimeInterval
    private var timer: (any PetAnimationTimer)?
    private var derivedTerminalState: PetAnimationState?
    private var isIdleResting = false
    private var idleFrameSequence: [Int] = []
    private var idleFrameSequencePosition = 0

    private var isVisible = true
    private var isScreenLocked = false
    private var animationsEnabled = true
    private var reducedMotion = false

    private(set) var currentState: PetAnimationState = .idle
    private(set) var currentFrameIndex = 0
    private(set) var currentFrame: PetAtlasFrame?
    private(set) var currentIdleMicroAction: PetIdleMicroAction?

    var onFrame: ((PetAtlasFrame) -> Void)?
    var onError: ((Error) -> Void)?
    var timerIsRunning: Bool { timer?.isValid == true }

    convenience init(atlas: PetAtlas) throws {
        try self.init(atlas: atlas, scheduler: FoundationPetAnimationScheduler())
    }

    init(
        atlas: PetAtlas,
        scheduler: any PetAnimationScheduling,
        idleActionProvider: @escaping () -> PetIdleMicroAction = {
            PetIdleMicroAction.select(Int.random(in: 0..<100))
        },
        idleRestDelayProvider: @escaping () -> TimeInterval = {
            Double.random(in: PetIdleMicroAction.restDelayRange)
        }
    ) throws {
        self.atlas = atlas
        self.scheduler = scheduler
        self.idleActionProvider = idleActionProvider
        self.idleRestDelayProvider = idleRestDelayProvider
        try atlas.activate(.idle)
        currentFrame = try atlas.canonicalIdleMicroActionFrame()
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
        resetIdlePlayback()
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

    func loopSafeDurationMilliseconds(
        for state: PetAnimationState,
        requested: Int64
    ) -> Int64 {
        let allowed = PetCompanionDirector.extendedReactionDurationRange
        guard state.isExtendedCompanionReaction,
              allowed.contains(requested),
              let row = atlas.manifest.row(for: state) else {
            return requested
        }
        let frameMilliseconds = 1_000.0 / Double(row.fps)
        let cycleMilliseconds = frameMilliseconds * Double(row.frames)
        let maximumCycles = Int(ceil(Double(allowed.upperBound) / cycleMilliseconds)) + 1
        // PERF: single pass avoids the per-cycle 2-element arrays plus the
        // map + filter intermediates on the reaction-snap path.
        var best: Int64?
        var bestDistance = Int64.max
        for cycle in 1...maximumCycles {
            let boundary = Double(cycle) * cycleMilliseconds
            for edge in [boundary - frameMilliseconds / 2, boundary + frameMilliseconds / 2] {
                let candidate = Int64(edge.rounded())
                guard allowed.contains(candidate) else { continue }
                let distance = abs(candidate - requested)
                if distance < bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
        }
        return best ?? requested
    }

    private var shouldAnimate: Bool {
        isVisible
            && !isScreenLocked
            && animationsEnabled
            && !reducedMotion
    }

    private func reconcilePolicy() {
        stopTimer()
        resetIdlePlayback()
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
        currentIdleMicroAction = nil
        idleFrameSequence = []
        idleFrameSequencePosition = 0
        currentFrameIndex = row.canonicalFrame
        publishCurrentFrameOrStop()
        timer = scheduler.schedule(interval: idleRestDelayProvider()) { [weak self] in
            self?.tick()
        }
    }

    private func beginIdleMicroAction() {
        let action = idleActionProvider()
        currentIdleMicroAction = action
        idleFrameSequence = frameSequence(for: action)
        idleFrameSequencePosition = 0
        currentFrameIndex = idleFrameSequence[0]
        publishCurrentFrameOrStop()
        stopTimer()
        timer = scheduler.schedule(interval: 1.0 / Double(action.framesPerSecond)) { [weak self] in
            self?.tick()
        }
    }

    private func frameSequence(for action: PetIdleMicroAction) -> [Int] {
        switch action {
        case .blink:
            return [1, 2, 4, 0]
        case .tail:
            return [1, 2, 3, 2, 1, 0]
        case .ears:
            return [1, 2, 3, 4, 5, 6, 7, 0]
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func resetIdlePlayback() {
        isIdleResting = false
        currentIdleMicroAction = nil
        idleFrameSequence = []
        idleFrameSequencePosition = 0
    }

    private func tick() {
        guard shouldAnimate,
              let row = atlas.manifest.row(for: currentState) else {
            reconcilePolicy()
            return
        }

        if currentState == .idle, isIdleResting {
            isIdleResting = false
            beginIdleMicroAction()
            return
        }

        if currentState == .idle, currentIdleMicroAction != nil {
            if idleFrameSequencePosition + 1 < idleFrameSequence.count {
                idleFrameSequencePosition += 1
                currentFrameIndex = idleFrameSequence[idleFrameSequencePosition]
                publishCurrentFrameOrStop()
                if idleFrameSequencePosition + 1 == idleFrameSequence.count {
                    scheduleIdleRest(for: row)
                }
            } else {
                scheduleIdleRest(for: row)
            }
            return
        }

        let last = row.frames - 1
        if currentFrameIndex < last {
            currentFrameIndex += 1
            publishCurrentFrameOrStop()
            if currentFrameIndex == last,
               row.mode == .onceHold,
               !currentState.isExtendedCompanionReaction {
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
            if currentState.isExtendedCompanionReaction {
                currentFrameIndex = 0
                publishCurrentFrameOrStop()
            } else {
                stopTimer()
            }
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
        let frame: PetAtlasFrame
        if currentState == .idle {
            frame = try atlas.idleMicroActionFrame(
                action: currentIdleMicroAction ?? .blink,
                index: currentFrameIndex
            )
        } else {
            frame = try atlas.frame(state: currentState, index: currentFrameIndex)
        }
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
