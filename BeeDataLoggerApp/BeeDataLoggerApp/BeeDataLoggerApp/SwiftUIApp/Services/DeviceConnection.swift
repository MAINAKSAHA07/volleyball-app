//
//  DeviceConnection.swift
//  BeeDataLoggerApp
//
//  Wraps a single BLE peripheral: connection state, discovery, notify subscription,
//  and latest sensor reading. Used by BLEManager to manage up to 2 devices.
//

import Foundation
import CoreBluetooth
import Combine

/// Connection state for one peripheral
enum DeviceConnectionState: Equatable {
    case disconnected
    case connecting
    case discovering
    case connected
    case failed(String)
}

/// Represents one BLE device session: peripheral, state, and latest data.
final class DeviceConnection: ObservableObject {
    let peripheral: CBPeripheral
    let identifier: String

    @Published private(set) var name: String
    @Published private(set) var state: DeviceConnectionState = .disconnected
    @Published private(set) var rssi: Int?
    @Published private(set) var lastReading: SensorReading?
    @Published private(set) var lastUpdated: Date?
    /// Recent readings for future charting (e.g. last 100)
    @Published private(set) var readingHistory: [SensorReading] = []
    private let historyLimit = 100

    /// Callback for connection state changes
    var onStateChanged: ((DeviceConnectionState) -> Void)?

    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?

    init(peripheral: CBPeripheral, name: String?, rssi: Int?) {
        self.peripheral = peripheral
        self.identifier = peripheral.identifier.uuidString
        self.name = name ?? peripheral.name ?? "Unknown"
        self.rssi = rssi
    }

    func updateRSSI(_ rssi: Int) {
        self.rssi = rssi
    }

    func updateName(_ name: String?) {
        if let n = name, !n.isEmpty { self.name = n }
    }

    func setState(_ newState: DeviceConnectionState) {
        state = newState
        onStateChanged?(newState)
    }

    /// Called when a sensor reading is parsed (from BLEManager)
    func didReceiveReading(_ reading: SensorReading) {
        lastReading = reading
        lastUpdated = reading.receivedAt
        readingHistory.append(reading)
        if readingHistory.count > historyLimit {
            readingHistory.removeFirst(readingHistory.count - historyLimit)
        }
    }

    /// Called when services/characteristics are discovered
    func didDiscover(service: CBService, characteristics: [CBCharacteristic]) {
        for char in characteristics {
            if char.uuid == BLEConstants.notifyCharacteristicUUID {
                notifyCharacteristic = char
            }
            if let writeUUID = BLEConstants.writeCharacteristicUUID, char.uuid == writeUUID {
                writeCharacteristic = char
            }
        }
    }

    func getNotifyCharacteristic() -> CBCharacteristic? { notifyCharacteristic }
    func getWriteCharacteristic() -> CBCharacteristic? { writeCharacteristic }

    func clearHistory() {
        readingHistory.removeAll()
    }
}
