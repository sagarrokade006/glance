//
//  ActivitySettingsPage.swift
//  glance
//

import SwiftUI

struct ActivitySettingsPage: View {
    @Bindable var pocController: POCController

    @State private var isUnlocking = false
    @State private var sessionError: String?

    private var log: ActivityLog { ActivityStore.shared.log }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(pocController.isSessionUnlocked ? 0 : 1)
                .allowsHitTesting(!pocController.isSessionUnlocked)
                .accessibilityHidden(pocController.isSessionUnlocked)

            unlockedState
                .opacity(pocController.isSessionUnlocked ? 1 : 0)
                .allowsHitTesting(pocController.isSessionUnlocked)
                .accessibilityHidden(!pocController.isSessionUnlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: pocController.isSessionUnlocked)
        .onAppear { pocController.refreshCredentialStatus() }
    }

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

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            if let summary = log.awaySummary {
                SettingsSectionTitle(text: "While you were away")
                SettingsGroup {
                    SettingsRowContent(
                        title: summary.failedAttempts == 1 ? "1 failed attempt" : "\(summary.failedAttempts) failed attempts",
                        subtitle: "Most recent: \(formatted(summary.latest)). No images are stored.",
                        subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                    ) {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(.orange)
                    }
                }
            }

            SettingsSectionTitle(text: "Recent activity")
            SettingsGroup {
                if log.events.isEmpty {
                    SettingsRowContent(title: "No activity yet") { EmptyView() }
                } else {
                    ForEach(Array(log.events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { SettingsGroupDivider() }
                        row(event)
                    }
                }
            }

            if !log.events.isEmpty {
                SettingsGroup {
                    SettingsRowContent(title: "Clear history") {
                        HoldToConfirmButton(title: "Clear") { ActivityStore.shared.clear() }
                    }
                }
            }
        }
    }

    private func row(_ event: ActivityEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: event.kind))
                .foregroundStyle(color(for: event.kind))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.kind.title)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                if let detail = event.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(formatted(event.date))
                .font(.system(size: 11))
                .foregroundStyle(SettingsMetrics.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func symbol(for kind: ActivityKind) -> String {
        switch kind {
        case .unlocked: return "checkmark.circle.fill"
        case .notRecognized: return "person.fill.questionmark"
        case .spoofSuspected: return "xmark.circle.fill"
        case .passwordEntryFailed, .passwordRejected: return "key.fill"
        case .paused: return "pause.circle.fill"
        case .securitySettingsRestored: return "exclamationmark.shield.fill"
        }
    }

    private func color(for kind: ActivityKind) -> Color {
        switch kind {
        case .unlocked: return .green
        case .notRecognized, .spoofSuspected: return .red
        case .passwordEntryFailed, .passwordRejected, .paused, .securitySettingsRestored: return .orange
        }
    }

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }
}
