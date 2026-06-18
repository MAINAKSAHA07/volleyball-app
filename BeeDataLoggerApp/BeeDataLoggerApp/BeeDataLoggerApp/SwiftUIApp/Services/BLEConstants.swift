//
//  BLEConstants.swift
//  BeeDataLoggerApp
//
//  Central place for BLE UUIDs. Replace with your actual ESP32 service/characteristic UUIDs.
//

import Foundation
import CoreBluetooth

enum BLEConstants {

    // MARK: - Service UUID
    /// Main service UUID advertised by the Bee Data Logger (BDL) device.
    /// Replace with your actual service UUID from ESP32.
    static let serviceUUID = CBUUID(string: "0000180D-0000-1000-8000-00805F9B34FB") // placeholder; use e.g. "12345678-1234-1234-1234-123456789ABC"

    // MARK: - Characteristic UUIDs
    /// Notify characteristic for real-time sensor stream (CSV: epoch_ms,fsr1..fsr5).
    static let notifyCharacteristicUUID = CBUUID(string: "00002A37-0000-1000-8000-00805F9B34FB") // placeholder

    /// Optional: write characteristic for commands (e.g. start/stop logging).
    /// Set to nil if your device has no write characteristic.
    static let writeCharacteristicUUID: CBUUID? = CBUUID(string: "00002A38-0000-1000-8000-00805F9B34FB") // placeholder; use nil if not needed

    // MARK: - Device name prefix (for preferring BDL-01, BDL-02)
    static let preferredDeviceNamePrefix = "BDL"
}
