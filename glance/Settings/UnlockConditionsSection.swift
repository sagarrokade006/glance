//
//  UnlockConditionsSection.swift
//  glance
//
//  Security presets and the "Only unlock when" conditions on the Recognition page.
//

import SwiftUI

struct SecurityLevelSection: View {
    @Bindable private var settings = GlanceSettings.shared

    private var currentLevel: SecurityLevel? {
        SecurityLevel.matching(
            livenessEnabled: settings.livenessChecksEnabled,
            livenessMode: settings.livenessMode,
            requiresAttention: settings.requiresAttention,
            sessionLimitDays: settings.autoLockInterval.rawValue
        )
    }

    var body: some View {
        SettingsGroup {
            SettingsLabeledOptionRow(
                title: "Security level",
                subtitle: currentLevel == nil ? "Custom settings" : "Sets liveness, attention, and session length."
            ) {
                ForEach(SecurityLevel.allCases) { level in
                    SettingsOptionTile(
                        title: level.title,
                        isSelected: currentLevel == level,
                        action: { apply(level) },
                        previewHeight: SettingsMetrics.triggerOptionPreviewSize.height,
                        previewWidth: SettingsMetrics.triggerOptionPreviewSize.width
                    ) {
                        Image(systemName: level.symbol)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(SettingsOptionTile<EmptyView>.previewTint(isSelected: currentLevel == level))
                    }
                }
            }
        }
    }

    private func apply(_ level: SecurityLevel) {
        settings.livenessChecksEnabled = true
        settings.livenessMode = level.livenessMode
        settings.requiresAttention = level.requiresAttention
        if let interval = AutoLockInterval(rawValue: level.sessionLimitDays) {
            settings.autoLockInterval = interval
        }
    }
}

struct UnlockConditionsSection: View {
    @Bindable private var settings = GlanceSettings.shared

    @State private var bluetoothDevices: [TrustedBluetoothDevice] = []
    @State private var networkMessage: String?

    private var environment: TrustedEnvironment { TrustedEnvironment.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Only unlock when")
            SettingsGroup {
                networkRows
                SettingsGroupDivider()
                bluetoothRows
                SettingsGroupDivider()
                scheduleRows
            }
            if let networkMessage {
                SettingsCaption(text: networkMessage)
            }
        }
        .onAppear(perform: loadBluetoothDevicesIfNeeded)
        .onChange(of: settings.unlockConditions.requiresBluetoothDevice) { _, _ in
            loadBluetoothDevicesIfNeeded()
        }
    }

    // MARK: - Network

    @ViewBuilder
    private var networkRows: some View {
        SettingsRowContent(
            title: "On a trusted network",
            subtitle: networkSummary,
            subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
        ) {
            GlanceToggle(isOn: $settings.unlockConditions.requiresTrustedNetwork)
        }
        if settings.unlockConditions.requiresTrustedNetwork {
            SettingsGroupDivider()
            SettingsActionRowContent(title: "Current Wi-Fi network", buttonTitle: "Add", action: addCurrentNetwork)
            if !settings.unlockConditions.trustedNetworks.isEmpty {
                SettingsGroupDivider()
                SettingsActionRowContent(title: "Trusted networks", buttonTitle: "Clear", isDestructive: true) {
                    settings.unlockConditions.trustedNetworks = []
                }
            }
        }
    }

    private var networkSummary: String {
        let networks = settings.unlockConditions.trustedNetworks
        return networks.isEmpty ? "No networks added" : networks.joined(separator: ", ")
    }

    private func addCurrentNetwork() {
        guard environment.hasLocationAccess else {
            environment.requestLocationAccess()
            networkMessage = "macOS only shares Wi-Fi names with apps that have Location access. Allow it, then tap Add again."
            return
        }
        guard let name = environment.currentNetworkName() else {
            networkMessage = "Glance couldn't read a Wi-Fi network name. Check that Wi-Fi is connected."
            return
        }
        networkMessage = nil
        if !settings.unlockConditions.trustedNetworks.contains(name) {
            settings.unlockConditions.trustedNetworks.append(name)
        }
    }

    // MARK: - Bluetooth

    @ViewBuilder
    private var bluetoothRows: some View {
        SettingsRowContent(
            title: "A Bluetooth device is connected",
            subtitle: "A photo of you isn't enough without it.",
            subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
        ) {
            GlanceToggle(isOn: $settings.unlockConditions.requiresBluetoothDevice)
        }
        if settings.unlockConditions.requiresBluetoothDevice {
            SettingsGroupDivider()
            SettingsRowContent(title: "Device") {
                SettingsMenuPickerPill(label: settings.unlockConditions.bluetoothName ?? "Choose") {
                    ForEach(bluetoothDevices) { device in
                        Button(device.name) {
                            settings.unlockConditions.bluetoothAddress = device.address
                            settings.unlockConditions.bluetoothName = device.name
                        }
                    }
                }
            }
        }
    }

    private func loadBluetoothDevicesIfNeeded() {
        guard settings.unlockConditions.requiresBluetoothDevice else { return }
        bluetoothDevices = environment.pairedBluetoothDevices()
    }

    // MARK: - Schedule

    @ViewBuilder
    private var scheduleRows: some View {
        SettingsRowContent(title: "Within set hours") {
            GlanceToggle(isOn: $settings.unlockConditions.requiresSchedule)
        }
        if settings.unlockConditions.requiresSchedule {
            SettingsGroupDivider()
            SettingsRowContent(title: "From") { timePicker($settings.unlockConditions.startMinute) }
            SettingsGroupDivider()
            SettingsRowContent(title: "Until") { timePicker($settings.unlockConditions.endMinute) }
            SettingsGroupDivider()
            SettingsRowContent(title: "Weekdays only") {
                GlanceToggle(isOn: $settings.unlockConditions.weekdaysOnly)
            }
        }
    }

    private func timePicker(_ minutes: Binding<Int>) -> some View {
        DatePicker(
            "",
            selection: Binding(
                get: {
                    Calendar.current.date(
                        bySettingHour: minutes.wrappedValue / 60,
                        minute: minutes.wrappedValue % 60,
                        second: 0,
                        of: Date()
                    ) ?? Date()
                },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
    }
}
