//
//  ScanView.swift
//  BeeDataLoggerApp
//
//  Scan screen: start/stop scan, list of discovered devices, select 2, connect.
//

import SwiftUI

struct ScanView: View {
    @StateObject private var viewModel = ScanViewModel()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                scanSection
                devicesSection
            }
            .navigationTitle("Scan")
            .onAppear {
                viewModel.updateStatusFromState()
            }
            .onChange(of: viewModel.bluetoothState) { _, _ in
                viewModel.updateStatusFromState()
            }
        }
    }

    private var statusSection: some View {
        Section {
            Text(viewModel.statusMessage)
                .foregroundStyle(viewModel.errorMessage != nil ? .red : .secondary)
            if let err = viewModel.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Status")
        }
    }

    private var scanSection: some View {
        Section {
            if viewModel.isScanning {
                Button("Stop scan") { viewModel.stopScan() }
                    .foregroundStyle(.red)
            } else {
                Button("Start scan") { viewModel.startScan() }
                    .disabled(viewModel.bluetoothState != .poweredOn)
            }
            Button("Connect to selected (\(viewModel.selectedIds.count)/2)") {
                viewModel.connectSelected()
            }
            .disabled(!viewModel.canConnect || viewModel.connectionInProgress)
            if viewModel.connectionInProgress {
                ProgressView()
                    .padding(.top, 4)
            }
        } header: {
            Text("Actions")
        }
    }

    private var devicesSection: some View {
        Section {
            if viewModel.sortedDiscovered.isEmpty && !viewModel.isScanning {
                Text("No devices found. Start a scan.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.sortedDiscovered) { scanned in
                DeviceRowView(
                    scanned: scanned,
                    isSelected: viewModel.selectedIds.contains(scanned.id),
                    onTap: { viewModel.toggleSelection(id: scanned.id) }
                )
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("Select exactly 2 devices (e.g. BDL-01 and BDL-02), then tap Connect.")
        }
    }
}

private struct DeviceRowView: View {
    let scanned: BLEManager.ScannedPeripheral
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scanned.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(scanned.id.uuidString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("RSSI: \(scanned.rssi)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ScanView()
}
