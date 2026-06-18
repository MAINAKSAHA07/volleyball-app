//
//  MockData.swift
//  BeeDataLoggerApp
//
//  Mock data for SwiftUI previews and optional preview/mock mode.
//

import Foundation

enum MockData {

    static let sampleCSV = "1741738205123,122,130,141,118,125,88"
    static let sampleCSV2 = "1741738205234,100,110,120,105,115,72"

    static var sampleReading1: SensorReading {
        SensorReading(
            epochMs: 1741738205123,
            fsr1: 122, fsr2: 130, fsr3: 141, fsr4: 118, fsr5: 125,
            batteryPercent: 88,
            deviceIdentifier: "BDL-01-Mock",
            receivedAt: Date()
        )
    }

    static var sampleReading2: SensorReading {
        SensorReading(
            epochMs: 1741738205234,
            fsr1: 100, fsr2: 110, fsr3: 120, fsr4: 105, fsr5: 115,
            batteryPercent: 72,
            deviceIdentifier: "BDL-02-Mock",
            receivedAt: Date()
        )
    }

    static func reading(deviceId: String, offset: Int = 0) -> SensorReading {
        SensorReading(
            epochMs: Int64(Date().timeIntervalSince1970 * 1000) + Int64(offset),
            fsr1: 100 + offset, fsr2: 110, fsr3: 120, fsr4: 105, fsr5: 115,
            batteryPercent: 80,
            deviceIdentifier: deviceId,
            receivedAt: Date()
        )
    }
}
