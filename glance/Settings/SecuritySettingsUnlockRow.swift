//
//  SecuritySettingsUnlockRow.swift
//  glance
//

import SwiftUI

struct SecuritySettingsUnlockRow: View {
    var body: some View {
        SettingsGroup {
            SettingsRowContent(
                title: "Security settings are locked",
                subtitle: "Authenticate to change how face unlock works.",
                subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
            ) {
                SettingsPrimaryButton(title: "Unlock", compact: true) {
                    Task {
                        _ = await FreshAuthentication.shared.require(reason: "change Glance security settings")
                    }
                }
            }
        }
    }
}
