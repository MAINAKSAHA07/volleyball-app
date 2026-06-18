//
//  WiFiAnalysisView.swift
//  BeeDataLoggerApp
//
//  In-app peak calculation and graphs (Charts) for recorded/streamed data.
//

import SwiftUI
import Charts

struct WiFiAnalysisView: View {
    @EnvironmentObject private var wifiVM: WiFiConnectViewModel

    /// Distinct colors for FSR1…FSR5 (stable across charts).
    private static let fsrChannelColors: [Color] = [
        .blue, .green, .orange, .purple, .pink
    ]

    private var plotRows: [WiFiConnectViewModel.WideSampleRow] { wifiVM.analysisChartRows }

    /// Downsampled for Σ / resultant charts.
    private var displayRows: [WiFiConnectViewModel.WideSampleRow] {
        WiFiConnectViewModel.downsampleChartRows(plotRows, maxPoints: 2000)
    }

    /// FSR charts: 5 series — keep point count lower.
    private var displayRowsFsr: [WiFiConnectViewModel.WideSampleRow] {
        WiFiConnectViewModel.downsampleChartRows(plotRows, maxPoints: 400)
    }

    private struct TapPeakEvent: Identifiable {
        /// Stable across body refreshes (Chart `ForEach`); not persisted in CSV.
        let id: Int
        let peakSampleIndex: Int
        /// Total FSR activity per device (ΣFSR1..5) computed from the same per-channel maxima used for RMS.
        let sumFsr1: Int
        let sumFsr2: Int
        let rms1: Double
        let rms2: Double
        let ratioD1OverD2: Double
    }

    /// Half-width of the RMS window on each side of the impact peak (milliseconds). Adapts to row spacing via device `epochMs`.
    private static let tapRmsHalfWindowMsEachSide: Double = 10

    /// Extract one point per “tap”: threshold defines the event; inside it we find the strongest sample, then RMS from per‑channel maxima in a ±10 ms window around that peak.
    private var tapPeakEvents: [TapPeakEvent] {
        guard !plotRows.isEmpty else { return [] }

        // Use the same normalization constant as the app’s resultant01().
        let rawMax = SensorReading.rawResultantMax()
        // Start when either pad exceeds the “min resultant” force (strong pad gate).
        let startRaw = max(1.0, wifiVM.autoVibrateMinResultant01 * rawMax)
        // End when BOTH pads fall below a fraction (hysteresis) so a single tap becomes one event.
        let endRaw = startRaw * 0.35

        var out: [TapPeakEvent] = []
        out.reserveCapacity(64)

        var inTap = false
        var tapStartIdx = 0
        var nextTapEventId = 0

        func finalizeSegment(endIdx: Int) {
            guard endIdx >= tapStartIdx else { return }
            let segment = Array(plotRows[tapStartIdx ... endIdx])
            if let event = Self.makeTapPeakEvent(
                segment: segment,
                fullSeries: plotRows,
                eventId: nextTapEventId
            ) {
                out.append(event)
                nextTapEventId += 1
            }
        }

        for (idx, row) in plotRows.enumerated() {
            let r1 = row.d1.resultantMagnitude
            let r2 = row.d2.resultantMagnitude
            let peakRawHere = max(r1, r2)

            if !inTap {
                if peakRawHere >= startRaw {
                    inTap = true
                    tapStartIdx = idx
                }
                continue
            }

            // End tap when both are below the hysteresis floor (this row still belongs to the segment).
            if r1 < endRaw, r2 < endRaw {
                finalizeSegment(endIdx: idx)
                inTap = false
            }
        }

        if inTap {
            finalizeSegment(endIdx: plotRows.count - 1)
        }
        return out
    }

    /// Median positive step in `epochMs` (ms) for consecutive rows; ignores gaps & duplicates.
    private static func medianEpochStepMs(epochs: [Int64]) -> Double? {
        guard epochs.count >= 2 else { return nil }
        var deltas: [Double] = []
        deltas.reserveCapacity(epochs.count)
        for i in 1 ..< epochs.count {
            let v = Double(epochs[i] - epochs[i - 1])
            if v > 0.5, v < 250 { deltas.append(v) }
        }
        guard !deltas.isEmpty else { return nil }
        deltas.sort()
        return deltas[deltas.count / 2]
    }

    private static func resolvedMedianDtMs(
        segment: [WiFiConnectViewModel.WideSampleRow],
        fullSeries: [WiFiConnectViewModel.WideSampleRow]
    ) -> Double {
        if let m = medianEpochStepMs(epochs: segment.map(\.d1.epochMs)), m > 0 { return m }
        let head = Array(fullSeries.prefix(min(500, fullSeries.count)))
        if let m = medianEpochStepMs(epochs: head.map(\.d1.epochMs)), m > 0 { return m }
        if segment.count >= 2 {
            let span = Double(segment[segment.count - 1].d1.epochMs - segment[0].d1.epochMs)
            let avg = span / Double(segment.count - 1)
            if avg > 0.5, avg < 250 { return avg }
        }
        // Last resort: ~25 Hz typical Wi‑Fi stream when timestamps are unusable.
        return 40.0
    }

    private static func halfWindowRowSpan(medianDtMs: Double) -> Int {
        guard medianDtMs > 0 else { return 1 }
        return max(1, Int(round(tapRmsHalfWindowMsEachSide / medianDtMs)))
    }

    /// Peak = max(D1,D2 resultant) within the segment; RMS uses per‑channel maxima inside ±`tapRmsHalfWindowMsEachSide` around that peak (clamped). If that window yields a dead pad, falls back to the full segment so a tap still produces a ratio point.
    private static func makeTapPeakEvent(
        segment: [WiFiConnectViewModel.WideSampleRow],
        fullSeries: [WiFiConnectViewModel.WideSampleRow],
        eventId: Int
    ) -> TapPeakEvent? {
        guard !segment.isEmpty else { return nil }

        var peakLocal = 0
        var best = -1.0
        for i in 0 ..< segment.count {
            let v = max(segment[i].d1.resultantMagnitude, segment[i].d2.resultantMagnitude)
            if v >= best {
                best = v
                peakLocal = i
            }
        }

        let dtMs = resolvedMedianDtMs(segment: segment, fullSeries: fullSeries)
        let halfRows = halfWindowRowSpan(medianDtMs: dtMs)
        let lo = max(0, peakLocal - halfRows)
        let hi = min(segment.count - 1, peakLocal + halfRows)

        let eps = 1e-6
        let (sum1w, sum2w, rms1w, rms2w) = featuresFromSegmentRange(segment, lo: lo, hi: hi)
        let (sum1, sum2, rms1, rms2): (Int, Int, Double, Double) = {
            if rms1w > eps, rms2w > eps { return (sum1w, sum2w, rms1w, rms2w) }
            return featuresFromSegmentRange(segment, lo: 0, hi: segment.count - 1)
        }()
        guard rms1 > eps, rms2 > eps else { return nil }
        let ratio = rms1 / rms2
        return TapPeakEvent(
            id: eventId,
            peakSampleIndex: segment[peakLocal].sampleIndex,
            sumFsr1: sum1,
            sumFsr2: sum2,
            rms1: rms1,
            rms2: rms2,
            ratioD1OverD2: ratio
        )
    }

    /// Per‑pad ΣFSR and RMS from per‑channel maxima on `segment[lo...hi]`.
    private static func featuresFromSegmentRange(
        _ segment: [WiFiConnectViewModel.WideSampleRow],
        lo: Int,
        hi: Int
    ) -> (Int, Int, Double, Double) {
        let n = SensorReading.fsrChannelCount
        var d1Max = [Int](repeating: 0, count: n)
        var d2Max = [Int](repeating: 0, count: n)
        for wi in lo ... hi {
            let row = segment[wi]
            for i in 0 ..< n {
                d1Max[i] = max(d1Max[i], row.d1.fsrValues[i])
                d2Max[i] = max(d2Max[i], row.d2.fsrValues[i])
            }
        }
        let sum1 = d1Max.reduce(0, +)
        let sum2 = d2Max.reduce(0, +)
        let a1 = d1Max.map { Double($0) }
        let a2 = d2Max.map { Double($0) }
        let rmsDiv = Double(n)
        let rms1 = (a1.reduce(0.0) { $0 + $1 * $1 } / rmsDiv).squareRoot()
        let rms2 = (a2.reduce(0.0) { $0 + $1 * $1 } / rmsDiv).squareRoot()
        return (sum1, sum2, rms1, rms2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !plotRows.isEmpty, displayRows.count < plotRows.count || displayRowsFsr.count < plotRows.count {
                    Text("Downsampled for rendering (Σ/resultant \(displayRows.count) pts, FSR charts \(displayRowsFsr.count) of \(plotRows.count)); markers use full indices.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("Resultant is RMS ratio (D1/D2). Auto-vibrate triggers when ratio is within 0.8…1.2 and both pads exceed the minimum. Export (⋯) → CSV data or PNG image.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                peakSummary

                combinedChartCard

                resultantChartCard

                fsrChannelsCard(title: "Device 1 — FSR1…FSR5", reading: \.d1, exportBasename: "analysis-fsr-d1")

                fsrChannelsCard(title: "Device 2 — FSR1…FSR5", reading: \.d2, exportBasename: "analysis-fsr-d2")
            }
            .padding()
        }
        .navigationTitle("Analysis")
        .background(Color(.systemGroupedBackground))
    }

    private func presentChartExport(csv: String, basename: String) {
        wifiVM.queueCSVExport(
            text: csv,
            filename: "\(basename)-\(Int(Date().timeIntervalSince1970)).csv"
        )
    }

    private func presentPngExport(data: Data, basename: String) {
        wifiVM.queuePngExport(
            data: data,
            filename: "\(basename)-\(Int(Date().timeIntervalSince1970)).png"
        )
    }

    private func csvCombined() -> String {
        var lines = ["sample_index,sum_fsr_d1,sum_fsr_d2"]
        for row in plotRows {
            lines.append("\(row.sampleIndex),\(WiFiConnectViewModel.sumFSR(row.d1)),\(WiFiConnectViewModel.sumFSR(row.d2))")
        }
        return lines.joined(separator: "\n")
    }

    private func csvResultant() -> String {
        var lines = ["tap_peak_sample_index,sum_fsr_d1,sum_fsr_d2,rms1,rms2,rms_ratio_d1_over_d2"]
        for e in tapPeakEvents {
            lines.append("\(e.peakSampleIndex),\(e.sumFsr1),\(e.sumFsr2),\(e.rms1),\(e.rms2),\(e.ratioD1OverD2)")
        }
        return lines.joined(separator: "\n")
    }

    private func csvFSR(reading: KeyPath<WiFiConnectViewModel.WideSampleRow, SensorReading>) -> String {
        var lines = ["sample_index,fsr1,fsr2,fsr3,fsr4,fsr5"]
        for row in plotRows {
            let r = row[keyPath: reading]
            lines.append("\(row.sampleIndex),\(r.fsr1),\(r.fsr2),\(r.fsr3),\(r.fsr4),\(r.fsr5)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Chart bodies (shared by on-screen cards and PNG export)

    /// Dynamic Y domain so ratio points outside 0.5…1.5 (common for uneven hits) stay visible; always includes the ratio band.
    private var resultantRatioChartYDomain: ClosedRange<Double> {
        var values: [Double] = []
        values.reserveCapacity(tapPeakEvents.count + wifiVM.vibrationMarkers.count + 2)
        values.append(contentsOf: tapPeakEvents.map(\.ratioD1OverD2))
        values.append(contentsOf: wifiVM.vibrationMarkers.map(\.rmsRatioD1OverD2))
        values.append(wifiVM.autoVibrateRatioLower)
        values.append(wifiVM.autoVibrateRatioUpper)
        let loRaw = values.min() ?? 0.5
        let hiRaw = values.max() ?? 1.5
        var lo = loRaw
        var hi = hiRaw
        if hi <= lo { hi = lo + 0.15 }
        let pad = max((hi - lo) * 0.12, 0.05)
        lo = max(0.02, lo - pad)
        hi = hi + pad
        return lo...hi
    }

    @ViewBuilder
    private func combinedChartCore() -> some View {
        Chart {
            ForEach(displayRows, id: \.sampleIndex) { row in
                LineMark(
                    x: .value("Sample", Double(row.sampleIndex)),
                    y: .value("Sum FSR", WiFiConnectViewModel.sumFSR(row.d1))
                )
                .foregroundStyle(by: .value("Device", "Device 1"))
                .lineStyle(StrokeStyle(lineWidth: 1.25))
                LineMark(
                    x: .value("Sample", Double(row.sampleIndex)),
                    y: .value("Sum FSR", WiFiConnectViewModel.sumFSR(row.d2))
                )
                .foregroundStyle(by: .value("Device", "Device 2"))
                .lineStyle(StrokeStyle(lineWidth: 1.25))
            }
            ForEach(wifiVM.vibrationMarkers) { m in
                PointMark(
                    x: .value("Sample", Double(m.sampleIndex)),
                    y: .value("Sum FSR", m.sumFSRMax)
                )
                .symbol(.circle)
                .symbolSize(20)
                .foregroundStyle(m.kind == .manual ? Color.teal : Color.primary)
                .annotation(position: .top, spacing: 2) {
                    Text(m.chartAnnotation)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(m.kind == .manual ? Color.teal : Color.primary)
                }
            }
        }
        .chartForegroundStyleScale(domain: ["Device 1", "Device 2"], range: [.blue, .orange])
        .chartLegend(position: .bottom, alignment: .center)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
    }

    @ViewBuilder
    private func resultantChartCore() -> some View {
        Chart {
            RuleMark(y: .value("Lower", wifiVM.autoVibrateRatioLower))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Color.secondary)
            RuleMark(y: .value("Upper", wifiVM.autoVibrateRatioUpper))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Color.secondary)

            // Tap ratio series (connected line + points) so it reads like a “graph”.
            ForEach(tapPeakEvents) { e in
                LineMark(
                    x: .value("Sample", Double(e.peakSampleIndex)),
                    y: .value("RMS ratio", e.ratioD1OverD2)
                )
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .foregroundStyle(Color.indigo.opacity(0.55))

                PointMark(
                    x: .value("Sample", Double(e.peakSampleIndex)),
                    y: .value("RMS ratio", e.ratioD1OverD2)
                )
                .symbol(.circle)
                .symbolSize(24)
                .foregroundStyle(Color.indigo)
            }

            ForEach(wifiVM.vibrationMarkers) { m in
                PointMark(
                    x: .value("Sample", Double(m.sampleIndex)),
                    y: .value("RMS ratio", m.rmsRatioD1OverD2)
                )
                .symbol(.circle)
                .symbolSize(22)
                .foregroundStyle(vibrationMarkerColor(m))
                .annotation(position: .top, spacing: 2) {
                    Text(m.chartAnnotation)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(vibrationMarkerColor(m))
                }
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: resultantRatioChartYDomain)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
    }

    @ViewBuilder
    private func fsrChartCore(reading: KeyPath<WiFiConnectViewModel.WideSampleRow, SensorReading>) -> some View {
        Chart {
            ForEach(1...SensorReading.fsrChannelCount, id: \.self) { ch in
                ForEach(displayRowsFsr, id: \.sampleIndex) { row in
                    let r = row[keyPath: reading]
                    LineMark(
                        x: .value("Sample", Double(row.sampleIndex)),
                        y: .value("FSR", Self.fsr(r, channel: ch))
                    )
                    .foregroundStyle(by: .value("Channel", "FSR\(ch)"))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.1))
                }
            }
        }
        .chartForegroundStyleScale(
            domain: (1...SensorReading.fsrChannelCount).map { "FSR\($0)" },
            range: Self.fsrChannelColors
        )
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
    }

    private func chartExportMenu(csv: String, csvBasename: String, pngBasename: String, pngExport: @escaping @MainActor () -> Data?) -> some View {
        Menu {
            Button("CSV (data)") {
                presentChartExport(csv: csv, basename: csvBasename)
            }
            Button("PNG (image)") {
                Task { @MainActor in
                    guard let data = pngExport() else { return }
                    presentPngExport(data: data, basename: pngBasename)
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.down")
        }
        .font(.caption)
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .accessibilityLabel("Export chart")
        .help("Export as CSV or PNG image")
        .disabled(plotRows.isEmpty)
    }

    private var peakSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Peaks (raw resultant √(ΣFSR²))")
                .font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Device 1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(peakText(wifiVM.peakD1))
                        .font(.subheadline.monospacedDigit())
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Device 2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(peakText(wifiVM.peakD2))
                        .font(.subheadline.monospacedDigit())
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func peakText(_ p: WiFiConnectViewModel.PeakMetric?) -> String {
        guard let p else { return "—" }
        return String(format: "%.1f @ sample %d", p.maxResultant, p.atSampleIndex)
    }

    private var combinedChartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Total FSR activity (Σ channels)")
                    .font(.headline)
                Spacer()
                Text("\(plotRows.count) samples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                chartExportMenu(
                    csv: csvCombined(),
                    csvBasename: "analysis-sum-fsr",
                    pngBasename: "analysis-sum-fsr",
                    pngExport: {
                        ChartImageExport.pngData(preferredSize: CGSize(width: 920, height: 420)) {
                            combinedChartCore()
                        }
                    }
                )
            }
            Text("X-axis: sample index (CSV).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if plotRows.isEmpty {
                Text("Record, then stop — charts load the last capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                combinedChartCore()
                    .frame(height: 220)
                    .drawingGroup()
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var resultantChartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Resultant (RMS ratio D1/D2)")
                    .font(.headline)
                Spacer()
                Text("\(plotRows.count) samples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                chartExportMenu(
                    csv: csvResultant(),
                    csvBasename: "analysis-resultant",
                    pngBasename: "analysis-resultant",
                    pngExport: {
                        return ChartImageExport.pngData(preferredSize: CGSize(width: 920, height: 400)) {
                            resultantChartCore()
                        }
                    }
                )
            }
            Text("One point per tap: a hit is detected with the same force gate as auto‑vibrate; we find the strongest sample (max D1/D2 resultant), take ±10 ms around it (from device timestamps), then RMS from each FSR’s max in that window. * = auto vibration; M = manual test (dashboard button). Red * = tight ratio (0.95…1.05).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if plotRows.isEmpty {
                Text("Record, then stop — charts load the last capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if tapPeakEvents.isEmpty {
                        Text("No tap ratio points in this capture (peaks stayed below the same minimum as auto‑vibrate, or only one pad saw force). Lower Min resultant on the dashboard and re‑record if you expected hits here.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    resultantChartCore()
                        .frame(height: 200)
                        .drawingGroup()
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func fsrChannelsCard(
        title: String,
        reading: KeyPath<WiFiConnectViewModel.WideSampleRow, SensorReading>,
        exportBasename: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(plotRows.count) samples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                chartExportMenu(
                    csv: csvFSR(reading: reading),
                    csvBasename: exportBasename,
                    pngBasename: exportBasename,
                    pngExport: {
                        ChartImageExport.pngData(preferredSize: CGSize(width: 920, height: 480)) {
                            fsrChartCore(reading: reading)
                        }
                    }
                )
            }
            if plotRows.isEmpty {
                Text("Record, then stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                fsrChartCore(reading: reading)
                    .frame(height: 240)
                    .drawingGroup()
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func vibrationMarkerColor(_ m: WiFiConnectViewModel.VibrationChartMarker) -> Color {
        switch m.kind {
        case .manual: return .teal
        case .auto: return m.isEqualPressure ? .red : .secondary
        }
    }

    private static func fsr(_ r: SensorReading, channel: Int) -> Double {
        guard channel >= 1, channel <= fsrChannelCount else { return 0 }
        return Double(r.fsrValues[channel - 1])
    }

    private static var fsrChannelCount: Int { SensorReading.fsrChannelCount }

    // MARK: - (Removed) equal-pressure range segmentation
    // The resultant is now a *ratio* (RMS D1/D2), so we no longer segment the line into “equal pressure” ranges.
}
