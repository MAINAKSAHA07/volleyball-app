//
//  DashboardView.swift
//  BeeDataLoggerApp
//
//  Live dashboard: two device cards side by side (or stacked on small screens),
//  BLE log console, reconnect buttons.
//

import SwiftUI

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    deviceCards
                    logSection
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .background(Color(.systemGroupedBackground))
        }
    }

    private var deviceCards: some View {
        VStack(spacing: 16) {
            DeviceCardView(
                title: "Device 1",
                device: viewModel.device1,
                isMock: viewModel.isMockMode,
                onReconnect: { viewModel.device1.map { viewModel.reconnect($0) } }
            )
            DeviceCardView(
                title: "Device 2",
                device: viewModel.device2,
                isMock: viewModel.isMockMode,
                onReconnect: { viewModel.device2.map { viewModel.reconnect($0) } }
            )
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BLE Log")
                    .font(.headline)
                Spacer()
                Button("Clear") { viewModel.clearLog() }
                    .font(.caption)
            }
            if viewModel.logEntries.isEmpty {
                Text("No events yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.logEntries.suffix(50)) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(logColor(entry.level))
                                .frame(width: 6, height: 6)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.message)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Text(entry.date.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxHeight: 200)
            }
        }
    }

    private func logColor(_ level: BLELogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

#Preview {
    DashboardView()
}
