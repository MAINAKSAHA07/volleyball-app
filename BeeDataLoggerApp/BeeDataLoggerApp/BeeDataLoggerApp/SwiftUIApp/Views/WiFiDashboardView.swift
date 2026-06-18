//
//  WiFiDashboardView.swift
//  BeeDataLoggerApp
//
//  Live dashboard for Wi‑Fi streamed sensor data from two ESP32 devices.
//

import SwiftUI
import Charts

struct WiFiDashboardView: View {
    @EnvironmentObject private var wifiVM: WiFiConnectViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let err = wifiVM.errorMessage {
                    statusBanner(text: err, icon: "exclamationmark.triangle.fill", tint: .orange) {
                        wifiVM.errorMessage = nil
                    }
                }

                if let notice = wifiVM.lastSaveNotice {
                    statusBanner(text: notice, icon: "checkmark.circle.fill", tint: .green) {
                        wifiVM.lastSaveNotice = nil
                    }
                }

                HStack {
                    Text("Live Dashboard")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    NavigationLink("Analysis") {
                        WiFiAnalysisView()
                    }
                    .buttonStyle(.bordered)
                    rateMenu
                    recordButton
                    saveRecordingButton
                    Button("Disconnect") { wifiVM.disconnectAll() }
                        .foregroundStyle(.red)
                }

                pairSelectorCard

                autoVibrateCard

                recentSessionsCard

                allPairsDeviceCards

                sessionChartsCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func statusBanner(text: String, icon: String, tint: Color, onDismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var rateMenu: some View {
        Menu {
            Picker("Rate", selection: $wifiVM.targetSampleRateHz) {
                Text("50 Hz").tag(50)
                Text("100 Hz").tag(100)
                Text("200 Hz").tag(200)
                Text("500 Hz").tag(500)
            }
        } label: {
            Label("\(wifiVM.targetSampleRateHz)Hz", systemImage: "speedometer")
        }
        .buttonStyle(.bordered)
        .disabled(wifiVM.isRecording) // lock rate while recording
    }

    private var recordButton: some View {
        Button {
            if wifiVM.isRecording {
                _ = wifiVM.stopRecording()
            } else {
                wifiVM.startRecording()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: wifiVM.isRecording ? "stop.circle.fill" : "record.circle")
                Text(wifiVM.isRecording ? "Stop (\(wifiVM.recordedCount))" : "Record")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(wifiVM.isRecording ? .red : .accentColor)
        // Start Record when at least one device is connected; Stop always while recording.
        .disabled(!wifiVM.isRecording && !wifiVM.anySlotConnected())
    }

    private var allPairsDeviceCards: some View {
        ForEach(0..<wifiVM.pairCount, id: \.self) { pair in
            pairDevicesSection(pairIndex: pair)
        }
        .id("dashboard-device-pairs-\(wifiVM.pairCount)")
    }

    @ViewBuilder
    private func pairDevicesSection(pairIndex: Int) -> some View {
        let aSlot = pairIndex * 2
        let bSlot = aSlot + 1
        let isActive = pairIndex == wifiVM.activePairIndex

        VStack(alignment: .leading, spacing: 10) {
            Button {
                wifiVM.setActivePairIndex(pairIndex)
            } label: {
                HStack(spacing: 8) {
                    Text("Pair \(pairIndex + 1)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    if isActive {
                        Text("Active — charts")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    if wifiVM.isPairBothConnected(pairIndex) {
                        Label("Both connected", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(wifiVM.isRecording)

            pairPlayerNamesRow(pairIndex: pairIndex, aSlot: aSlot, bSlot: bSlot)

            sleeveDeviceCard(slot: aSlot, pairIndex: pairIndex, label: "Sleeve A")
            sleeveDeviceCard(slot: bSlot, pairIndex: pairIndex, label: "Sleeve B")
        }
    }

    private func pairPlayerNamesRow(pairIndex: Int, aSlot: Int, bSlot: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Players (Excel tab: \(wifiVM.pairSheetTitle(pairIndex: pairIndex)))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("Sleeve A player", text: Binding(
                    get: { wifiVM.sleevePlayerName(slot: aSlot) },
                    set: { wifiVM.setSleevePlayerName($0, slot: aSlot) }
                ))
                .textInputAutocapitalization(.words)
                TextField("Sleeve B player", text: Binding(
                    get: { wifiVM.sleevePlayerName(slot: bSlot) },
                    set: { wifiVM.setSleevePlayerName($0, slot: bSlot) }
                ))
                .textInputAutocapitalization(.words)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .disabled(wifiVM.isRecording)
    }

    @ViewBuilder
    private func sleeveDeviceCard(slot: Int, pairIndex: Int, label: String) -> some View {
        let title = "Pair \(pairIndex + 1) — \(label)"
        if let device = wifiVM.device(atSlot: slot) {
            WiFiDeviceCardView(
                title: title,
                slotLabel: "Slot \(slot + 1)",
                device: device,
                onVibrate: { wifiVM.sendVibratorTest(atSlot: slot) },
                onReconnect: { device.reconnect() }
            )
            .id("wifi-sleeve-\(slot)-\(device.id.uuidString)")
        } else {
            WiFiDevicePlaceholderCardView(title: title)
                .id("wifi-sleeve-placeholder-\(slot)")
        }
    }

    private var saveRecordingButton: some View {
        Menu {
            Button("Excel workbook (.xls)") {
                let data = wifiVM.workbookDataForLastRecording()
                wifiVM.queueWorkbookExport(
                    data: data,
                    filename: "bdl-recording-\(Int(Date().timeIntervalSince1970)).xls"
                )
            }
            Button("CSV — active pair") {
                guard let csv = wifiVM.csvStringForLastRecording() else {
                    wifiVM.errorMessage = "No recording rows for the active pair."
                    return
                }
                wifiVM.queueCSVExport(
                    text: csv,
                    filename: "bdl-recording-\(Int(Date().timeIntervalSince1970)).csv"
                )
            }
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .disabled(!wifiVM.canExportLastRecording)
    }

    private var pairSelectorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pairs")
                    .font(.headline)
                Spacer()
                Text("\(wifiVM.pairCount) configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Stepper("Total pairs: \(wifiVM.pairCount)", value: Binding(
                get: { wifiVM.pairCount },
                set: { wifiVM.setPairCount($0) }
            ), in: 1...WiFiStreamManager.maxPairs)
                .disabled(wifiVM.isRecording)
            Picker("Active pair (charts)", selection: Binding(
                get: { wifiVM.activePairIndex },
                set: { wifiVM.setActivePairIndex($0) }
            )) {
                ForEach(0..<wifiVM.pairCount, id: \.self) { i in
                    Text("Pair \(i + 1)").tag(i)
                }
            }
            .disabled(wifiVM.isRecording)
            Text("After Stop, tap Save to export the workbook (.xls) or CSV. Each pair gets its own Excel tab. Charts use the active pair only.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .id("dashboard-pairs-\(wifiVM.pairCount)")
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var anyPairBothConnected: Bool {
        (0 ..< wifiVM.pairCount).contains { wifiVM.isPairBothConnected($0) }
    }

    private var recentSessionsCard: some View {
        let sessions = wifiVM.recentSessions.reversed()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent sessions (last 10)")
                    .font(.headline)
                Spacer()
                Text("\(wifiVM.recentSessions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if wifiVM.recentSessions.isEmpty {
                Text("After each Stop, the app auto-saves a multi-tab Excel workbook (.xls) in Documents and keeps the last 10 here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(sessions.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.localCsvFilename)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                            Text("\(s.rowCount) rows · \(s.pairsRecorded) pair(s)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            wifiVM.queueSessionFileExport(named: s.localCsvFilename)
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .help("Export this session CSV")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func csvSessionResultant(rows: [WiFiConnectViewModel.WideSampleRow]) -> String {
        var lines = ["sample_index,rms_ratio_d1_over_d2"]
        for row in rows {
            let raw1 = row.d1.resultantMagnitude
            let raw2 = row.d2.resultantMagnitude
            let eps = 1e-6
            if raw1 <= eps || raw2 <= eps {
                lines.append("\(row.sampleIndex),")
            } else {
                let rmsDiv = Double(SensorReading.fsrChannelCount).squareRoot()
                let ratio = (raw1 / rmsDiv) / (raw2 / rmsDiv)
                lines.append("\(row.sampleIndex),\(ratio)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Quick graphs from the current recording buffer or last stopped capture (same rows as Analysis).
    private var sessionChartsCard: some View {
        let rows = wifiVM.analysisChartRows
        let display = WiFiConnectViewModel.downsampleChartRows(rows, maxPoints: 320)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Session resultant (RMS ratio D1/D2)")
                    .font(.headline)
                Spacer()
                Button {
                    wifiVM.queueCSVExport(
                        text: csvSessionResultant(rows: rows),
                        filename: "session-resultant-\(Int(Date().timeIntervalSince1970)).csv"
                    )
                } label: {
                    Label("Save CSV", systemImage: "square.and.arrow.down")
                }
                .font(.caption)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .accessibilityLabel("Download session resultant CSV")
                .help("Export session resultant as CSV")
                .disabled(rows.isEmpty)
                NavigationLink("Open Analysis") {
                    WiFiAnalysisView()
                }
                .buttonStyle(.bordered)
            }
            if rows.isEmpty {
                Text("Tap Record while both devices stream (or open Analysis after Stop) — this chart uses the recorded session buffer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(rows.count) samples — downsampled to \(display.count) points here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Chart {
                    ForEach(display, id: \.sampleIndex) { row in
                        let raw1 = row.d1.resultantMagnitude
                        let raw2 = row.d2.resultantMagnitude
                        let eps = 1e-6
                        if raw1 > eps, raw2 > eps {
                            let rmsDiv = Double(SensorReading.fsrChannelCount).squareRoot()
                let ratio = (raw1 / rmsDiv) / (raw2 / rmsDiv)
                            LineMark(
                                x: .value("Sample", Double(row.sampleIndex)),
                                y: .value("RMS ratio", ratio)
                            )
                            .foregroundStyle(Color.indigo)
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                        }
                    }
                }
                .chartYScale(domain: 0.5...1.5)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .chartYAxis { AxisMarks(values: [0.5, 0.8, 1.0, 1.2, 1.5]) }
                .frame(height: 160)
                .drawingGroup()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var autoVibrateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $wifiVM.autoVibrateOnMatchedResultant) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto vibrate on matched peaks")
                        .font(.headline)
                    Text("Each connected pair is evaluated separately; both sleeves in a pair must see force. Applies to all pairs, not only the active one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!anyPairBothConnected)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Min resultant (each device)")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2f", wifiVM.autoVibrateMinResultant01))
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $wifiVM.autoVibrateMinResultant01, in: 0...1, step: 0.01)
                    .disabled(!anyPairBothConnected || !wifiVM.autoVibrateOnMatchedResultant)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Resultant ratio band (D1/D2)")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.2f…%.2f", wifiVM.autoVibrateRatioLower, wifiVM.autoVibrateRatioUpper))
                            .font(.caption.monospacedDigit())
                    }
                    RangeSlider(
                        lower: $wifiVM.autoVibrateRatioLower,
                        upper: $wifiVM.autoVibrateRatioUpper,
                        bounds: 0.2...3.0,
                        step: 0.01,
                        minimumDistance: 0.01
                    )
                    .disabled(!anyPairBothConnected || !wifiVM.autoVibrateOnMatchedResultant)
                    Text("Vibrate when RMS ratio stays within the band (default 0.80…1.20).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Vibration intensity")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.0f%%", wifiVM.autoVibrateIntensity * 100))
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $wifiVM.autoVibrateIntensity, in: 0...1, step: 0.01)
                    .disabled(!anyPairBothConnected || !wifiVM.autoVibrateOnMatchedResultant)

                Text("Higher intensity = longer motor pulse (and slightly faster repeat). Min resultant matches Analysis (0…1).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let t = wifiVM.lastAutoVibrateEventAt {
                Text("Last auto pulse: \(t.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct WiFiDeviceCardView: View {
    let title: String
    let slotLabel: String
    @ObservedObject var device: WiFiDeviceConnection
    let onVibrate: () -> Void
    let onReconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text("\(slotLabel) · \(device.deviceIdentifier)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case .connected = device.state {
                    let live = device.isReceivingLiveData
                    HStack(spacing: 6) {
                        Circle().fill(live ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(live ? "Live data" : "Connected — waiting for samples")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Text("State")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(stateText(device.state))
                    .multilineTextAlignment(.trailing)
            }

            if let updated = device.lastUpdated {
                HStack {
                    Text("Last updated")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(updated.formatted(date: .omitted, time: .standard))
                        .monospacedDigit()
                }
            }

            if case .connected = device.state, let r = device.lastReading, let pct = r.batteryPercent {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: batterySymbol(percent: pct))
                        .imageScale(.large)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(pct > 15 ? Color.primary : Color.red)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Battery")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(pct)%")
                                .font(.body.monospacedDigit().weight(.semibold))
                        }
                        ProgressView(value: Double(pct), total: 100)
                            .tint(pct > 20 ? .green : (pct > 10 ? .orange : .red))
                    }
                }
            } else if case .connected = device.state {
                HStack {
                    Text("Battery")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("—")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            vibratorTestSection

            if let r = device.lastReading {
                Text("Epoch: \(r.epochMs)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
                    ForEach(Array(["FSR1","FSR2","FSR3","FSR4","FSR5"].enumerated()), id: \.offset) { i, label in
                        VStack(spacing: 2) {
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(r.fsrValues[i])")
                                .font(.body.monospacedDigit().weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting for data…")
                        .foregroundStyle(.secondary)
                    if case .connected = device.state {
                        Text("If this lasts more than ~12s, tap Reconnect (or cycle ESP32 power).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if device.parseFailureCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Parse failures: \(device.parseFailureCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let last = device.lastParseFailureLine {
                        Text("Last: \(last)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            Button(action: onReconnect) {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .disabled(disableReconnect)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var disableReconnect: Bool {
        if case .connecting = device.state { return true }
        return false
    }

    private var vibratorTestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    onVibrate()
                } label: {
                    Label("Manual vibration", systemImage: "waveform.path")
                }
                .buttonStyle(.bordered)
                .disabled(!isConnectedForVib)
            }
            Text("Logged as M in CSV and charts when recording.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let ack = device.lastVibratorAckAt {
                Text("Manual vibration — board OK at \(ack.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let err = device.lastVibratorSendError, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var isConnectedForVib: Bool {
        if case .connected = device.state { return true }
        return false
    }

    private func stateText(_ s: WiFiDeviceState) -> String {
        switch s {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    /// SF Symbol battery level (iOS 17+ has `battery.100percent` etc.; use stable names).
    private func batterySymbol(percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

private struct WiFiDevicePlaceholderCardView: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text("Disconnected")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

