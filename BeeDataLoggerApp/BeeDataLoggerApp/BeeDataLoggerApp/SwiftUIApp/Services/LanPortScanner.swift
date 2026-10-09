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
        let interfaceName: String
        let localIP: String
        let prefixLen: Int
        let startHost: UInt32
        let endHost: UInt32
        let networkKey: UInt32
    }

    /// Prefer Wi‑Fi / Ethernet / hotspot interfaces on Mac and iPad.
    private func isUsefulInterface(_ name: String) -> Bool {
        if name == "lo0" || name.hasPrefix("utun") || name.hasPrefix("awdl") { return false }
        return name.hasPrefix("en")
            || name.hasPrefix("bridge")
            || name.hasPrefix("ap")
            || name == "pdp_ip0"
    }

    func allIPv4ScanInfos(maxSubnets: Int = 6) -> [ScanInfo] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(info: ScanInfo, score: Int)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = ifaddr
        while let p = ptr {
            let ifa = p.pointee
            defer { ptr = ifa.ifa_next }

            let flags = Int32(ifa.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: ifa.ifa_name)
            guard isUsefulInterface(name) else { continue }

            let addrIn = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let ip = UInt32(bigEndian: addrIn.sin_addr.s_addr)
            guard ip != 0, ip != 0x7F000001 else { continue } // skip 0.0.0.0 / 127.0.0.1

            guard let netmaskPtr = ifa.ifa_netmask else { continue }
            let netmaskIn = netmaskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let mask = UInt32(bigEndian: netmaskIn.sin_addr.s_addr)
            let prefixLen = mask.nonzeroBitCount
            guard prefixLen >= 16, prefixLen <= 30 else { continue }

            let network = ip & mask
            let broadcast = network | (~mask)
            let startHost = network &+ 1
            let endHost = broadcast &- 1
            guard endHost >= startHost else { continue }

            let hostCount = Int(endHost - startHost + 1)
            guard hostCount <= 4096 else { continue }

            var score = prefixLen * 10
            if name.hasPrefix("en0") { score += 50 }
            if name.hasPrefix("en") { score += 20 }
            if name.hasPrefix("bridge") { score += 15 }

            let info = ScanInfo(
                interfaceName: name,
                localIP: String(ipv4: ip),
                prefixLen: prefixLen,
                startHost: startHost,
                endHost: endHost,
                networkKey: network
            )
            candidates.append((info, score))
        }

        var unique: [UInt32: (info: ScanInfo, score: Int)] = [:]
        for c in candidates {
            if let existing = unique[c.info.networkKey] {
                if c.score > existing.score { unique[c.info.networkKey] = c }
            } else {
                unique[c.info.networkKey] = c
            }
        }

        return unique.values
            .sorted { $0.score > $1.score }
            .prefix(maxSubnets)
            .map(\.info)
    }

    func currentIPv4Info() -> ScanInfo? {
        allIPv4ScanInfos(maxSubnets: 1).first
    }

    func scanTCPPort(
        port: UInt16,
        timeout: TimeInterval = 0.25,
        concurrency: Int = 25,
        onCandidate: @escaping (LanCandidate) -> Void,
        onComplete: @escaping (Int) -> Void
    ) {
        cancelled = false

        let subnets = allIPv4ScanInfos()
        guard !subnets.isEmpty else {
            DispatchQueue.main.async {
                onComplete(0)
            }
            return
        }

        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: concurrency)
        var found = 0
        var seenIPs = Set<String>()
        let queue = DispatchQueue(label: "com.beedatalogger.lan.scan", qos: .userInitiated)

        for info in subnets {
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
                    params.prohibitExpensivePaths = false
                    params.prohibitConstrainedPaths = false

                    let conn = NWConnection(to: endpoint, using: params)
                    var finished = false
                    let finishOnce: (Bool) -> Void = { hit in
                        if finished { return }
                        finished = true
                        conn.cancel()
                        if hit {
                            found += 1
                            DispatchQueue.main.async {
                                if seenIPs.insert(ipStr).inserted {
                                    onCandidate(LanCandidate(ip: ipStr, port: port))
                                }
                            }
                        }
                        semaphore.signal()
                        group.leave()
                    }

                    conn.stateUpdateHandler = { newState in
                        switch newState {
                        case .ready:
                            finishOnce(true)
                        case .failed, .cancelled:
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
        }

        group.notify(queue: queue) {
            DispatchQueue.main.async {
                onComplete(found)
            }
        }
    }
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
