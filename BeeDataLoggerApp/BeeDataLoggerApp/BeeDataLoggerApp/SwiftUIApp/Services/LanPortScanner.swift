//
//  LanPortScanner.swift
//  BeeDataLoggerApp
//
//  Scans the local IPv4 subnet for hosts that have a TCP port open.
//  This is used as a fallback when Bonjour/mDNS discovery is unreliable.
//

import Foundation
import Network
import Darwin

struct LanCandidate: Identifiable, Equatable {
    let id: String
    let ip: String
    let port: UInt16

    init(ip: String, port: UInt16) {
        self.ip = ip
        self.port = port
        self.id = "\(ip):\(port)"
    }
}

final class LanPortScanner {
    private var cancelled = false

    func cancel() {
        cancelled = true
    }

    struct ScanInfo {
        let localIP: String
        let prefixLen: Int
        let startHost: UInt32
        let endHost: UInt32
    }

    func currentIPv4Info() -> ScanInfo? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var best: (ip: UInt32, mask: UInt32, prefixLen: Int, localIPStr: String)?

        var ptr: UnsafeMutablePointer<ifaddrs>? = ifaddr
        while let p = ptr {
            let ifa = p.pointee

            if let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                // Prefer Wi‑Fi-like interfaces.
                let name = String(cString: ifa.ifa_name)
                if (name.hasPrefix("en") || name == "pdp_ip0") {
                    let addrIn = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    let ip = UInt32(bigEndian: addrIn.sin_addr.s_addr)

                    if let netmaskPtr = ifa.ifa_netmask {
                        let netmaskIn = netmaskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        let mask = UInt32(bigEndian: netmaskIn.sin_addr.s_addr)

                        let prefixLen = mask.nonzeroBitCount
                        let localIPStr = String(ipv4: ip)

                        if let current = best {
                            if prefixLen > current.prefixLen {
                                best = (ip, mask, prefixLen, localIPStr)
                            }
                        } else {
                            best = (ip, mask, prefixLen, localIPStr)
                        }
                    }
                }
            }

            ptr = ifa.ifa_next
        }

        guard let b = best else { return nil }

        let network = b.ip & b.mask
        let broadcast = network | (~b.mask)
        let startHost = network &+ 1
        let endHost = broadcast &- 1

        return ScanInfo(localIP: b.localIPStr, prefixLen: b.prefixLen, startHost: startHost, endHost: endHost)
    }

    func scanTCPPort(
        port: UInt16,
        timeout: TimeInterval = 0.25,
        concurrency: Int = 25,
        onCandidate: @escaping (LanCandidate) -> Void,
        onComplete: @escaping (Int) -> Void
    ) {
        cancelled = false

        guard let info = currentIPv4Info() else {
            DispatchQueue.main.async {
                onComplete(0)
            }
            return
        }

        // Practical limit: if it's too large, scanning will be slow.
        // Most hotspot/LAN networks are /24.
        if info.prefixLen < 16 {
            DispatchQueue.main.async {
                onComplete(0)
            }
            return
        }

        let hostCount = Int(max(0, Int(info.endHost - info.startHost + 1)))
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: concurrency)

        var found = 0
        let queue = DispatchQueue(label: "com.beedatalogger.lan.scan", qos: .userInitiated)

        for host in info.startHost...info.endHost {
            if cancelled { break }
            semaphore.wait()
            group.enter()
            let ipStr = String(ipv4: host)

            queue.async {
                if self.cancelled {
                    semaphore.signal()
                    group.leave()
                    return
                }

                let nwHost = NWEndpoint.Host(ipStr)
                let endpoint = NWEndpoint.hostPort(host: nwHost, port: NWEndpoint.Port(rawValue: port)!)
                let params = NWParameters.tcp
                params.includePeerToPeer = true

                let conn = NWConnection(to: endpoint, using: params)
                var finished = false
                let finishOnce: (Bool) -> Void = { _ in
                    if finished { return }
                    finished = true
                    conn.cancel()
                    semaphore.signal()
                    group.leave()
                }

                conn.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        found += 1
                        DispatchQueue.main.async {
                            onCandidate(LanCandidate(ip: ipStr, port: port))
                        }
                        finishOnce(true)
                    case .failed:
                        finishOnce(false)
                    case .cancelled:
                        finishOnce(false)
                    default:
                        break
                    }
                }

                conn.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    finishOnce(false)
                }
            }
        }

        group.notify(queue: queue) {
            DispatchQueue.main.async {
                onComplete(found)
            }
        }
    }
}

private extension String {
    // Only used for ipv4 conversion display.
}

private extension String {
    init(ipv4: UInt32) {
        let b1 = (ipv4 >> 24) & 0xFF
        let b2 = (ipv4 >> 16) & 0xFF
        let b3 = (ipv4 >> 8) & 0xFF
        let b4 = ipv4 & 0xFF
        self.init("\(b1).\(b2).\(b3).\(b4)")
    }
}

