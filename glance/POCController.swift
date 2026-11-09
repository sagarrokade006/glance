//
//  POCController.swift
//  glance
//
//  Orchestration for credential storage: wires SecureCredentialManager to
//  KeystrokeInjector and exposes session/password status for Settings.
//

import Foundation
import Observation

enum PasswordEntryResult {
    /// The password and Return were sent. Whether macOS accepted them is checked separately.
    case typed
    /// The screen was already unlocked, so nothing needed typing.
    case notNeeded
    case failed
}

@Observable
@MainActor
final class POCController {
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var sessionError: String? = nil
    private(set) var isCheckingPassword = false

    /// Bound to the setup SecureField. Cleared immediately after a successful save.
    var passwordInput: String = ""

    var statusMessage: String = "Idle"

    func refreshAccessibilityStatus() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    func refreshCredentialStatus() {
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
    }

    // MARK: - Session (Touch ID gate)

    /// Must succeed before `savePassword()` or `injectStoredPassword()` will do anything.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "Authenticate to set up or use glance")
            }.value
            isSessionUnlocked = true
            // Catches a password changed while Glance wasn't running, before it's typed at the lock screen. Skipped once
            // stale, since each wrong check counts as a failed login.
            if hasStoredPassword, !PasswordHealthStore.shared.health.isStale {
                Task { await checkStoredPassword() }
            }
        } catch {
            isSessionUnlocked = false
            sessionError = error.localizedDescription
        }
    }

    /// Asks macOS whether the stored password still works. Requires an unlocked session.
    func checkStoredPassword() async {
        guard SecureCredentialManager.isSessionUnlocked, !isCheckingPassword else { return }
        isCheckingPassword = true
        defer { isCheckingPassword = false }
        let verification = await Task.detached(priority: .userInitiated) { () -> PasswordVerification in
            guard var bytes = try? SecureCredentialManager.readPassword() else { return .unavailable }
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            guard let password = String(data: bytes, encoding: .utf8) else { return .unavailable }
            return PasswordVerifier.verify(password)
        }.value
        PasswordHealthStore.shared.health.apply(verification, at: Date())
    }

    func lockSession() {
        SecureCredentialManager.lockSession()
        isSessionUnlocked = false
    }

    /// Locks the session if it has outlived the user's limit. Returns true if the session is now expired.
    @discardableResult
    func lockSessionIfExpired() -> Bool {
        guard let startedAt = SecureCredentialManager.sessionStartedAt,
              SessionExpiry.isExpired(
                startedAt: startedAt,
                limit: GlanceSettings.shared.autoLockInterval.duration,
                now: Date()
              )
        else { return false }
        lockSession()
        return true
    }

    // MARK: - Setup flow

    /// Encrypts and stores `passwordInput`. Requires the session to already
    /// be unlocked (Touch ID happens in `unlockSession()`, not here).
    func savePassword() async {
        guard !passwordInput.isEmpty else {
            statusMessage = "Enter a password first."
            return
        }
        let plaintext = passwordInput
        passwordInput = ""

        do {
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = plaintext.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            statusMessage = "Password saved and encrypted."
            hasStoredPassword = true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Injection

    /// Reads + decrypts + injects the stored password, zeroing the plaintext
    /// buffer before returning. When `requireAuthoritativeLock` is true (the
    /// auto-trigger path), refuses to inject unless the CGSession dictionary
    /// confirms the screen is actually locked.
    @discardableResult
    func injectStoredPassword(requireAuthoritativeLock: Bool = false) async -> PasswordEntryResult {
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "Accessibility not granted — open System Settings and enable glance."
            return .failed
        }
        // Checked at the point of use: the periodic timer and wake check can both lag behind the deadline.
        guard !lockSessionIfExpired(), SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Session locked — authenticate with Touch ID first."
            return .failed
        }
        guard !PasswordHealthStore.shared.health.isStale else {
            statusMessage = "Stored password looks out of date — update it in Settings."
            return .failed
        }

        if requireAuthoritativeLock {
            guard LockMonitor.isScreenActuallyLocked() else {
                statusMessage = "Skipped: CGSession reports screen is not actually locked."
                return .notNeeded
            }
        }

        statusMessage = "Injecting…"
        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try KeystrokeInjector.typeAndReturn(bytes) {
                    !requireAuthoritativeLock || LockMonitor.isScreenActuallyLocked()
                }
            }.value
            statusMessage = "Injected stored password + Return at \(Date().formatted(date: .omitted, time: .standard))"
            return .typed
        } catch is InjectionAborted {
            statusMessage = "Stopped typing: the screen is no longer locked."
            return .notNeeded
        } catch {
            statusMessage = "Injection failed: \(error.localizedDescription)"
            return .failed
        }
    }
}
