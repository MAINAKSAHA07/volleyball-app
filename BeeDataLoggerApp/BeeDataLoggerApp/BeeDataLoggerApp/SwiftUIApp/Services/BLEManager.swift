//
//  BLEManager.swift
//  BeeDataLoggerApp
//
//  Central BLE layer: scanning, connecting up to 2 peripherals, service discovery,
//  notify subscription, and parsing. Runs on its own queue; publishes to main for UI.
//

import Foundation
import CoreBluetooth
import Combine

/// BLE manager state
enum BLEManagerState {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

/// Log entry for UI console
struct BLELogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
    let level: Level
    enum Level { case info; case warning; case error }
}

final class BLEManager: NSObject, ObservableObject {
    static let shared = BLEManager()

    private var centralManager: CBCentralManager!
    private let queue = DispatchQueue(label: "com.beedatalogger.ble", qos: .userInitiated)
    private var rssiTimer: Timer?

    @Published private(set) var state: BLEManagerState = .unknown
    @Published private(set) var isScanning = false
    /// Discovered peripherals (name, identifier, RSSI) for scan UI
    @Published private(set) var discoveredPeripherals: [ScannedPeripheral] = []
    /// Up to 2 active device sessions
    @Published private(set) var device1: DeviceConnection?
    @Published private(set) var device2: DeviceConnection?
    /// Log entries for UI (bounded)
    @Published private(set) var logEntries: [BLELogEntry] = []
    private let logLimit = 200

    /// Scanned device info for list
    struct ScannedPeripheral: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        var identifier: String { id.uuidString }
    }

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: - Logging
    private func log(_ message: String, level: BLELogEntry.Level = .info) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let entry = BLELogEntry(date: Date(), message: message, level: level)
            self.logEntries.append(entry)
            if self.logEntries.count > self.logLimit {
                self.logEntries.removeFirst(self.logEntries.count - self.logLimit)
            }
        }
    }

    // MARK: - Scan
    func startScanning() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.state == .poweredOn else {
                self.log("Cannot scan: Bluetooth not powered on", level: .warning)
                return
            }
            self.discoveredPeripherals = []
            self.centralManager.scanForPeripherals(withServices: [BLEConstants.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            DispatchQueue.main.async { self.isScanning = true }
            self.log("Scanning started")
        }
    }

    func stopScanning() {
        queue.async { [weak self] in
            self?.centralManager.stopScan()
            DispatchQueue.main.async { self?.isScanning = false }
            self?.log("Scanning stopped")
        }
    }

    // MARK: - Connect (select up to 2)
    /// Connect to a peripheral by identifier. If we have fewer than 2 devices, adds as device1 or device2.
    func connect(to peripheral: CBPeripheral, name: String?, rssi: Int?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let session = DeviceConnection(peripheral: peripheral, name: name, rssi: rssi)
            session.onStateChanged = { [weak self] _ in
                self?.objectWillChange.send()
            }

            if self.device1 == nil {
                DispatchQueue.main.async { self.device1 = session }
                self.connectSession(session)
                return
            }
            if self.device2 == nil, session.peripheral.identifier != self.device1?.peripheral.identifier {
                DispatchQueue.main.async { self.device2 = session }
                self.connectSession(session)
                return
            }
            self.log("Already connected to 2 devices", level: .warning)
        }
    }

    /// Connect using scanned info (from ScanViewModel)
    func connectToScanned(id: UUID, name: String, rssi: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let peripheral = self.centralManager.retrievePeripherals(withIdentifiers: [id]).first {
                self.connect(to: peripheral, name: name, rssi: rssi)
            } else {
                self.log("Peripheral not found: \(id)", level: .error)
            }
        }
    }

    private func connectSession(_ session: DeviceConnection) {
        let peripheral = session.peripheral
        peripheral.delegate = self
        session.setState(.connecting)
        log("Connecting to \(session.name)...")
        centralManager.connect(peripheral, options: nil)
    }

    // MARK: - Disconnect / Reconnect
    func disconnect(_ session: DeviceConnection) {
        queue.async { [weak self] in
            self?.centralManager.cancelPeripheralConnection(session.peripheral)
            session.setState(.disconnected)
            self?.log("Disconnected: \(session.name)")
            self?.clearSessionIfNeeded(session)
        }
    }

    func reconnect(_ session: DeviceConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            session.setState(.connecting)
            self.log("Reconnecting to \(session.name)...")
            self.centralManager.connect(session.peripheral, options: nil)
        }
    }

    private func clearSessionIfNeeded(_ session: DeviceConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.device1?.identifier == session.identifier { self.device1 = nil }
            if self.device2?.identifier == session.identifier { self.device2 = nil }
        }
    }

    // MARK: - Data handling (parse off main thread for smooth UI)
    private func handleData(_ data: Data, device: DeviceConnection) {
        let deviceId = device.identifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let reading = SensorDataParser.parse(data, deviceIdentifier: deviceId) else { return }
            DispatchQueue.main.async {
                device.didReceiveReading(reading)
            }
        }
    }

    /// Clear in-memory BLE log (for UI console)
    func clearLog() {
        DispatchQueue.main.async { [weak self] in
            self?.logEntries.removeAll()
        }
    }

    // MARK: - Mock mode (for previews)
    private var useMockData = false
    func setMockMode(_ enabled: Bool) {
        useMockData = enabled
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState: BLEManagerState
        switch central.state {
        case .unknown: newState = .unknown
        case .resetting: newState = .resetting
        case .unsupported: newState = .unsupported
        case .unauthorized: newState = .unauthorized
        case .poweredOff: newState = .poweredOff
        case .poweredOn: newState = .poweredOn
        @unknown default: newState = .unknown
        }
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
        log("Bluetooth state: \(central.state.rawValue)")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unknown"
        let rssi = RSSI.intValue
        let scanned = ScannedPeripheral(id: peripheral.identifier, name: name, rssi: rssi)
        DispatchQueue.main.async { [weak self] in
            self?.updateDiscovered(scanned)
        }
    }

    private func updateDiscovered(_ scanned: ScannedPeripheral) {
        if let idx = discoveredPeripherals.firstIndex(where: { $0.id == scanned.id }) {
            discoveredPeripherals[idx] = scanned
        } else {
            discoveredPeripherals.append(scanned)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let session = self.device1, session.peripheral.identifier == peripheral.identifier {
                session.setState(.discovering)
                peripheral.discoverServices([BLEConstants.serviceUUID])
                self.log("Connected: \(session.name)")
            } else if let session = self.device2, session.peripheral.identifier == peripheral.identifier {
                session.setState(.discovering)
                peripheral.discoverServices([BLEConstants.serviceUUID])
                self.log("Connected: \(session.name)")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription ?? "Unknown"
        DispatchQueue.main.async { [weak self] in
            self?.device1?.peripheral.identifier == peripheral.identifier ? (self?.device1?.setState(.failed(msg))) : ()
            self?.device2?.peripheral.identifier == peripheral.identifier ? (self?.device2?.setState(.failed(msg))) : ()
        }
        log("Failed to connect: \(msg)", level: .error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription ?? "Disconnected"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.device1?.peripheral.identifier == peripheral.identifier {
                self.device1?.setState(.disconnected)
                self.log("Device 1 disconnected: \(msg)")
            } else if self.device2?.peripheral.identifier == peripheral.identifier {
                self.device2?.setState(.disconnected)
                self.log("Device 2 disconnected: \(msg)")
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let err = error {
            DispatchQueue.main.async { [weak self] in
                self?.setFailedFor(peripheral, message: err.localizedDescription)
            }
            log("Service discovery failed: \(err.localizedDescription)", level: .error)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == BLEConstants.serviceUUID }) else {
            DispatchQueue.main.async { [weak self] in
                self?.setFailedFor(peripheral, message: "Service not found")
            }
            log("Service \(BLEConstants.serviceUUID.uuidString) not found", level: .error)
            return
        }
        var uuids: [CBUUID] = [BLEConstants.notifyCharacteristicUUID]
        if let w = BLEConstants.writeCharacteristicUUID { uuids.append(w) }
        peripheral.discoverCharacteristics(uuids, for: service)
    }

    private func setFailedFor(_ peripheral: CBPeripheral, message: String) {
        if device1?.peripheral.identifier == peripheral.identifier { device1?.setState(.failed(message)) }
        if device2?.peripheral.identifier == peripheral.identifier { device2?.setState(.failed(message)) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let err = error {
            setFailedFor(peripheral, message: err.localizedDescription)
            return
        }
        let characteristics = service.characteristics ?? []
        DispatchQueue.main.async { [weak self] in
            if let session = self?.device1, session.peripheral.identifier == peripheral.identifier {
                session.didDiscover(service: service, characteristics: characteristics)
                self?.subscribeToNotify(session)
            } else if let session = self?.device2, session.peripheral.identifier == peripheral.identifier {
                session.didDiscover(service: service, characteristics: characteristics)
                self?.subscribeToNotify(session)
            }
        }
    }

    private func subscribeToNotify(_ session: DeviceConnection) {
        guard let char = session.getNotifyCharacteristic() else {
            session.setState(.failed("Notify characteristic not found"))
            log("Notify characteristic not found", level: .error)
            return
        }
        session.peripheral.setNotifyValue(true, for: char)
        session.setState(.connected)
        log("Subscribed to notifications: \(session.name)")
        startRSSITimerIfNeeded()
    }

    /// Periodic RSSI updates for connected devices (nice-to-have)
    private func startRSSITimerIfNeeded() {
        guard rssiTimer == nil else { return }
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let d = self.device1, case .connected = d.state { d.peripheral.readRSSI() }
            if let d = self.device2, case .connected = d.state { d.peripheral.readRSSI() }
        }
        RunLoop.main.add(rssiTimer!, forMode: .common)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let err = error {
            log("Notify error: \(err.localizedDescription)", level: .warning)
            return
        }
        guard let data = characteristic.value else { return }
        // Dispatch to main only to get session reference, then parse off main in handleData
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let session = self.device1, session.peripheral.identifier == peripheral.identifier {
                self.handleData(data, device: session)
            } else if let session = self.device2, session.peripheral.identifier == peripheral.identifier {
                self.handleData(data, device: session)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            if self?.device1?.peripheral.identifier == peripheral.identifier {
                self?.device1?.updateRSSI(RSSI.intValue)
            } else if self?.device2?.peripheral.identifier == peripheral.identifier {
                self?.device2?.updateRSSI(RSSI.intValue)
            }
        }
    }
}
