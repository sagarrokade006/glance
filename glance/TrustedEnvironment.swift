//
//  TrustedEnvironment.swift
//  glance
//
//  Reads the Wi-Fi network and Bluetooth devices used by `UnlockConditions`. macOS only reveals Wi-Fi names
//  to apps with Location access, and a Bluetooth lookup prompts for access, so nothing here runs until a user turns on the matching condition.
//

import CoreLocation
import CoreWLAN
import Foundation
import IOBluetooth

struct TrustedBluetoothDevice: Identifiable, Equatable {
    let name: String
    let address: String

    var id: String { address }
}

@MainActor
final class TrustedEnvironment {
    static let shared = TrustedEnvironment()

    private let locationManager = CLLocationManager()

    var hasLocationAccess: Bool {
        locationManager.authorizationStatus == .authorizedAlways
    }

    func requestLocationAccess() {
        locationManager.requestAlwaysAuthorization()
    }

    func currentNetworkName() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    func pairedBluetoothDevices() -> [TrustedBluetoothDevice] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.compactMap { device in
            guard let address = device.addressString else { return nil }
            return TrustedBluetoothDevice(name: device.name ?? address, address: address)
        }
    }

    func isBluetoothDeviceConnected(address: String) -> Bool {
        IOBluetoothDevice(addressString: address)?.isConnected() ?? false
    }
}
