//
//  SecurityPolicy.swift
//  glance
//
//  Detects security settings changed outside the app, and decides which cameras may be trusted. No app dependencies
//  beyond `UnlockConditions`, so `tools/unlock_conditions_selftest.swift` can compile it.
//

import CryptoKit
import Foundation

/// Every setting that affects how hard it is to unlock the Mac. Bump `version` when adding a field, or an update would
/// look like tampering.
struct SecurityPolicySnapshot: Codable, Equatable {
    var version = 1
    var matchThreshold: Float
    var minimumFaceWidth: Float
    var livenessEnabled: Bool
    var livenessMode: String
    var requiresAttention: Bool
    var autoLockDays: Int
    var conditions: UnlockConditions

    fileprivate var canonicalData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }
}

enum SecurityPolicySeal {
    static func seal(_ snapshot: SecurityPolicySnapshot, key: SymmetricKey) -> Data? {
        guard let data = snapshot.canonicalData else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func isValid(_ seal: Data, for snapshot: SecurityPolicySnapshot, key: SymmetricKey) -> Bool {
        guard let data = snapshot.canonicalData else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(seal, authenticating: data, using: key)
    }
}

/// A virtual camera can feed prerecorded video straight into recognition, past every liveness check, so only
/// cameras backed by real hardware are allowed.
enum CameraTrust {
    private static let trustedTransports: Set<UInt32> = [
        fourCharacterCode("usb "),
        fourCharacterCode("thun"),
        fourCharacterCode("pci "),
    ]

    static func allows(isBuiltIn: Bool, isContinuityCamera: Bool, transportType: Int32) -> Bool {
        isBuiltIn || isContinuityCamera || trustedTransports.contains(UInt32(bitPattern: transportType))
    }

    static func fourCharacterCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

enum SecuritySettingLimits {
    static let matchThreshold: ClosedRange<Float> = 0.60...0.80
    static let minimumFaceWidth: ClosedRange<Float> = 0.10...0.50

    static func clamped(_ value: Float, to range: ClosedRange<Float>) -> Float {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
