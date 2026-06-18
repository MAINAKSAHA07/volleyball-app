//
//  ContentView.swift
//  BeeDataLoggerApp
//
//  Root view: tab or navigation between Scan and Dashboard.
//  Shows Scan first; after connecting to 2 devices, user can switch to Dashboard.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()
    @StateObject private var wifiVM = WiFiConnectViewModel()

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            WiFiConnectView()
                .tabItem {
                    Label("Wi‑Fi", systemImage: "wifi")
                }
                .tag(0)

            WiFiRootDashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "chart.bar.doc.horizontal")
                }
                .tag(1)
        }
        .environmentObject(appState)
        .environmentObject(wifiVM)
        .background {
            if wifiVM.showDocumentExport, let url = wifiVM.documentExportURL {
                DocumentExportPicker(url: url, isPresented: $wifiVM.showDocumentExport) {
                    wifiVM.finishDocumentExport()
                }
                .frame(width: 0, height: 0)
            }
        }
    }
}

#Preview {
    ContentView()
}
