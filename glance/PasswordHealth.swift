//
//  PasswordHealth.swift
//  glance
//
//  Tracks whether the stored Mac password still works, so an out-of-date password isn't typed at the lock screen
//  again and again. No AppKit or OpenDirectory dependency, so `tools/password_health_selftest.swift` can compile it.
//

import Foundation
import Observation

nonisolated enum PasswordVerification: Equatable {
    case verified
    case rejected
    /// macOS couldn't give an answer, which says nothing about the password itself.
    case unavailable

    /// `kODErrorCredentialsInvalid`. Other credential errors (locked account, expired password) don't prove the
    /// password is wrong, so they are deliberately not treated as a rejection.
    static let credentialsInvalidCode = 5000

    static func classify(errorCode: Int) -> PasswordVerification {
        errorCode == credentialsInvalidCode ? .rejected : .unavailable
    }
}

struct PasswordHealth: Codable, Equatable {
    /// Two, not one: a single unlock can stay locked for unrelated reasons, such as the field not having focus yet.
    static let failedEntriesBeforeStale = 2

    private(set) var lastVerifiedAt: Date?
    private(set) var lastSuccessfulUnlockAt: Date?
    private(set) var consecutiveFailedEntries = 0
    /// While true, Glance won't type the stored password.
    private(set) var isStale = false

    mutating func apply(_ verification: PasswordVerification, at now: Date) {
        switch verification {
        case .verified:
            lastVerifiedAt = now
            consecutiveFailedEntries = 0
            isStale = false
        case .rejected:
            isStale = true
        case .unavailable:
            break
        }
    }

    /// A newly saved password starts clean. `verification` is never `.rejected` here, since rejected passwords aren't saved.
    mutating func recordPasswordSaved(_ verification: PasswordVerification, at now: Date) {
        lastVerifiedAt = verification == .verified ? now : nil
        consecutiveFailedEntries = 0
        isStale = false
    }

    mutating func recordEntryConfirmed(at now: Date) {
        lastSuccessfulUnlockAt = now
        consecutiveFailedEntries = 0
        isStale = false
    }

    mutating func recordEntryStillLocked() {
        consecutiveFailedEntries += 1
        if consecutiveFailedEntries >= Self.failedEntriesBeforeStale {
            isStale = true
        }
    }
}

@Observable
@MainActor
final class PasswordHealthStore {
    static let shared = PasswordHealthStore()

    private static let key = "GlanceSettings.passwordHealth"

    @ObservationIgnored private let defaults: UserDefaults

    var health: PasswordHealth {
        didSet {
            if let data = try? JSONEncoder().encode(health) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        health = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(PasswordHealth.self, from: $0) }
            ?? PasswordHealth()
    }
}

enum UnlockConfirmation: Equatable {
    case unlocked
    case stillLocked
    /// The Mac went to sleep while waiting, so the result says nothing about the password.
    case inconclusive
}

enum UnlockConfirmer {
    static let timeout: TimeInterval = 5
    static let pollInterval: TimeInterval = 0.1

    /// Waits to see whether the password Glance just typed actually unlocked the Mac.
    @MainActor
    static func wait(
        timeout: TimeInterval = timeout,
        pollInterval: TimeInterval = pollInterval,
        isLocked: () -> Bool,
        isSleeping: () -> Bool,
        sleep: (TimeInterval) async -> Void
    ) async -> UnlockConfirmation {
        for _ in 0..<Int(timeout / pollInterval) {
            if !isLocked() { return .unlocked }
            if isSleeping() { return .inconclusive }
            await sleep(pollInterval)
        }
        return isLocked() ? .stillLocked : .unlocked
    }
}
