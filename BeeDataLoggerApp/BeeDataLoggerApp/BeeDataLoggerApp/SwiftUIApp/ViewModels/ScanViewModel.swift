//
//  ScanViewModel.swift
//  BeeDataLoggerApp
//
//  Handles scan UI state: discovered devices, selection of 2 devices, connection,
//  and navigation to dashboard. Prefers BDL-01 / BDL-02 when available.
//

import Foundation
import Combine
import CoreBluetooth

final class ScanViewModel: ObservableObject {
    @Published private(set) var discoveredDevices: [BLEManager.ScannedPeripheral] = []
    @Published var selectedIds: Set<UUID> = []
    @Published var statusMessage: String = ""
    @Published var isScanning: Bool = false
    @Published var canConnect: Bool = false
    @Published var connectionInProgress: Bool = false
    @Published var bluetoothState: BLEManagerState = .unknown
    @Published var errorMessage: String?

    private let bleManager = BLEManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let maxSelection = 2

    init() {
        bleManager.$discoveredPeripherals
            .receive(on: DispatchQueue.main)
            .assign(to: &$discoveredDevices)

        bleManager.$isScanning
            .receive(on: DispatchQueue.main)
            .assign(to: &$isScanning)

        bleManager.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$bluetoothState)

        $selectedIds
            .map { $0.count == 2 }
            .assign(to: &$canConnect)

        bleManager.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusFromState() }
            .store(in: &cancellables)

        updateStatusFromState()
    }

    func updateStatusFromState() {
        switch bluetoothState {
        case .poweredOff:
            statusMessage = "Turn on Bluetooth to scan"
            errorMessage = "Bluetooth is off"
        case .unauthorized, .unsupported:
            statusMessage = "Bluetooth access not available"
            errorMessage = "Check Bluetooth permission in Settings"
        case .poweredOn:
            if isScanning {
                statusMessage = "Scanning... Select 2 devices"
            } else {
                statusMessage = "Tap Scan to find devices"
            }
            errorMessage = nil
        default:
            statusMessage = "Initializing..."
            errorMessage = nil
        }
    }

    func startScan() {
        errorMessage = nil
        selectedIds.removeAll()
        bleManager.startScanning()
        statusMessage = "Scanning... Select 2 devices"
    }

    func stopScan() {
        bleManager.stopScanning()
        statusMessage = "Tap Scan to find devices"
    }

    func toggleSelection(id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else if selectedIds.count < maxSelection {
            selectedIds.insert(id)
        }
    }

    /// Sorted list for display: prefer BDL-01, BDL-02 first
    var sortedDiscovered: [BLEManager.ScannedPeripheral] {
        let prefix = BLEConstants.preferredDeviceNamePrefix
        return discoveredDevices.sorted { a, b in
            let aPref = a.name.uppercased().hasPrefix(prefix.uppercased())
            let bPref = b.name.uppercased().hasPrefix(prefix.uppercased())
            if aPref != bPref { return aPref }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func connectSelected() {
        guard selectedIds.count == 2 else {
            errorMessage = "Please select exactly 2 devices"
            return
        }
        errorMessage = nil
        connectionInProgress = true
        let selected = sortedDiscovered.filter { selectedIds.contains($0.id) }
        // Connect in order: first selected, then second
        if selected.count >= 2 {
            bleManager.connectToScanned(id: selected[0].id, name: selected[0].name, rssi: selected[0].rssi)
            bleManager.connectToScanned(id: selected[1].id, name: selected[1].name, rssi: selected[1].rssi)
        }
        statusMessage = "Connecting..."
        // Reset progress after a short delay (actual connection state is in DashboardViewModel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.connectionInProgress = false
        }
    }

    func hasDevice1And2() -> Bool {
        bleManager.device1 != nil && bleManager.device2 != nil
    }
}
