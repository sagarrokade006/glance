//
//  password_health_selftest.swift
//  glance (tools)
//
//      swiftc -O -o /tmp/password_health_selftest glance/PasswordHealth.swift tools/password_health_selftest.swift \
//      && /tmp/password_health_selftest
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

private let now = Date(timeIntervalSinceReferenceDate: 1_000)

@main
struct PasswordHealthSelfTest {
    @MainActor
    static func main() async {
        testClassification()
        testHealthTransitions()
        testPersistence()
        await testConfirmation()

        guard failureCount == 0 else {
            print("\n\(failureCount) password health self-test(s) FAILED.")
            exit(1)
        }
        print("\nAll password health self-tests passed.")
    }

    private static func testClassification() {
        check(PasswordVerification.classify(errorCode: 5000) == .rejected, "A wrong password is a rejection")
        check(PasswordVerification.classify(errorCode: 5304) == .unavailable, "A temporarily locked account isn't a rejection")
        check(PasswordVerification.classify(errorCode: 2100) == .unavailable, "A lookup failure isn't a rejection")
    }

    private static func testHealthTransitions() {
        var health = PasswordHealth()
        health.recordEntryStillLocked()
        check(!health.isStale, "One failed entry doesn't pause face unlock")
        health.recordEntryConfirmed(at: now)
        check(health.consecutiveFailedEntries == 0, "A successful unlock clears the failure count")
        check(health.lastSuccessfulUnlockAt == now, "A successful unlock is recorded")

        health.recordEntryStillLocked()
        health.recordEntryStillLocked()
        check(health.isStale, "Two failed entries in a row pause face unlock")

        health.apply(.unavailable, at: now)
        check(health.isStale, "An inconclusive check doesn't clear a stale password")
        health.apply(.verified, at: now)
        check(!health.isStale && health.lastVerifiedAt == now, "A verified check clears a stale password")

        health.apply(.rejected, at: now)
        check(health.isStale, "A rejected check marks the password stale immediately")
        health.recordPasswordSaved(.unavailable, at: now)
        check(!health.isStale && health.lastVerifiedAt == nil, "A new unverified password starts clean but not verified")
        health.recordPasswordSaved(.verified, at: now)
        check(health.lastVerifiedAt == now, "A new verified password records the time")
    }

    @MainActor
    private static func testPersistence() {
        let suite = "glance.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return check(false, "Test defaults exist") }
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PasswordHealthStore(defaults: defaults)
        store.health.apply(.rejected, at: now)
        check(PasswordHealthStore(defaults: defaults).health.isStale, "A stale password survives a relaunch")
    }

    @MainActor
    private static func testConfirmation() async {
        var polls = 0
        let unlocksLater = await UnlockConfirmer.wait(
            isLocked: { polls += 1; return polls < 4 },
            isSleeping: { false },
            sleep: { _ in }
        )
        check(unlocksLater == .unlocked, "An unlock during the wait is confirmed")

        let neverUnlocks = await UnlockConfirmer.wait(isLocked: { true }, isSleeping: { false }, sleep: { _ in })
        check(neverUnlocks == .stillLocked, "Staying locked for the whole wait is reported")

        let slept = await UnlockConfirmer.wait(isLocked: { true }, isSleeping: { true }, sleep: { _ in })
        check(slept == .inconclusive, "Going to sleep while waiting proves nothing")
    }
}
