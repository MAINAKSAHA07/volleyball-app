//
//  BonjourDiscovery.swift
//  BeeDataLoggerApp
//
//  Discovers ESP32 stream servers advertised via Bonjour/mDNS.
//  Firmware should advertise: _bdl._tcp on port 3333
//

import Foundation
import Network
import Combine

struct DiscoveredWiFiDevice: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let endpoint: NWEndpoint
    /// Stable key for selection (since NWEndpoint isn't Hashable)
    let key: String

    static func == (lhs: DiscoveredWiFiDevice, rhs: DiscoveredWiFiDevice) -> Bool {
        lhs.key == rhs.key
    }
}

final class BonjourDiscovery: ObservableObject {
    @Published private(set) var devices: [DiscoveredWiFiDevice] = []
    @Published private(set) var isBrowsing: Bool = false

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let b = NWBrowser(for: .bonjour(type: "_bdl._tcp", domain: nil), using: params)
        browser = b
        isBrowsing = true

        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let mapped: [DiscoveredWiFiDevice] = results.compactMap { result in
                guard case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint else { return nil }
                return DiscoveredWiFiDevice(name: name, endpoint: result.endpoint, key: result.endpoint.debugDescription)
            }
            DispatchQueue.main.async {
                self.devices = mapped.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }

        b.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                if case .failed = state {
                    self?.stop()
                }
            }
        }

        b.start(queue: DispatchQueue(label: "com.beedatalogger.bonjour", qos: .userInitiated))
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        devices = []
    }

    // Connect using the NWEndpoint directly (no IP required).
}

