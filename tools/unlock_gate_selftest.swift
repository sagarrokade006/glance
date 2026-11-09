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
