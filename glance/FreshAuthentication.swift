//
//  FreshAuthentication.swift
//  glance
//
//  Like Face ID requiring the passcode to enroll a face: an unlocked session isn't enough to weaken security, so
//  sensitive changes ask for Touch ID or the Mac password again.
//

import Foundation
import LocalAuthentication
import Observation

@Observable
@MainActor
final class FreshAuthentication {
    static let shared = FreshAuthentication()

    /// Long enough to change several settings without repeated prompts.
    private static let window: Duration = .seconds(120)

    private(set) var isAuthorized = false
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// Returns true once the user has authenticated within the last two minutes.
    func require(reason: String) async -> Bool {
        if isAuthorized { return true }
        let context = LAContext()
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else {
            return false
        }
        isAuthorized = true
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.window)
            guard !Task.isCancelled else { return }
            self?.isAuthorized = false
        }
        return true
    }
}
