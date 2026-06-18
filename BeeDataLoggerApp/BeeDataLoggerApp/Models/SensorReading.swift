//
//  SensorReading.swift
//  BeeDataLoggerApp
//
//  Model for a single sensor reading from a BDL device.
//  Supports live display and future charting via history buffer.
//

import Foundation

/// A single sensor reading parsed from BLE notify payload.
struct SensorReading: Identifiable, Equatable {
    /// Number of FSR channels on the sleeve (RMS / normalization use √N).
    static let fsrChannelCount = 5

    let id: UUID
    /// Epoch milliseconds from device
    let epochMs: Int64
    /// FSR sensor values (1–5)
    let fsr1: Int
    let fsr2: Int
    let fsr3: Int
    let fsr4: Int
    let fsr5: Int
    /// 0…100 from Wi‑Fi CSV when firmware sends `battery_pct` (optional; BLE may omit).
    let batteryPercent: Int?
    /// Which device this reading came from
    let deviceIdentifier: String
    /// When the app received this reading
    let receivedAt: Date

    init(
        id: UUID = UUID(),
        epochMs: Int64,
        fsr1: Int, fsr2: Int, fsr3: Int, fsr4: Int, fsr5: Int,
        batteryPercent: Int? = nil,
        deviceIdentifier: String,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.epochMs = epochMs
        self.fsr1 = fsr1
        self.fsr2 = fsr2
        self.fsr3 = fsr3
        self.fsr4 = fsr4
        self.fsr5 = fsr5
        self.batteryPercent = batteryPercent
        self.deviceIdentifier = deviceIdentifier
        self.receivedAt = receivedAt
    }

    /// All FSR values as array for charting or iteration
    var fsrValues: [Int] { [fsr1, fsr2, fsr3, fsr4, fsr5] }

    /// Max raw resultant at full-scale ADC (for 0…1 normalization).
    static func rawResultantMax(adcMax: Double = 4095) -> Double {
        adcMax * Double(fsrChannelCount).squareRoot()
    }

    /// Raw resultant √(fsr1² + … + fsr5²). Same definition as Analysis peaks and auto‑vibrate.
    var resultantMagnitude: Double {
        fsrValues.map { Double($0) }.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
    }
}
