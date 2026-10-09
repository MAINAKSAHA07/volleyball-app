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
    @Published private(set) var statusMessage: String = "Discovery idle."

    private var browser: NWBrowser?
    private var retryWorkItem: DispatchWorkItem?
    private var retryCount = 0
    private let maxRetries = 6

    func start() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryCount = 0
        startBrowser()
    }

    func stop() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryCount = 0
        browser?.cancel()
        browser = nil
        isBrowsing = false
        devices = []
        statusMessage = "Discovery stopped."
    }

    private func startBrowser() {
        browser?.cancel()
        browser = nil

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        params.prohibitExpensivePaths = false
        params.prohibitConstrainedPaths = false

        let b = NWBrowser(for: .bonjour(type: "_bdl._tcp", domain: "local."), using: params)
        browser = b
        isBrowsing = true
        statusMessage = retryCount == 0
            ? "Searching for _bdl._tcp devices on the local network…"
            : "Retrying Bonjour discovery (attempt \(retryCount + 1))…"

        b.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            let mapped = Self.mapBrowseResults(results)
            DispatchQueue.main.async {
                self.devices = mapped.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                if mapped.isEmpty {
                    self.statusMessage = "Bonjour active — no _bdl._tcp devices found yet."
                } else {
                    self.statusMessage = "Found \(mapped.count) device(s) via Bonjour."
                    self.retryCount = 0
                }
            }
        }

        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self.statusMessage = "Bonjour browser ready — listening for _bdl._tcp."
                case .failed(let error):
                    self.statusMessage = "Bonjour failed: \(error.localizedDescription). Use LAN scan or enter hostnames manually."
                    self.scheduleRetry()
                case .cancelled:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }

        b.start(queue: DispatchQueue(label: "com.beedatalogger.bonjour", qos: .userInitiated))
    }

    private func scheduleRetry() {
        browser?.cancel()
        browser = nil
        guard retryCount < maxRetries else {
            isBrowsing = false
            statusMessage = "Bonjour unavailable after several retries. Use “Scan LAN for open port” below."
            return
        }
        retryCount += 1
        let delay = min(8.0, 0.75 * Double(retryCount))
        let work = DispatchWorkItem { [weak self] in
            self?.startBrowser()
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func mapBrowseResults(_ results: Set<NWBrowser.Result>) -> [DiscoveredWiFiDevice] {
        results.compactMap { result in
            switch result.endpoint {
            case let .service(name: name, type: _, domain: _, interface: _):
                return DiscoveredWiFiDevice(
                    name: name,
                    endpoint: result.endpoint,
                    key: "service:\(name)|\(result.endpoint.debugDescription)"
                )
            case let .hostPort(host: host, port: port):
                let label = "\(host):\(port.rawValue)"
                return DiscoveredWiFiDevice(
                    name: label,
                    endpoint: result.endpoint,
                    key: "host:\(label)"
                )
            default:
                return nil
            }
        }
    }
}
