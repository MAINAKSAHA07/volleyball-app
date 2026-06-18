//
//  DeviceCardView.swift
//  BeeDataLoggerApp
//
//  One panel for a single device: name, connection state, last updated,
//  epoch, FSR1–FSR5, streaming indicator, reconnect button.
//

import SwiftUI
import CoreBluetooth

struct DeviceCardView: View {
    let title: String
    let device: DeviceConnection?
    let isMock: Bool
    let onReconnect: () -> Void

    private var reading: SensorReading? { device?.lastReading }
    private var state: DeviceConnectionState { device?.state ?? .disconnected }
    private var lastUpdated: Date? { device?.lastUpdated }
    private var rssi: Int? { device?.rssi }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            connectionBadge
            if let rssi = rssi {
                Text("RSSI: \(rssi) dBm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let updated = lastUpdated {
                Text("Last updated: \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let r = reading {
                epochRow(r)
                fsrGrid(r)
                streamingIndicator
            } else {
                noDataPlaceholder
            }
            reconnectButton
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            if isMock {
                Text("MOCK")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.3))
                    .clipShape(Capsule())
            }
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(stateText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var stateColor: Color {
        switch state {
        case .connected: return .green
        case .connecting, .discovering: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var stateText: String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .discovering: return "Discovering…"
        case .disconnected: return "Disconnected"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    private func epochRow(_ r: SensorReading) -> some View {
        Text("Epoch: \(r.epochMs)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func fsrGrid(_ r: SensorReading) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], spacing: 8) {
            ForEach(Array(["FSR1", "FSR2", "FSR3", "FSR4", "FSR5"].enumerated()), id: \.offset) { i, label in
                VStack(spacing: 2) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(r.fsrValues[i])")
                        .font(.body.monospacedDigit().weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var streamingIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text("Streaming")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var noDataPlaceholder: some View {
        Text("No data yet")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    private var reconnectButton: some View {
        Button(action: onReconnect) {
            Label("Reconnect", systemImage: "arrow.clockwise")
                .font(.subheadline)
        }
        .disabled(state == .connected || state == .connecting || state == .discovering)
    }
}

#Preview("Device card - no data") {
    DeviceCardView(title: "Device 1", device: nil, isMock: false, onReconnect: {})
        .padding()
}
