//
//  ActivityStore.swift
//  glance
//
//  Keeps the activity log encrypted under the same Touch-ID-gated session key as enrolled faces.
//

import Foundation
import Observation

@Observable
@MainActor
final class ActivityStore {
    static let shared = ActivityStore()

    private(set) var log = ActivityLog()

    @ObservationIgnored private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("glance", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("activity.enc")
    }()

    private init() {
        reload()
        NotificationCenter.default.addObserver(
            forName: .secureCredentialSessionDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    /// Drops the history from memory when the session locks. A file that can't be read just starts a fresh history.
    private func reload() {
        guard SecureCredentialManager.isSessionUnlocked,
              let ciphertext = try? Data(contentsOf: fileURL),
              let plaintext = try? SecureCredentialManager.decrypt(ciphertext),
              let decoded = try? JSONDecoder().decode(ActivityLog.self, from: plaintext)
        else {
            log = ActivityLog()
            return
        }
        log = decoded
    }

    func record(_ kind: ActivityKind, detail: String? = nil) {
        log.append(kind, detail: detail, at: Date())
        persist()
    }

    func clear() {
        log = ActivityLog()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Failing to save a history entry must never get in the way of unlocking.
    private func persist() {
        guard let plaintext = try? JSONEncoder().encode(log),
              let ciphertext = try? SecureCredentialManager.encrypt(plaintext)
        else { return }
        try? ciphertext.write(to: fileURL, options: .atomic)
    }
}
