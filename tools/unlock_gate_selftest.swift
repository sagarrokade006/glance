//
//  unlock_gate_selftest.swift
//  glance (tools)
//
//  Offline, camera-free test for the decisions that lead to typing the Mac password. Compiles against the real files:
//
//      swiftc -O -o /tmp/unlock_gate_selftest \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Liveness/GeometryLiveness.swift \
//        glance/Liveness/GlareCue.swift \
//        glance/Liveness/LivenessCues.swift \
//        glance/Liveness/LivenessScoring.swift \
//        glance/Liveness/LivenessAnalyzer.swift \
//        glance/UnlockGate.swift \
//        tools/unlock_gate_selftest.swift \
//      && /tmp/unlock_gate_selftest
//

import Foundation

private var failureCount = 0

private func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS: \(name)")
    } else {
        failureCount += 1
        print("FAIL: \(name)")
    }
}

private let start = Date(timeIntervalSinceReferenceDate: 0)
private let frameInterval: TimeInterval = 0.05

private func makeFrame(at time: Date, eyeOpenness: CGFloat = 0.3, deviceOverlap: CGFloat? = nil) -> LivenessFrame {
    LivenessFrame(
        timestamp: time,
        landmarks: [],
        interocularDistance: nil,
        yaw: nil,
        leftEyeAspectRatio: eyeOpenness,
        rightEyeAspectRatio: eyeOpenness,
        noseOffsetRatio: nil,
        hasReliableLandmarks: false,
        deviceOverlapFraction: deviceOverlap
    )
}

/// Open, open, closed, open, open: enough for `blinkDynamics` to see a dip with recovery on both sides.
private let blinkEyes: [CGFloat] = [0.3, 0.3, 0.1, 0.3, 0.3]

@MainActor
private final class Scan {
    let gate: UnlockGate
    private(set) var now = start
    private(set) var last = UnlockGate.Decision.keepScanning
    private(set) var everUnlocked = false

    init(mode: LivenessMode?) {
        guard let mode else {
            gate = UnlockGate(liveness: nil)
            return
        }
        let analyzer = LivenessAnalyzer()
        analyzer.modeProvider = { mode }
        gate = UnlockGate(liveness: analyzer)
    }

    func face(_ faceClass: UnlockFaceClass, eyes: CGFloat = 0.3, device: CGFloat? = nil) {
        now += frameInterval
        last = gate.observeFace(faceClass, frame: makeFrame(at: now, eyeOpenness: eyes, deviceOverlap: device), at: now)
        if case .unlock = last { everUnlocked = true }
    }

    func faces(_ faceClass: UnlockFaceClass, count: Int) {
        for _ in 0..<count { face(faceClass) }
    }

    func blink(_ faceClass: UnlockFaceClass) {
        for eyes in blinkEyes { face(faceClass, eyes: eyes) }
    }

    func noFace(for duration: TimeInterval) {
        let end = now + duration
        while now < end {
            now += frameInterval
            gate.observeNoFace(at: now)
        }
    }
}

@main
struct UnlockGateSelfTest {
    @MainActor
    static func main() {
        testLivenessIsBoundToTheMatchingFace()
        testLightModeWaitsForDenyCues()
        testMatchesMustBeConsecutive()
        testFaceGaps()
        testWrongFace()
        testFrameFreshnessAndClassification()
        testAttention()
        testHeadTurnChallenge()
        testAttemptLimiter()
        testSessionExpiry()
        testInjectionPlan()

        guard failureCount == 0 else {
            print("\n\(failureCount) unlock gate self-test(s) FAILED.")
            exit(1)
        }
        print("\nAll unlock gate self-tests passed.")
    }

    @MainActor
    private static func testLivenessIsBoundToTheMatchingFace() {
        let attack = Scan(mode: .heavy)
        attack.blink(.impostor)
        attack.faces(.match, count: 10)
        check(!attack.everUnlocked, "Heavy: an impostor's blink can't vouch for a photo of the owner")

        let owner = Scan(mode: .heavy)
        owner.blink(.match)
        owner.faces(.match, count: 3)
        check(owner.everUnlocked, "Heavy: the owner's own blink unlocks")

        let turning = Scan(mode: .heavy)
        turning.blink(.plausibleOwner)
        turning.faces(.match, count: 3)
        check(turning.everUnlocked, "Heavy: a blink below the match threshold still counts if it is plausibly the owner")

        let swapped = Scan(mode: .heavy)
        swapped.blink(.plausibleOwner)
        swapped.face(.impostor)
        swapped.faces(.match, count: 10)
        check(!swapped.everUnlocked, "Heavy: an impostor frame discards earlier confirmation")

        let photo = Scan(mode: .heavy)
        photo.faces(.match, count: 40)
        check(!photo.everUnlocked, "Heavy: a matching face with no proof of life never unlocks")
    }

    @MainActor
    private static func testLightModeWaitsForDenyCues() {
        let policyMinimum = LivenessTuning.default.lightModeMinimumFrames

        let early = Scan(mode: .light)
        early.faces(.match, count: policyMinimum - 1)
        check(!early.everUnlocked, "Light: no unlock before the minimum observation window")
        early.face(.match)
        check(early.everUnlocked, "Light: unlocks once the window completes")

        let lateDeny = Scan(mode: .light)
        lateDeny.faces(.match, count: 4)
        for _ in 0..<LivenessTuning.default.deviceFrames { lateDeny.face(.match, device: 0.5) }
        check(!lateDeny.everUnlocked, "Light: a deny cue that starts after the first frames still blocks")
        check(lateDeny.last == .spoof(reason: LivenessDecision.denied(by: .deviceDetected).denialReason), "Light: reports the spoof")

        let deniedByStranger = Scan(mode: .heavy)
        for _ in 0..<LivenessTuning.default.deviceFrames { deniedByStranger.face(.impostor, device: 0.5) }
        if case .spoof = deniedByStranger.last {
            check(true, "Deny cues still run on non-matching faces")
        } else {
            check(false, "Deny cues still run on non-matching faces")
        }
    }

    @MainActor
    private static func testMatchesMustBeConsecutive() {
        let single = Scan(mode: nil)
        single.face(.match)
        check(!single.everUnlocked, "Liveness off: one frame can't unlock")
        single.face(.match)
        check(!single.everUnlocked, "Liveness off: two frames can't unlock")
        single.face(.match)
        check(single.everUnlocked, "Liveness off: three consecutive frames unlock")

        let broken = Scan(mode: nil)
        broken.faces(.match, count: 2)
        broken.face(.plausibleOwner)
        broken.faces(.match, count: 2)
        check(!broken.everUnlocked, "A non-match restarts the consecutive count")
    }

    @MainActor
    private static func testFaceGaps() {
        let dropout = Scan(mode: nil)
        dropout.faces(.match, count: 2)
        dropout.noFace(for: 0.1)
        dropout.face(.match)
        check(dropout.everUnlocked, "A brief detection dropout keeps the consecutive count")

        let longGap = Scan(mode: nil)
        longGap.faces(.match, count: 2)
        longGap.noFace(for: 1.0)
        longGap.face(.match)
        check(!longGap.everUnlocked, "A long absence restarts the consecutive count")

        let leftAfterBlink = Scan(mode: .heavy)
        leftAfterBlink.blink(.plausibleOwner)
        leftAfterBlink.noFace(for: 1.0)
        leftAfterBlink.faces(.match, count: 10)
        check(!leftAfterBlink.everUnlocked, "A long absence discards earlier proof of life")
    }

    @MainActor
    private static func testWrongFace() {
        let framesPastGrace = Int(UnlockGatePolicy.standard.wrongFaceGrace / frameInterval) + 2

        let stranger = Scan(mode: .light)
        stranger.faces(.impostor, count: framesPastGrace)
        check(stranger.last == .wrongFace, "A sustained wrong face fails the scan")

        let earlyLookAway = Scan(mode: .light)
        earlyLookAway.faces(.impostor, count: 5)
        check(earlyLookAway.last == .keepScanning, "A brief non-match keeps scanning")
    }

    @MainActor
    private static func testFrameFreshnessAndClassification() {
        let policy = UnlockGatePolicy.standard
        check(policy.isFresh(capturedAt: start, now: start + 0.1), "A recent frame is fresh")
        check(!policy.isFresh(capturedAt: start, now: start + 3600), "A frame from an earlier scan is stale")

        check(policy.classify(isMatch: true, bestSimilarity: 0.7) == .match, "A match classifies as a match")
        check(policy.classify(isMatch: false, bestSimilarity: 0.5) == .plausibleOwner, "Between floor and threshold is plausible")
        check(policy.classify(isMatch: false, bestSimilarity: 0.2) == .impostor, "Below the floor is an impostor")
        check(policy.classify(isMatch: false, bestSimilarity: nil) == .impostor, "No comparable identity is an impostor")
        check(policy.plausibleOwnerFloor < 0.58, "The plausible floor sits below every selectable threshold")
    }

    @MainActor
    private static func testAttention() {
        var policy = UnlockGatePolicy.standard
        policy.requiresAttention = true

        func frame(yaw: Float? = 0, pitch: Float? = 0, eyes: CGFloat? = 0.3, at time: Date) -> LivenessFrame {
            LivenessFrame(
                timestamp: time, landmarks: [], interocularDistance: nil, yaw: yaw,
                leftEyeAspectRatio: eyes, rightEyeAspectRatio: eyes, noseOffsetRatio: nil,
                hasReliableLandmarks: false, deviceOverlapFraction: nil, pitch: pitch
            )
        }

        check(policy.isAttentive(frame(at: start)), "Open eyes facing the screen are attentive")
        check(!policy.isAttentive(frame(eyes: 0.05, at: start)), "Closed eyes are not attentive")
        check(!policy.isAttentive(frame(yaw: 0.6, at: start)), "Looking away sideways is not attentive")
        check(!policy.isAttentive(frame(pitch: 0.6, at: start)), "Looking down is not attentive")
        check(!policy.isAttentive(frame(yaw: nil, at: start)), "Unknown head pose is not attentive")
        check(!policy.isAttentive(frame(eyes: nil, at: start)), "Unknown eye state is not attentive")

        func feed(_ gate: UnlockGate, eyes: CGFloat, count: Int, from first: Int) -> UnlockGate.Decision {
            var decision = UnlockGate.Decision.keepScanning
            for index in first..<(first + count) {
                let time = start + Double(index) * frameInterval
                decision = gate.observeFace(.match, frame: frame(eyes: eyes, at: time), at: time)
            }
            return decision
        }

        let asleep = UnlockGate(policy: policy, liveness: nil)
        check(feed(asleep, eyes: 0.05, count: 30, from: 0) == .keepScanning, "A matching face with closed eyes never unlocks")

        let attentive = UnlockGate(policy: policy, liveness: nil)
        check(feed(attentive, eyes: 0.3, count: 3, from: 0) == .unlock(confirmedBy: nil), "A matching attentive face unlocks")

        let interrupted = UnlockGate(policy: policy, liveness: nil)
        _ = feed(interrupted, eyes: 0.3, count: 2, from: 0)
        _ = feed(interrupted, eyes: 0.05, count: 1, from: 2)
        check(feed(interrupted, eyes: 0.3, count: 2, from: 3) == .keepScanning, "Looking away restarts the consecutive count")
        check(feed(interrupted, eyes: 0.3, count: 1, from: 5) == .unlock(confirmedBy: nil), "Attention must hold for the full count")
    }

    @MainActor
    private static func testHeadTurnChallenge() {
        var left = HeadTurnChallenge(direction: .left)
        left.observe(yaw: 0)
        left.observe(yaw: -0.3)
        check(!left.isComplete, "Turning the wrong way doesn't complete the challenge")
        left.observe(yaw: 0.12)
        check(left.progress == 0.5, "Progress follows the turn")
        left.observe(yaw: 0)
        check(left.progress == 0.5, "Progress doesn't go backward")
        left.observe(yaw: 0.3)
        check(left.isComplete, "Turning far enough completes the challenge")

        var right = HeadTurnChallenge(direction: .right)
        right.observe(yaw: 0)
        right.observe(yaw: -0.3)
        check(right.isComplete, "A right turn uses negative yaw")

        var alreadyTurned = HeadTurnChallenge(direction: .left)
        alreadyTurned.observe(yaw: 0.4)
        alreadyTurned.observe(yaw: 0.5)
        check(!alreadyTurned.isComplete, "A head already turned the right way proves nothing")

        var unknown = HeadTurnChallenge(direction: .left)
        unknown.observe(yaw: nil)
        check(unknown.progress == 0, "Unknown head pose doesn't count")

        func frame(_ yaw: Float, eyes: CGFloat = 0.3, at time: Date) -> LivenessFrame {
            LivenessFrame(
                timestamp: time, landmarks: [], interocularDistance: nil, yaw: yaw,
                leftEyeAspectRatio: eyes, rightEyeAspectRatio: eyes, noseOffsetRatio: nil,
                hasReliableLandmarks: false, deviceOverlapFraction: nil
            )
        }

        func makeGate() -> UnlockGate {
            let analyzer = LivenessAnalyzer()
            analyzer.modeProvider = { .challenge }
            return UnlockGate(liveness: analyzer, challenge: HeadTurnChallenge(direction: .left))
        }

        var clock = start
        func feed(_ gate: UnlockGate, _ faceClass: UnlockFaceClass, yaw: Float, eyes: [CGFloat]) -> UnlockGate.Decision {
            var decision = UnlockGate.Decision.keepScanning
            for openness in eyes {
                clock += frameInterval
                decision = gate.observeFace(faceClass, frame: frame(yaw, eyes: openness, at: clock), at: clock)
                if case .unlock = decision { return decision }
            }
            return decision
        }
        let open: [CGFloat] = [0.3, 0.3, 0.3]

        let blinkOnly = makeGate()
        check(feed(blinkOnly, .match, yaw: 0, eyes: blinkEyes + open + open) == .keepScanning, "A blink alone can't pass the challenge")

        let passes = makeGate()
        _ = feed(passes, .match, yaw: 0, eyes: blinkEyes)
        _ = feed(passes, .plausibleOwner, yaw: 0.3, eyes: open)
        check(feed(passes, .match, yaw: 0, eyes: open) == .unlock(confirmedBy: .blink), "Proof of life, the turn, and a match unlock")

        let turnOnly = makeGate()
        _ = feed(turnOnly, .match, yaw: 0, eyes: open)
        _ = feed(turnOnly, .match, yaw: 0.3, eyes: open)
        check(feed(turnOnly, .match, yaw: 0, eyes: open + open) == .keepScanning, "The turn alone isn't proof of life")

        let swapped = makeGate()
        _ = feed(swapped, .match, yaw: 0, eyes: blinkEyes)
        _ = feed(swapped, .plausibleOwner, yaw: 0.3, eyes: open)
        _ = feed(swapped, .impostor, yaw: 0, eyes: [0.3])
        check(swapped.challenge?.progress == 0, "A different face resets the challenge")
        check(feed(swapped, .match, yaw: 0, eyes: open + open) == .keepScanning, "A different face must not inherit a completed turn")
    }

    @MainActor
    private static func testAttemptLimiter() {
        var limiter = UnlockAttemptLimiter()
        for _ in 0..<(limiter.maxFailures - 1) { limiter.recordFailure() }
        check(!limiter.isLockedOut, "Attempts remain below the limit")
        limiter.recordFailure()
        check(limiter.isLockedOut, "Reaching the limit locks face unlock out")
        limiter.reset()
        check(!limiter.isLockedOut, "A real unlock clears the lockout")
    }

    @MainActor
    private static func testSessionExpiry() {
        let day: TimeInterval = 86_400
        check(!SessionExpiry.isExpired(startedAt: start, limit: day, now: start + day - 1), "Session is valid inside its limit")
        check(SessionExpiry.isExpired(startedAt: start, limit: day, now: start + day), "Session expires at its limit")
        check(!SessionExpiry.isExpired(startedAt: start, limit: nil, now: start + 1_000 * day), "Never does not expire")
    }

    @MainActor
    private static func testInjectionPlan() {
        let ascii = [UInt16](repeating: 65, count: 45)
        let steps = InjectionPlan.steps(utf16: ascii, maxBatchLength: 20)
        check(steps == [.clearField, .text(0..<20), .text(20..<40), .text(40..<45), .pressReturn], "Password is batched between field clear and Return")

        var pair = [UInt16](repeating: 65, count: 19)
        pair += Array("😀".utf16)
        let pairSteps = InjectionPlan.steps(utf16: pair, maxBatchLength: 20)
        check(pairSteps == [.clearField, .text(0..<19), .text(19..<21), .pressReturn], "A surrogate pair is never split")

        var performed: [InjectionStep] = []
        var remainingLockedChecks = 2
        var aborted = false
        do {
            try InjectionPlan.run(steps, isStillLocked: {
                defer { remainingLockedChecks -= 1 }
                return remainingLockedChecks > 0
            }, perform: { performed.append($0) })
        } catch {
            aborted = error is InjectionAborted
        }
        check(aborted, "Unlocking during entry aborts it")
        check(performed == [.clearField, .text(0..<20)], "No keystrokes are sent after the screen unlocks")
        check(!performed.contains(.pressReturn), "Return is never pressed after an abort")

        var notLocked: [InjectionStep] = []
        try? InjectionPlan.run(steps, isStillLocked: { false }, perform: { notLocked.append($0) })
        check(notLocked.isEmpty, "Nothing is sent, not even the field clear, if the screen isn't locked")
    }
}
