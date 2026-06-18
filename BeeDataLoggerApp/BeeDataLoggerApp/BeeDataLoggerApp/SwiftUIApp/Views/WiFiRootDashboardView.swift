//
//  WiFiRootDashboardView.swift
//  BeeDataLoggerApp
//
//  Dashboard tab root: always shows the live dashboard layout (devices, controls, graphs).
//  When not fully connected, a banner points users to the Wi‑Fi tab.
//

import SwiftUI

struct WiFiRootDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var wifiVM: WiFiConnectViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !anyWiFiConnected {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect sleeves")
                                .font(.subheadline.weight(.semibold))
                            Text("Use the Wi‑Fi tab to connect 1–5 pairs. The dashboard updates as soon as any sleeve is streaming.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open Wi‑Fi tab") {
                                appState.selectedTab = 0
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
                }
                WiFiDashboardView()
            }
            .navigationTitle("Dashboard")
        }
    }

    private var anyWiFiConnected: Bool {
        if case .connected = wifiVM.device1?.state { return true }
        if case .connected = wifiVM.device2?.state { return true }
        return false
    }
}

#Preview {
    WiFiRootDashboardView()
        .environmentObject(AppState())
        .environmentObject(WiFiConnectViewModel())
}
