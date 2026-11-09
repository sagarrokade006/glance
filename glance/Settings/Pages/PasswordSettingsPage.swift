//
//  PasswordSettingsPage.swift
//  glance
//

import SwiftUI

struct PasswordSettingsPage: View {
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared
    private var health: PasswordHealth { PasswordHealthStore.shared.health }

    @State private var isUnlocking = false
    @State private var sessionError: String?
    @State private var statusMessage: String?

    /// Read from `POCController`, not a local copy — `SessionAutoLocker` can
    /// lock the session from outside this view.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    /// "No password stored" takes priority over lock state entirely, so
    /// removal doesn't fall back to an "unlock session" prompt for a
    /// session that no longer protects anything.
    private enum PageState: Equatable {
        case noPassword
        case locked
        case unlocked
    }

    private var pageState: PageState {
        guard pocController.hasStoredPassword else { return .noPassword }
        return isSessionUnlocked ? .unlocked : .locked
    }

    var body: some View {
        ZStack(alignment: .top) {
            noPasswordState
                .opacity(pageState == .noPassword ? 1 : 0)
                // Hidden from hit-testing and accessibility while faded out.
                .allowsHitTesting(pageState == .noPassword)
                .accessibilityHidden(pageState != .noPassword)

            lockedState
                .opacity(pageState == .locked ? 1 : 0)
                .allowsHitTesting(pageState == .locked)
                .accessibilityHidden(pageState != .locked)

            unlockedState
                .opacity(pageState == .unlocked ? 1 : 0)
                .allowsHitTesting(pageState == .unlocked)
                .accessibilityHidden(pageState != .unlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: pageState)
        .onAppear {
            pocController.refreshCredentialStatus()
            pocController.refreshAccessibilityStatus()
        }
        // The onboarding password step runs in the notch, outside this
        // view's hierarchy, so nothing else prompts a re-check once it closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
            FaceEnrollmentStore.shared.reloadIfUnlocked()
        }
    }

    // MARK: - No password stored

    private var noPasswordState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Set up a password",
            buttonTitle: "Set password",
            caption: statusMessage,
            action: { OnboardingController.startPasswordOnly() }
        )
    }

    // MARK: - Locked

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Session locked",
            buttonTitle: isUnlocking ? "Authenticating…" : "Unlock session",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            if health.isStale {
                staleWarning
            }

            SettingsGroup {
                SettingsRowContent(title: "Password encrypted") {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                }

                SettingsGroupDivider()

                SettingsSteppedSliderRowContent(
                    title: "Auto lock session",
                    valueLabel: settings.autoLockInterval.title,
                    index: Binding(
                        get: { settings.autoLockInterval.sliderIndex },
                        set: { settings.autoLockInterval = .from(sliderIndex: $0) }
                    ),
                    stopCount: AutoLockInterval.allCases.count
                )

                SettingsGroupDivider()

                SettingsRowContent(title: "Change password") {
                    SettingsPrimaryButton(title: "Change", compact: true) {
                        OnboardingController.startPasswordOnly()
                    }
                }

                SettingsGroupDivider()

                SettingsRowContent(title: "Remove password") {
                    HoldToConfirmButton(title: "Remove", action: removePassword)
                }
            }

            if let statusMessage {
                SettingsCaption(text: statusMessage)
            }

            SettingsSectionTitle(text: "Password health")
            SettingsGroup {
                SettingsRowContent(title: "Last verified with macOS") {
                    healthValue(formatted(health.lastVerifiedAt, fallback: "Not verified"))
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "Last successful unlock") {
                    healthValue(formatted(health.lastSuccessfulUnlockAt, fallback: "Not yet"))
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "Accessibility permission") {
                    Image(systemName: pocController.accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(pocController.accessibilityGranted ? .green : .red)
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "Session re-locks in") {
                    healthValue(sessionTimeRemaining)
                }
                if !health.isStale {
                    SettingsGroupDivider()
                    checkPasswordRow
                }
            }
        }
    }

    private var staleWarning: some View {
        SettingsGroup {
            SettingsRowContent(
                title: "Stored password looks out of date",
                subtitle: "macOS didn't accept it. Face unlock is paused to avoid failed login attempts.",
                subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
            ) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            SettingsGroupDivider()
            SettingsRowContent(title: "Update password") {
                SettingsPrimaryButton(title: "Update", compact: true) {
                    OnboardingController.startPasswordOnly()
                }
            }
            SettingsGroupDivider()
            checkPasswordRow
        }
    }

    private var checkPasswordRow: some View {
        SettingsActionRowContent(
            title: "Check stored password",
            buttonTitle: pocController.isCheckingPassword ? "Checking…" : "Check",
            isEnabled: !pocController.isCheckingPassword
        ) {
            Task { await pocController.checkStoredPassword() }
        }
    }

    private func healthValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(SettingsMetrics.textSecondary)
    }

    private func formatted(_ date: Date?, fallback: String) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? fallback
    }

    private var sessionTimeRemaining: String {
        guard let limit = settings.autoLockInterval.duration,
              let startedAt = SecureCredentialManager.sessionStartedAt
        else { return "Never" }
        let hours = max(0, Int((limit - Date().timeIntervalSince(startedAt)) / 3600))
        if hours >= 48 { return "\(hours / 24) days" }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    // MARK: - Actions

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            // Face store is encrypted under the same session key, so reload
            // it now rather than leaving Your Face stuck showing "locked".
            FaceEnrollmentStore.shared.reloadIfUnlocked()
            isUnlocking = false
        }
    }

    /// Face samples must be deleted before the password/session key —
    /// `deletePassword()` clears the cached session key, and deleting the
    /// face store requires an unlocked session.
    private func removePassword() {
        do {
            FaceEnrollmentStore.shared.deleteAll()
            try SecureCredentialManager.deletePassword()
            pocController.refreshCredentialStatus()
            statusMessage = "Password and face enrollment removed."
        } catch {
            statusMessage = "Couldn't remove: \(error.localizedDescription)"
        }
    }
}
