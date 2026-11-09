//
//  unlock_conditions_selftest.swift
//  glance (tools)
//
//      swiftc -O -o /tmp/unlock_conditions_selftest \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Liveness/GeometryLiveness.swift \
//        glance/Liveness/GlareCue.swift \
//        glance/Liveness/LivenessCues.swift \
//        glance/Liveness/LivenessScoring.swift \
//        glance/UnlockConditions.swift \
//        tools/unlock_conditions_selftest.swift \
//      && /tmp/unlock_conditions_selftest
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

private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar
}()

/// 2 November 2026 is a Monday.
private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? Date()
}

private func unmet(
    _ conditions: UnlockConditions,
    at now: Date = date(day: 2, hour: 12),
    network: String? = nil,
    bluetooth: Bool = false
) -> UnmetUnlockCondition? {
    conditions.firstUnmet(now: now, calendar: calendar, networkName: network, isBluetoothConnected: bluetooth)
}

@main
struct UnlockConditionsSelfTest {
    static func main() {
        check(unmet(UnlockConditions()) == nil, "No conditions means nothing is unmet")

        var network = UnlockConditions()
        network.requiresTrustedNetwork = true
        check(unmet(network, network: "Home") == .untrustedNetwork, "An empty trusted list fails closed")
        network.trustedNetworks = ["Home"]
        check(unmet(network, network: "Home") == nil, "A trusted network passes")
        check(unmet(network, network: "Cafe") == .untrustedNetwork, "An untrusted network fails")
        check(unmet(network, network: nil) == .untrustedNetwork, "An unreadable network name fails closed")

        var bluetooth = UnlockConditions()
        bluetooth.requiresBluetoothDevice = true
        check(unmet(bluetooth, bluetooth: true) == nil, "A connected device passes")
        check(unmet(bluetooth, bluetooth: false) == .bluetoothDeviceMissing, "A missing device fails")

        var hours = UnlockConditions()
        hours.requiresSchedule = true
        hours.startMinute = 8 * 60
        hours.endMinute = 20 * 60
        check(unmet(hours, at: date(day: 2, hour: 8)) == nil, "The start time is inside the window")
        check(unmet(hours, at: date(day: 2, hour: 20)) == .outsideAllowedHours, "The end time is outside the window")
        check(unmet(hours, at: date(day: 2, hour: 7, minute: 59)) == .outsideAllowedHours, "Before the window fails")

        var weekdays = hours
        weekdays.weekdaysOnly = true
        check(unmet(weekdays, at: date(day: 6, hour: 12)) == nil, "Friday passes weekdays only")
        check(unmet(weekdays, at: date(day: 7, hour: 12)) == .outsideAllowedHours, "Saturday fails weekdays only")

        var overnight = UnlockConditions()
        overnight.requiresSchedule = true
        overnight.startMinute = 22 * 60
        overnight.endMinute = 6 * 60
        check(unmet(overnight, at: date(day: 2, hour: 23)) == nil, "Overnight passes before midnight")
        check(unmet(overnight, at: date(day: 3, hour: 5)) == nil, "Overnight passes after midnight")
        check(unmet(overnight, at: date(day: 3, hour: 12)) == .outsideAllowedHours, "Overnight fails at midday")

        overnight.weekdaysOnly = true
        check(unmet(overnight, at: date(day: 7, hour: 1)) == nil, "Early Saturday still belongs to Friday night")
        check(unmet(overnight, at: date(day: 2, hour: 1)) == .outsideAllowedHours, "Early Monday belongs to Sunday night")

        var multiple = network
        multiple.requiresBluetoothDevice = true
        check(unmet(multiple, network: "Home", bluetooth: false) == .bluetoothDeviceMissing, "Every condition must hold")

        let decoded = (try? JSONEncoder().encode(hours)).flatMap { try? JSONDecoder().decode(UnlockConditions.self, from: $0) }
        check(decoded == hours, "Conditions survive saving")

        for level in SecurityLevel.allCases {
            let match = SecurityLevel.matching(
                livenessEnabled: true,
                livenessMode: level.livenessMode,
                requiresAttention: level.requiresAttention,
                sessionLimitDays: level.sessionLimitDays
            )
            check(match == level, "\(level.title) is recognized from its own settings")
        }
        check(
            SecurityLevel.matching(livenessEnabled: false, livenessMode: .heavy, requiresAttention: true, sessionLimitDays: 7) == nil,
            "Liveness off is never a preset"
        )
        check(
            SecurityLevel.matching(livenessEnabled: true, livenessMode: .heavy, requiresAttention: false, sessionLimitDays: 7) == nil,
            "Mixed settings are custom"
        )

        guard failureCount == 0 else {
            print("\n\(failureCount) unlock conditions self-test(s) FAILED.")
            exit(1)
        }
        print("\nAll unlock conditions self-tests passed.")
    }
}
