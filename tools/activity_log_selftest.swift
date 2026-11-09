//
//  activity_log_selftest.swift
//  glance (tools)
//
//      swiftc -O -o /tmp/activity_log_selftest glance/ActivityLog.swift tools/activity_log_selftest.swift \
//      && /tmp/activity_log_selftest
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

private func time(_ offset: Int) -> Date { Date(timeIntervalSinceReferenceDate: TimeInterval(offset)) }

@main
struct ActivityLogSelfTest {
    static func main() {
        var log = ActivityLog()
        log.append(.unlocked, detail: "Alex", at: time(1))
        log.append(.notRecognized, at: time(2))
        check(log.events.first?.kind == .notRecognized, "Newest events come first")

        var capped = ActivityLog()
        for index in 0..<(ActivityLog.capacity + 25) { capped.append(.notRecognized, at: time(index)) }
        check(capped.events.count == ActivityLog.capacity, "History is capped")
        check(capped.events.first?.date == time(ActivityLog.capacity + 24), "The cap drops the oldest events")

        let encoded = try? JSONEncoder().encode(log)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(ActivityLog.self, from: $0) }
        check(decoded == log, "History survives encoding")

        check(ActivityLog().awaySummary == nil, "An empty history has no summary")

        var quiet = ActivityLog()
        quiet.append(.unlocked, at: time(1))
        quiet.append(.unlocked, at: time(2))
        check(quiet.awaySummary == nil, "Nothing to report between successful unlocks")

        var away = ActivityLog()
        away.append(.unlocked, at: time(1))
        away.append(.notRecognized, at: time(5))
        away.append(.spoofSuspected, at: time(6))
        away.append(.paused, at: time(7))
        away.append(.unlocked, at: time(9))
        check(
            away.awaySummary == ActivityAwaySummary(failedAttempts: 2, earliest: time(5), latest: time(6)),
            "Failures before the latest unlock are summarized, and pauses aren't counted as attempts"
        )

        var ongoing = ActivityLog()
        ongoing.append(.unlocked, at: time(1))
        ongoing.append(.notRecognized, at: time(5))
        check(ongoing.awaySummary?.failedAttempts == 1, "Failures after the latest unlock are summarized")

        var older = ActivityLog()
        older.append(.notRecognized, at: time(1))
        older.append(.unlocked, at: time(2))
        older.append(.notRecognized, at: time(3))
        older.append(.unlocked, at: time(4))
        check(older.awaySummary?.failedAttempts == 1, "Failures from earlier absences aren't included")

        guard failureCount == 0 else {
            print("\n\(failureCount) activity log self-test(s) FAILED.")
            exit(1)
        }
        print("\nAll activity log self-tests passed.")
    }
}
