//
//  WiFiConnectView.swift
//  BeeDataLoggerApp
//
//  Simple Wi‑Fi connect screen: enter two device IPs/hostnames and connect.
//

import SwiftUI

struct WiFiConnectView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var wifiVM: WiFiConnectViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairs") {
                    Stepper("Pairs: \(wifiVM.pairCount)", value: Binding(
                        get: { wifiVM.pairCount },
                        set: { wifiVM.setPairCount($0) }
                    ), in: 1...WiFiStreamManager.maxPairs)
                        .disabled(wifiVM.isRecording)
                    Picker("Active pair", selection: Binding(
                        get: { wifiVM.activePairIndex },
                        set: { wifiVM.setActivePairIndex($0) }
                    )) {
                        ForEach(0..<wifiVM.pairCount, id: \.self) { i in
                            Text("Pair \(i + 1)").tag(i)
                        }
                    }
                    .disabled(wifiVM.isRecording)
                }

                Section("Auto-discovered (Bonjour)") {
                    Group {
                        if wifiVM.discovered.isEmpty {
                            Text("No devices found yet. Make sure both ESP32s advertise _bdl._tcp and your iPhone hotspot is on.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(0..<wifiVM.pairCount, id: \.self) { pair in
                                let aSlot = pair * 2
                                let bSlot = aSlot + 1
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Pair \(pair + 1)")
                                        .font(.subheadline.weight(.semibold))
                                    Picker("Sleeve A", selection: Binding(
                                        get: { wifiVM.slotSelectedKeys[aSlot] },
                                        set: { wifiVM.setSlotSelectedKey($0, slot: aSlot) }
                                    )) {
                                        Text("Select…").tag("")
                                        ForEach(wifiVM.discovered) { d in
                                            Text(d.name).tag(d.key)
                                        }
                                    }
                                    Picker("Sleeve B", selection: Binding(
                                        get: { wifiVM.slotSelectedKeys[bSlot] },
                                        set: { wifiVM.setSlotSelectedKey($0, slot: bSlot) }
                                    )) {
                                        Text("Select…").tag("")
                                        ForEach(wifiVM.discovered) { d in
                                            Text(d.name).tag(d.key)
                                        }
                                    }
                                    TextField("Player A (Excel tab name)", text: Binding(
                                        get: { wifiVM.sleevePlayerName(slot: aSlot) },
                                        set: { wifiVM.setSleevePlayerName($0, slot: aSlot) }
                                    ))
                                    .textInputAutocapitalization(.words)
                                    TextField("Player B (Excel tab name)", text: Binding(
                                        get: { wifiVM.sleevePlayerName(slot: bSlot) },
                                        set: { wifiVM.setSleevePlayerName($0, slot: bSlot) }
                                    ))
                                    .textInputAutocapitalization(.words)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .id("bonjour-pairs-\(wifiVM.pairCount)")
                    Button(wifiVM.isBrowsing ? "Stop discovery" : "Start discovery") {
                        wifiVM.isBrowsing ? wifiVM.stopDiscovery() : wifiVM.startDiscovery()
                    }
                }

                Section("Devices (Wi‑Fi TCP)") {
                    Group {
                        ForEach(0..<wifiVM.pairCount, id: \.self) { pair in
                            let aSlot = pair * 2
                            let bSlot = aSlot + 1
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Pair \(pair + 1) (manual hosts)")
                                    .font(.subheadline.weight(.semibold))
                                TextField("Sleeve A host (optional, e.g. bdl-01.local)", text: Binding(
                                    get: { wifiVM.slotHosts[aSlot] },
                                    set: { wifiVM.setSlotHost($0, slot: aSlot) }
                                ))
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                TextField("Sleeve B host (optional, e.g. bdl-02.local)", text: Binding(
                                    get: { wifiVM.slotHosts[bSlot] },
                                    set: { wifiVM.setSlotHost($0, slot: bSlot) }
                                ))
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .id("manual-pairs-\(wifiVM.pairCount)")
                    TextField("Port", text: $wifiVM.port)
                        .keyboardType(.numberPad)
                }

                Section("LAN Probe (port 3333)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Local IP: \(wifiVM.localIPv4.isEmpty ? "Unknown" : wifiVM.localIPv4)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if case .scanning = wifiVM.lanScanState {
                            HStack {
                                ProgressView()
                                Text("Scanning…")
                                    .foregroundStyle(.secondary)
                            }
                            Button("Cancel") { wifiVM.cancelLANScan() }
                                .foregroundStyle(.red)
                        } else {
                            Button("Scan LAN for open port") { wifiVM.scanLANForServers() }
                        }
                    }

                    if !wifiVM.lanCandidates.isEmpty {
                        Text("Assign to Pair \(wifiVM.activePairIndex + 1): A = Sleeve A, B = Sleeve B")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Divider()
                        ForEach(wifiVM.lanCandidates) { c in
                            HStack(spacing: 8) {
                                Text(c.ip)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button("A") { wifiVM.useCandidate(c, asDevice: 1) }
                                    .buttonStyle(.bordered)
                                Button("B") { wifiVM.useCandidate(c, asDevice: 2) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    } else if case .failed(let msg) = wifiVM.lanScanState {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if case .done(let count) = wifiVM.lanScanState, count == 0 {
                        Text("No open stream servers found (TCP \(wifiVM.port)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let err = wifiVM.errorMessage {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        wifiVM.connect()
                    } label: {
                        HStack {
                            Text("Connect")
                            if wifiVM.isConnecting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(
                        wifiVM.slotSelectedKeys.prefix(wifiVM.pairCount * 2).allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
                        wifiVM.slotHosts.prefix(wifiVM.pairCount * 2).allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    )

                    Button("Open Dashboard") { appState.selectedTab = 1 }
                        .disabled(!anyConnected)

                    Button("Disconnect") { wifiVM.disconnectAll() }
                        .foregroundStyle(.red)
                }

                Section("Status") {
                    if let d1 = wifiVM.device1 {
                        DeviceStatusRow(title: "Active pair — Sleeve A", device: d1)
                    } else {
                        StaticStatusRow(title: "Active pair — Sleeve A", text: "Disconnected")
                    }
                    if let d2 = wifiVM.device2 {
                        DeviceStatusRow(title: "Active pair — Sleeve B", device: d2)
                    } else {
                        StaticStatusRow(title: "Active pair — Sleeve B", text: "Disconnected")
                    }
                }
            }
            .navigationTitle("Wi‑Fi Connect")
            .onAppear { wifiVM.startDiscovery() }
            .onChange(of: wifiVM.device1?.state) { _, _ in
                updateNavigationIfReady()
            }
            .onChange(of: wifiVM.device2?.state) { _, _ in
                updateNavigationIfReady()
            }
        }
    }

    private var bothConnected: Bool {
        if case .connected = wifiVM.device1?.state,
           case .connected = wifiVM.device2?.state {
            return true
        }
        return false
    }

    private var anyConnected: Bool {
        if case .connected = wifiVM.device1?.state { return true }
        if case .connected = wifiVM.device2?.state { return true }
        return false
    }

    private func updateNavigationIfReady() {
        if anyConnected {
            appState.selectedTab = 1
        }
    }
}

private struct DeviceStatusRow: View {
    let title: String
    @ObservedObject var device: WiFiDeviceConnection

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(stateText(device.state))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func stateText(_ s: WiFiDeviceState) -> String {
        switch s {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }
}

private struct StaticStatusRow: View {
    let title: String
    let text: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    WiFiConnectView()
}

