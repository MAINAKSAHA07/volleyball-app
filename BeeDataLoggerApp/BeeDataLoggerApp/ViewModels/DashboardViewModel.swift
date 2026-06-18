//
//  DashboardViewModel.swift
//  BeeDataLoggerApp
//
//  Drives the live dashboard: device1/device2 state, latest readings,
//  reconnect, and BLE log. Supports mock mode for previews.
//

import Foundation
import Combine

final class DashboardViewModel: ObservableObject {
    @Published var device1: DeviceConnection?
    @Published var device2: DeviceConnection?
    @Published var logEntries: [BLELogEntry] = []
    @Published var isMockMode: Bool = false

    private let bleManager = BLEManager.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        bleManager.$device1
            .receive(on: DispatchQueue.main)
            .assign(to: &$device1)

        bleManager.$device2
            .receive(on: DispatchQueue.main)
            .assign(to: &$device2)

        bleManager.$logEntries
            .receive(on: DispatchQueue.main)
            .assign(to: &$logEntries)
    }

    func reconnect(_ device: DeviceConnection) {
        bleManager.reconnect(device)
    }

    func disconnect(_ device: DeviceConnection) {
        bleManager.disconnect(device)
    }

    func clearLog() {
        bleManager.clearLog()
    }

    /// Enable mock mode for SwiftUI previews
    func setMockMode(_ enabled: Bool) {
        isMockMode = enabled
        bleManager.setMockMode(enabled)
    }
}
