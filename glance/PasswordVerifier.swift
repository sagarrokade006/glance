//
//  PasswordVerifier.swift
//  glance
//
//  Asks macOS whether a password is correct for the current user. A wrong guess counts as a failed login attempt,
//  so call this only when there's a real reason to check, never on a timer.
//

import Foundation
import OpenDirectory

nonisolated enum PasswordVerifier {
    /// Blocking; call from a background task.
    static func verify(_ password: String) -> PasswordVerification {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return .verified
        } catch {
            let nsError = error as NSError
            guard nsError.domain == (kODErrorDomainFramework as String?) else { return .unavailable }
            return PasswordVerification.classify(errorCode: nsError.code)
        }
    }
}
