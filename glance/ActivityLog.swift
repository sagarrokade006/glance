//
//  ActivityLog.swift
//  glance
//
//  History of face unlock attempts. Text only: no images or face data. No dependencies, so
//  `tools/activity_log_selftest.swift` can compile it alone. `ActivityStore` handles encryption and storage.
//

import Foundation

enum ActivityKind: String, Codable, Equatable {
    case unlocked
    case notRecognized
    case spoofSuspected
    case passwordEntryFailed
    case passwordRejected
    case paused
    case securitySettingsRestored

    var title: String {
        switch self {
        case .unlocked: return "Unlocked"
        case .notRecognized: return "Face not recognized"
        case .spoofSuspected: return "Possible spoof"
        case .passwordEntryFailed: return "Couldn't enter password"
        case .passwordRejected: return "Password not accepted"
        case .paused: return "Face unlock paused"
        case .securitySettingsRestored: return "Security settings restored"
        }
    }

    /// Whether this is an attempt by someone or something that didn't get in.
    var isFailedAttempt: Bool {
        self == .notRecognized || self == .spoofSuspected
    }
}

struct ActivityEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let kind: ActivityKind
    let detail: String?
}

struct ActivityAwaySummary: Equatable {
    let failedAttempts: Int
    let earliest: Date
    let latest: Date
}

struct ActivityLog: Codable, Equatable {
    static let capacity = 200

    /// Newest first.
    private(set) var events: [ActivityEvent] = []

    mutating func append(_ kind: ActivityKind, detail: String? = nil, at date: Date) {
        events.insert(ActivityEvent(id: UUID(), date: date, kind: kind, detail: detail), at: 0)
        if events.count > Self.capacity {
            events.removeLast(events.count - Self.capacity)
        }
    }

    /// Failed attempts since the unlock before the most recent one, so they're still visible after you get back in.
    var awaySummary: ActivityAwaySummary? {
        let afterLatestUnlock = events.first?.kind == .unlocked ? events.dropFirst() : events[...]
        let attempts = afterLatestUnlock
            .prefix { $0.kind != .unlocked }
            .filter(\.kind.isFailedAttempt)
        guard let latest = attempts.first?.date, let earliest = attempts.last?.date else { return nil }
        return ActivityAwaySummary(failedAttempts: attempts.count, earliest: earliest, latest: latest)
    }
}
