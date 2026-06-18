//
//  ContentView.swift
//  BeeDataLoggerApp
//
//  Root view: tab or navigation between Scan and Dashboard.
//  Shows Scan first; after connecting to 2 devices, user can switch to Dashboard.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ScanView()
                .tabItem {
                    Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(0)

            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "chart.bar.doc.horizontal")
                }
                .tag(1)
        }
    }
}

#Preview {
    ContentView()
}
