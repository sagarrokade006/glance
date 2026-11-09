//
//  SessionAutoLocker.swift
//  glance
//
//  Enforces `GlanceSettings.autoLockInterval`: re-locks the session once it is older than the user's chosen limit.
//

import Foundation
import AppKit

@MainActor
final class SessionAutoLocker {
    private let pocController: POCController
    private var timer: Timer?

    /// Coarse on purpose — the shortest selectable limit is a full day, and the decision compares timestamps, not ticks.
    private let checkInterval: TimeInterval = 5 * 60

    init(pocController: POCController) {
        self.pocController = pocController
        // `.common` so the countdown keeps being checked during tracking runloop modes (an open menu, a drag).
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Also evaluate on wake: no timer fires during sleep, but the elapsed time still counts once compared.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }

        evaluate()
    }

    deinit {
        timer?.invalidate()
    }

    /// Routed through `POCController` rather than `SecureCredentialManager` directly, so the Settings UI's
    /// `isSessionUnlocked` flag doesn't go stale. A "Never" preference still loses the in-memory session key on
    /// app relaunch; it only disables this limit while Glance runs.
    func evaluate() {
        pocController.lockSessionIfExpired()
    }
}
