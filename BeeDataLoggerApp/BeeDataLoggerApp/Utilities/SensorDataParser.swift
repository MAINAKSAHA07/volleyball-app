//
//  SensorDataParser.swift
//  BeeDataLoggerApp
//
//  Parses CSV: epoch_ms,fsr1…fsr5[,battery_pct] (6–7 fields from Wi‑Fi firmware)
//

import Foundation

enum SensorDataParser {

    /// CSV: epoch_ms,fsr1…fsr5[,battery_pct 0…100]
    /// Example: 1741738205123,122,130,141,118,125,87
    static func parse(
        _ data: Data,
        deviceIdentifier: String
    ) -> SensorReading? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        return parse(string, deviceIdentifier: deviceIdentifier)
    }

    static func parse(
        _ csvString: String,
        deviceIdentifier: String
    ) -> SensorReading? {
        let parts = csvString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",")
            .map(String.init)
        guard parts.count >= 6 else { return nil }
        guard let epochMs = Int64(parts[0]),
              let fsr1 = Int(parts[1]),
              let fsr2 = Int(parts[2]),
              let fsr3 = Int(parts[3]),
              let fsr4 = Int(parts[4]),
              let fsr5 = Int(parts[5]) else { return nil }
        let bat: Int?
        if parts.count >= 7, let p = Int(parts[6]) {
            bat = min(100, max(0, p))
        } else {
            bat = nil
        }
        return SensorReading(
            epochMs: epochMs,
            fsr1: fsr1, fsr2: fsr2, fsr3: fsr3, fsr4: fsr4, fsr5: fsr5,
            batteryPercent: bat,
            deviceIdentifier: deviceIdentifier,
            receivedAt: Date()
        )
    }
}
