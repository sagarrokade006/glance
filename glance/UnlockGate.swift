//
//  UnlockGate.swift
//  glance
//
//  The decisions that lead to typing the Mac password, with no camera, Vision, or AppKit dependency, so
//  `tools/unlock_gate_selftest.swift` can drive the real logic frame by frame with a fake clock.
//

import Foundation

/// How one detected face compares against the enrolled identities.
enum UnlockFaceClass: Equatable {
    /// Cleared the user's match threshold.
    case match
    /// Below the threshold but close enough to be the owner mid-blink or mid-head-turn. Can't unlock, but doesn't
    /// discard liveness evidence either.
    case plausibleOwner
    /// Clearly someone else. Liveness evidence from this face must never help a later match.
    case impostor
}

struct UnlockGatePolicy: Equatable {
    /// Consecutive matching frames needed, so one frame can never unlock on its own.
    var requiredConsecutiveMatches = 3
    /// ArcFace cosine similarity at or above which a non-matching face may still be the owner. Sits at the top of
    /// ArcFace's usual different-person cutoffs (~0.28-0.40) and below every selectable match threshold.
    var plausibleOwnerFloor: Float = 0.40
    /// Longest face-detection dropout that still counts as the same continuous presentation.
    var maxFaceGap: TimeInterval = 0.5
    /// A wake often catches the owner looking away, so only a sustained non-match fails the scan.
    var wrongFaceGrace: TimeInterval = 2
    /// Frames older than this are ignored, so nothing from an earlier moment can be scored as current.
    var maxFrameAge: TimeInterval = 0.5
    /// When on, a match only counts while the eyes are open and the face is turned toward the screen.
    var requiresAttention = false
    /// About 20 degrees, in radians, matching Vision's head-pose units.
    var maxAttentiveYaw: Float = 0.35
    var maxAttentivePitch: Float = 0.35
    /// Height-to-width ratio of the eye outline. Set low because Vision never fully collapses a closed eye.
    var minEyeOpenness: CGFloat = 0.17

    static let standard = UnlockGatePolicy()

    /// Unknown measurements count as not attentive, so missing landmarks can't satisfy the check.
    func isAttentive(_ frame: LivenessFrame) -> Bool {
        guard let yaw = frame.yaw,
              let leftEye = frame.leftEyeAspectRatio,
              let rightEye = frame.rightEyeAspectRatio,
              abs(yaw) <= maxAttentiveYaw,
              leftEye >= minEyeOpenness,
              rightEye >= minEyeOpenness
        else { return false }
        if let pitch = frame.pitch, abs(pitch) > maxAttentivePitch { return false }
        return true
    }

    func classify(isMatch: Bool, bestSimilarity: Float?) -> UnlockFaceClass {
        if isMatch { return .match }
        guard let bestSimilarity, bestSimilarity >= plausibleOwnerFloor else { return .impostor }
        return .plausibleOwner
    }

    func isFresh(capturedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(capturedAt) <= maxFrameAge
    }
}

enum HeadTurnDirection: CaseIterable, Equatable {
    case left
    case right

    var prompt: String { self == .left ? "Slowly turn left" : "Slowly turn right" }
    var symbol: String { self == .left ? "arrow.left" : "arrow.right" }
    /// Vision reports positive yaw for a head turned toward the left of the screen.
    var yawSign: Float { self == .left ? 1 : -1 }
}

/// A random head-turn prompt, which a prerecorded video can't anticipate.
struct HeadTurnChallenge: Equatable {
    /// Matches the band enrollment already asks users to reach, about 14 degrees.
    static let requiredTurn: Float = 0.24
    /// The turn must start from here, so a head already turned the right way proves nothing.
    static let centerLimit: Float = 0.12

    let direction: HeadTurnDirection
    private(set) var progress: Float = 0
    private var sawCenter = false

    init(direction: HeadTurnDirection) {
        self.direction = direction
    }

    var isComplete: Bool { progress >= 1 }

    mutating func observe(yaw: Float?) {
        guard !isComplete, let yaw else { return }
        let turn = yaw * direction.yawSign
        if turn <= Self.centerLimit { sawCenter = true }
        guard sawCenter else { return }
        progress = max(progress, min(1, max(0, turn / Self.requiredTurn)))
    }

    mutating func reset() {
        progress = 0
        sawCenter = false
    }
}

/// Binds recognition and liveness to one continuous presentation of the owner's face. One instance per scan.
@MainActor
final class UnlockGate {
    enum Decision: Equatable {
        case keepScanning
        /// `confirmedBy` is nil when liveness is off or Light mode confirmed without a specific cue.
        case unlock(confirmedBy: LivenessCue?)
        case wrongFace
        case spoof(reason: String?)
    }

    let policy: UnlockGatePolicy
    /// `nil` when the user has switched liveness off.
    private let liveness: LivenessAnalyzer?

    private var matchStreak = 0
    private var wrongFaceStartedAt: Date?
    private var lastFaceAt: Date?
    /// `nil` unless the head-turn challenge is in use.
    private(set) var challenge: HeadTurnChallenge?

    init(policy: UnlockGatePolicy = .standard, liveness: LivenessAnalyzer?, challenge: HeadTurnChallenge? = nil) {
        self.policy = policy
        self.liveness = liveness
        self.challenge = challenge
    }

    /// Call for each processed frame in which no usable face was found.
    func observeNoFace(at now: Date) {
        wrongFaceStartedAt = nil
        breakContinuityIfGapExceeded(now)
    }

    /// Call for each processed frame with a face. Deny cues see every face, including non-matching ones, so a
    /// spoof tell can't be waited out. Confirmation accrues only from faces that could be the owner.
    func observeFace(_ faceClass: UnlockFaceClass, frame: LivenessFrame, at now: Date) -> Decision {
        breakContinuityIfGapExceeded(now)
        lastFaceAt = now

        if faceClass == .impostor {
            challenge?.reset()
        } else {
            challenge?.observe(yaw: frame.yaw)
        }

        var isLive = liveness == nil
        var confirmingCue: LivenessCue?
        if let liveness {
            let snapshot = liveness.observe(frame, countsTowardConfirmation: faceClass != .impostor)
            switch snapshot.decision {
            case .denied:
                return .spoof(reason: snapshot.decision.denialReason)
            case .confirmed(let cue):
                isLive = true
                confirmingCue = cue
            case .pending:
                break
            }
        }

        guard faceClass == .match else {
            matchStreak = 0
            let startedAt = wrongFaceStartedAt ?? now
            wrongFaceStartedAt = startedAt
            return now.timeIntervalSince(startedAt) >= policy.wrongFaceGrace ? .wrongFace : .keepScanning
        }

        wrongFaceStartedAt = nil
        guard !policy.requiresAttention || policy.isAttentive(frame) else {
            matchStreak = 0
            return .keepScanning
        }
        matchStreak += 1
        guard matchStreak >= policy.requiredConsecutiveMatches, isLive, challenge?.isComplete != false else {
            return .keepScanning
        }
        return .unlock(confirmedBy: confirmingCue)
    }

    private func breakContinuityIfGapExceeded(_ now: Date) {
        guard let lastFaceAt, now.timeIntervalSince(lastFaceAt) > policy.maxFaceGap else { return }
        matchStreak = 0
        liveness?.resetConfirmation()
        challenge?.reset()
    }
}

/// Stops an unlimited stream of spoof attempts at one lock screen.
struct UnlockAttemptLimiter: Equatable {
    var maxFailures = 5
    private(set) var failures = 0

    var isLockedOut: Bool { failures >= maxFailures }

    mutating func recordFailure() { failures += 1 }
    /// Call only after the Mac was genuinely unlocked.
    mutating func reset() { failures = 0 }
}

enum SessionExpiry {
    /// `limit` is measured from the Touch ID unlock and is not extended by use. `nil` means "Never".
    static func isExpired(startedAt: Date, limit: TimeInterval?, now: Date) -> Bool {
        guard let limit else { return false }
        return now.timeIntervalSince(startedAt) >= limit
    }
}

// MARK: - Password entry sequencing

nonisolated enum InjectionStep: Equatable {
    case clearField
    case text(Range<Int>)
    case pressReturn
}

nonisolated struct InjectionAborted: LocalizedError {
    var errorDescription: String? { "The screen was no longer locked, so password entry stopped." }
}

nonisolated enum InjectionPlan {
    /// Batches UTF-16 units without ever splitting a surrogate pair.
    static func steps(utf16: [UInt16], maxBatchLength: Int) -> [InjectionStep] {
        var steps: [InjectionStep] = [.clearField]
        var start = 0
        while start < utf16.count {
            var end = min(start + maxBatchLength, utf16.count)
            if end < utf16.count, (0xD800...0xDBFF).contains(utf16[end - 1]), end - start > 1 {
                end -= 1
            }
            steps.append(.text(start..<end))
            start = end
        }
        steps.append(.pressReturn)
        return steps
    }

    /// Re-checks before every step, so the field clear, each password batch, and Return can't land in an app that
    /// took focus after the screen unlocked.
    static func run(
        _ steps: [InjectionStep],
        isStillLocked: () -> Bool,
        perform: (InjectionStep) throws -> Void
    ) throws {
        for step in steps {
            guard isStillLocked() else { throw InjectionAborted() }
            try perform(step)
        }
    }
}
