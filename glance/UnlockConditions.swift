//
//  UnlockConditions.swift
//  glance
//
//  Extra requirements a user can place on face unlock, plus one-tap security presets. No system-framework
//  dependencies, so `tools/unlock_conditions_selftest.swift` can drive it directly.
//

import Foundation

enum UnmetUnlockCondition: Equatable {
    case untrustedNetwork
    case bluetoothDeviceMissing
    case outsideAllowedHours

    var detail: String {
        switch self {
        case .untrustedNetwork: return "This isn't one of your trusted networks."
        case .bluetoothDeviceMissing: return "Your trusted Bluetooth device isn't connected."
        case .outsideAllowedHours: return "It's outside your allowed hours."
        }
    }
}

struct UnlockConditions: Codable, Equatable {
    var requiresTrustedNetwork = false
    var trustedNetworks: [String] = []

    var requiresBluetoothDevice = false
    var bluetoothAddress: String?
    var bluetoothName: String?

    var requiresSchedule = false
    /// Minutes after midnight. A start later than the end means the window runs overnight.
    var startMinute = 8 * 60
    var endMinute = 20 * 60
    var weekdaysOnly = false

    /// Fails closed: a requirement that can't be confirmed, such as an unreadable network name, counts as unmet.
    func firstUnmet(
        now: Date,
        calendar: Calendar,
        networkName: String?,
        isBluetoothConnected: Bool
    ) -> UnmetUnlockCondition? {
        if requiresTrustedNetwork {
            guard let networkName, trustedNetworks.contains(networkName) else { return .untrustedNetwork }
        }
        if requiresBluetoothDevice, !isBluetoothConnected {
            return .bluetoothDeviceMissing
        }
        if requiresSchedule, !isWithinSchedule(now: now, calendar: calendar) {
            return .outsideAllowedHours
        }
        return nil
    }

    private func isWithinSchedule(now: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let isOvernight = startMinute > endMinute
        let isInWindow = isOvernight
            ? minute >= startMinute || minute < endMinute
            : minute >= startMinute && minute < endMinute
        guard isInWindow else { return false }
        guard weekdaysOnly else { return true }

        // After midnight, an overnight window still belongs to the day it started on.
        let startedYesterday = isOvernight && minute < endMinute
        let startDay = startedYesterday ? calendar.date(byAdding: .day, value: -1, to: now) ?? now : now
        return !calendar.isDateInWeekend(startDay)
    }
}

enum SecurityLevel: String, CaseIterable, Identifiable {
    case convenience
    case balanced
    case strict

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convenience: return "Convenient"
        case .balanced: return "Balanced"
        case .strict: return "Strict"
        }
    }

    var symbol: String {
        switch self {
        case .convenience: return "bolt.fill"
        case .balanced: return "shield.lefthalf.filled"
        case .strict: return "lock.shield.fill"
        }
    }

    var livenessMode: LivenessMode {
        switch self {
        case .convenience: return .light
        case .balanced: return .heavy
        case .strict: return .challenge
        }
    }

    var requiresAttention: Bool { self != .convenience }

    var sessionLimitDays: Int {
        switch self {
        case .convenience: return 30
        case .balanced: return 2
        case .strict: return 1
        }
    }

    /// `nil` means the user's settings don't line up with any preset.
    static func matching(
        livenessEnabled: Bool,
        livenessMode: LivenessMode,
        requiresAttention: Bool,
        sessionLimitDays: Int
    ) -> SecurityLevel? {
        guard livenessEnabled else { return nil }
        return allCases.first {
            $0.livenessMode == livenessMode
                && $0.requiresAttention == requiresAttention
                && $0.sessionLimitDays == sessionLimitDays
        }
    }
}
