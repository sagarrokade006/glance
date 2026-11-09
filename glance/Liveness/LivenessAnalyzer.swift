//
//  LivenessAnalyzer.swift
//  glance
//
//  Rolling-window driver for the liveness cues. Takes `LivenessFrame`, not
//  `FaceRecognitionResult`, keeping this file's dependency graph shallow enough
//  to compile standalone in `tools/liveness_selftest.swift`.
//

import Foundation

@MainActor
final class LivenessAnalyzer {
    private let windowDuration: TimeInterval

    /// Read fresh on every `observe()`, not captured at init, so a mid-scan Settings change takes effect immediately.
    var modeProvider: () -> LivenessMode = { .light }
    var tuningProvider: () -> LivenessTuning = { .default }
    /// Face Lab can switch individual cues off to isolate one; the unlock
    /// path leaves this at "all enabled."
    var enabledCuesProvider: () -> Set<LivenessCue> = { Set(LivenessCue.allCases) }

    private var frames: [LivenessFrame] = []
    private var evaluator = LivenessEvaluator()
    private(set) var lastSnapshot = LivenessSnapshot.empty
    /// Kept for Face Lab's diagnostics panel (excess ratio, coherence, pair
    /// counts, yaw range) — the numbers behind the flat-vs-3D cue's level.
    private(set) var lastGeometry = GeometryLivenessResult.empty

    init(windowDuration: TimeInterval = 2.0) {
        self.windowDuration = windowDuration
    }

    func reset() {
        frames.removeAll()
        evaluator.reset()
        lastSnapshot = .empty
        lastGeometry = .empty
    }

    /// Clears the motion window and positive evidence of life. Deny-cue counts survive.
    func resetConfirmation() {
        frames.removeAll()
        evaluator.resetConfirmation()
        lastGeometry = .empty
    }

    /// Call once per frame with a detected face, regardless of whether it matched an identity,
    /// so liveness stays an independent gate. The window is time-pruned (~2s) but the evaluator's
    /// fire counts are not — they accumulate across the whole scan, so a spoof tell can't be waited out.
    ///
    /// With `countsTowardConfirmation` false (a face that can't be the owner), any confirmation so far is discarded
    /// and this frame feeds only the deny cues, so one person's blink can't vouch for another face.
    @discardableResult
    func observe(_ frame: LivenessFrame, countsTowardConfirmation: Bool = true) -> LivenessSnapshot {
        evaluator.mode = modeProvider()
        evaluator.tuning = tuningProvider()
        evaluator.enabledCues = enabledCuesProvider()

        guard countsTowardConfirmation else {
            resetConfirmation()
            let readings = LivenessCues.readings(window: [frame], geometry: .empty)
            let snapshot = evaluator.observe(readings, countsTowardConfirmation: false)
            lastSnapshot = snapshot
            return snapshot
        }

        frames.append(frame)
        frames.removeAll { frame.timestamp.timeIntervalSince($0.timestamp) > windowDuration }

        let geometry = GeometryLiveness.evaluate(frames)
        lastGeometry = geometry

        let readings = LivenessCues.readings(window: frames, geometry: geometry)
        let snapshot = evaluator.observe(readings)
        lastSnapshot = snapshot
        return snapshot
    }
}
