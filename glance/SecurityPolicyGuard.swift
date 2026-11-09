//
//  SecurityPolicyGuard.swift
//  glance
//
//  Settings live in UserDefaults, which any process running as this user can rewrite. The seal is keyed from the
//  Touch-ID-gated session key, so a change made outside Glance is caught the next time the session unlocks.
//

import CryptoKit
import Foundation

@MainActor
final class SecurityPolicyGuard {
    static let shared = SecurityPolicyGuard()

    /// Until the stored settings are verified, resealing would bless whatever is currently on disk.
    private var isVerified = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: .secureCredentialSessionDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if SecureCredentialManager.isSessionUnlocked {
                    self.verifyIfNeeded()
                } else {
                    self.isVerified = false
                }
            }
        }
    }

    func verifyIfNeeded() {
        guard !isVerified, let key = SecureCredentialManager.derivedPolicyKey() else { return }
        let settings = GlanceSettings.shared
        do {
            let stored = try KeychainManager.read(account: SecureCredentialManager.policySealAccount)
            isVerified = true
            guard !SecurityPolicySeal.isValid(stored, for: settings.securitySnapshot, key: key) else { return }
            settings.restoreSecureDefaults()
            ActivityStore.shared.record(.securitySettingsRestored, detail: "They were changed outside Glance.")
            writeSeal(key: key)
        } catch KeychainError.itemNotFound {
            // First run with this feature: there's nothing to compare against yet.
            isVerified = true
            writeSeal(key: key)
        } catch {
            // Leave unverified and try again at the next check, rather than treating a Keychain hiccup as tampering.
        }
    }

    /// Call after any in-app change to a security setting.
    func sealCurrentSettings() {
        guard isVerified, let key = SecureCredentialManager.derivedPolicyKey() else { return }
        writeSeal(key: key)
    }

    private func writeSeal(key: SymmetricKey) {
        guard let seal = SecurityPolicySeal.seal(GlanceSettings.shared.securitySnapshot, key: key) else { return }
        try? KeychainManager.save(account: SecureCredentialManager.policySealAccount, data: seal)
    }
}
