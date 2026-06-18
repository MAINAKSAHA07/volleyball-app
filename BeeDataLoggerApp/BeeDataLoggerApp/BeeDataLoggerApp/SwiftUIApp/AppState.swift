//
//  AppState.swift
//  BeeDataLoggerApp
//
//  Shared state across tabs (single Wi‑Fi session + selected tab).
//

import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: Int = 0
}

