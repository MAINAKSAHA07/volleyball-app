//
//  WiFiConnectViewModel.swift
//  BeeDataLoggerApp
//
//  Holds host/port inputs and manages connecting to two Wi‑Fi devices.
//

import Foundation
import Combine
import Network

final class WiFiConnectViewModel: ObservableObject {
    // Pair 1 legacy fields (still used by some UI); kept in sync with slot arrays.
    @Published var host1: String = ""
    @Published var host2: String = ""
    @Published var port: String = "3333"
    @Published var errorMessage: String?

    @Published private(set) var device1: WiFiDeviceConnection?
    @Published private(set) var device2: WiFiDeviceConnection?

    private let manager = WiFiStreamManager()
    @Published var discovered: [DiscoveredWiFiDevice] = []
    /// Picker selections. Empty string means "not selected".
    @Published var selected1Key: String = ""
    @Published var selected2Key: String = ""
    @Published private(set) var isConnecting: Bool = false

    // MARK: - Multi-pair support (1..5 pairs, 2..10 devices)
    @Published var pairCount: Int = 1
    /// Which pair is “active” for live charts / Analysis (all connected pairs record together).
    @Published var activePairIndex: Int = 0
    private var isNormalizingPairCount = false
    private var isNormalizingActivePairIndex = false

    /// Per-device slot host overrides (slot 0 = Pair1-A, 1 = Pair1-B, 2 = Pair2-A, ...).
    @Published var slotHosts: [String] = Array(repeating: "", count: WiFiStreamManager.maxDevices)
    /// Per-device slot Bonjour selections (DiscoveredWiFiDevice.key).
    @Published var slotSelectedKeys: [String] = Array(repeating: "", count: WiFiStreamManager.maxDevices)
    /// Player wearing each sleeve (slot 0 = Pair1-A, …). Used as Excel tab names / export columns.
    @Published var sleevePlayerNames: [String] = Array(repeating: "", count: WiFiStreamManager.maxDevices)
    private let sleevePlayerNamesDefaultsKey = "sleeve_player_names_v1"

    let discovery = BonjourDiscovery()
    private var cancellables = Set<AnyCancellable>()
    /// Forwards `WiFi…Connection` updates so views reading `wifiVM.device?.state` (e.g. Record button) redraw.
    private var deviceStateSubscriptions = Set<AnyCancellable>()
    @Published private(set) var isBrowsing: Bool = false

    // MARK: - LAN probing (fallback when Bonjour finds nothing)
    enum LanScanState {
        case idle
        case scanning
        case done(Int)
        case failed(String)
        case cancelled
    }

    @Published private(set) var lanScanState: LanScanState = .idle
    @Published private(set) var lanCandidates: [LanCandidate] = []
    @Published private(set) var localIPv4: String = ""

    private let lanScanner = LanPortScanner()

    // MARK: - Recording
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var recordedCount: Int = 0
    @Published var targetSampleRateHz: Int = 500
    private var recordingTimer: DispatchSourceTimer?
    private let recordingQueue = DispatchQueue(label: "com.beedatalogger.recording", qos: .userInitiated)
    /// Set only on `recordingQueue` — safe for receive-driven capture (avoids racing `isRecording` on Main).
    private var isCapturingOnQueue = false
    private var recordedWideRowsByPair: [[WideSampleRow]] = []
    /// Live chart buffer during recording (active pair only, capped for memory).
    @Published private(set) var chartRows: [WideSampleRow] = []
    /// Full-resolution copy of the last finished recording for Analysis (active pair).
    @Published private(set) var lastCompleteRecording: [WideSampleRow] = []
    /// All pairs from the last stop (for multi-pair workbook export).
    @Published private(set) var lastCompleteRecordingByPair: [[WideSampleRow]] = []
    /// Shown on Dashboard after Stop — confirms capture / auto-save or explains empty sessions.
    @Published var lastSaveNotice: String?

    // MARK: - Session archive (last 10, persisted)
    struct RecordingSession: Identifiable, Codable, Equatable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date
        let rowCount: Int
        /// Number of pairs included in `localCsvFilename` (1 for legacy sessions).
        let pairsRecorded: Int
        /// CSV stored in app Documents so it survives restarts.
        let localCsvFilename: String

        enum CodingKeys: String, CodingKey {
            case id, startedAt, endedAt, rowCount, pairsRecorded, localCsvFilename
        }

        init(id: UUID, startedAt: Date, endedAt: Date, rowCount: Int, pairsRecorded: Int, localCsvFilename: String) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.rowCount = rowCount
            self.pairsRecorded = pairsRecorded
            self.localCsvFilename = localCsvFilename
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            startedAt = try c.decode(Date.self, forKey: .startedAt)
            endedAt = try c.decode(Date.self, forKey: .endedAt)
            rowCount = try c.decode(Int.self, forKey: .rowCount)
            localCsvFilename = try c.decode(String.self, forKey: .localCsvFilename)
            pairsRecorded = try c.decodeIfPresent(Int.self, forKey: .pairsRecorded) ?? 1
        }
    }

    @Published private(set) var recentSessions: [RecordingSession] = []
    private let recentSessionsMax = 10
    private let recentSessionsDefaultsKey = "recent_recording_sessions_v1"
    private var activeSessionStartedAt: Date?

    /// Max points kept in `chartRows` while recording (~72 s at 500 Hz). Analysis after Stop uses `lastCompleteRecording` in full.
    private let chartPointCap = 36_000
    /// Hard safety cap per pair to prevent unbounded memory growth on long multi-pair sessions.
    /// At ~150 Hz across 4 pairs this is roughly 45+ minutes of capture; if hit, recording
    /// auto-stops with a clear notice rather than letting the app exhaust memory and crash.
    private let maxRowsPerPairHardCap = 400_000
    /// Flush counters / peaks / chart batch to Main at most this often while recording (~8 Hz).
    private let recordingUIMinInterval: CFTimeInterval = 0.125

    /// Last known sample index per pair, updated off `recordingQueue` so the main-thread
    /// auto-vibrate tick never blocks on `recordingQueue.sync`.
    private var lastKnownSampleIndexByPair: [Int: Int] = [:]
    private var lastKnownRowSnapshotByPair: [Int: (sumFSRMax: Double, ratio: Double)] = [:]
    private let lastKnownSampleIndexLock = NSLock()

    // Receive-driven recording state (pairs two TCP streams reliably).
    private struct ReceiveRecordingState {
        var nextSampleIndex: Int = 1
        var q1: [SensorReading] = []
        var q2: [SensorReading] = []
        var q1Head: Int = 0
        var q2Head: Int = 0
        var epochOffsetD2MinusD1: Int64? = nil
        var peak1: PeakMetric? = nil
        var peak2: PeakMetric? = nil
        var lastUIWallTime: CFTimeInterval = CFAbsoluteTimeGetCurrent()
        var chartBatch: [WideSampleRow] = []
    }

    private var receiveRecordingStatesByPair: [ReceiveRecordingState?] = []
    private var wideRecordModesByPair: [WideRecordMode] = []

    struct PeakMetric: Equatable {
        let maxResultant: Double
        let atEpochMs: Int64
        let atSampleIndex: Int
    }

    @Published private(set) var peakD1: PeakMetric?
    @Published private(set) var peakD2: PeakMetric?

    private let pairingToleranceMs: Int64 = 6
    private let pairingMaxBacklog = 3000
    /// How to build `WideSampleRow`s: both pads paired in time, or one live pad with the other as zeros.
    private enum WideRecordMode: Equatable {
        case dual
        case singleActivePad1
        case singleActivePad2
    }

    struct WideSampleRow {
        let sampleIndex: Int
        let recordedAt: Date
        let d1: SensorReading
        let d2: SensorReading
    }

    /// Rows driving Analysis charts: after Stop, full `lastCompleteRecording`; while recording, live `chartRows` (also full-rate).
    var analysisChartRows: [WideSampleRow] {
        if isRecording { return chartRows }
        return lastCompleteRecording.isEmpty ? chartRows : lastCompleteRecording
    }

    // MARK: - Auto vibrate when both devices’ resultants match
    /// When enabled, pulses both boards’ vibrators on a matched hit (same normalized resultant scale as Analysis: **0…1**).
    @Published var autoVibrateOnMatchedResultant: Bool = true
    /// Minimum **normalized** resultant (0…1) each device must reach before a match can count. Lower = more sensitive.
    @Published var autoVibrateMinResultant01: Double = 0.06
    /// Vibration **intensity** 0…1 (maps to pulse length on firmware; also affects auto-pulse spacing).
    @Published var autoVibrateIntensity: Double = 0.45
    @Published private(set) var lastAutoVibrateEventAt: Date?

    /// Fixed matching behavior (no user sliders). Uses same **0…1** normalization as graphs.
    private let matchAbsTol01 = 0.17
    private let matchRelativeTol = 0.38
    /// Relaxed so a short tap (few samples) still counts as “both participating”.
    private let minBalanceRatioInternal = 0.15
    private let equalAbsFloor01 = 0.019
    private let equalRelativeTol = 0.11
    private let equalBalanceMin = 0.78
    /// For brief impacts, allow the weaker pad to be some fraction of the main pad.
    private let weakPadFactor = 0.40
    /// Ratio band for “matched” dual-pad impacts (RMS D1 / RMS D2). Adjustable on the dashboard.
    @Published var autoVibrateRatioLower: Double = 0.8 { didSet { normalizeRatioBandIfNeeded() } }
    @Published var autoVibrateRatioUpper: Double = 1.2 { didSet { normalizeRatioBandIfNeeded() } }
    /// Tighter band for “equal pressure” (used for marker styling).
    private let equalRatioBand: ClosedRange<Double> = 0.95...1.05

    private var isNormalizingRatioBand = false

    private func normalizeRatioBandIfNeeded() {
        // Prevent didSet -> normalize -> didSet recursion (RangeSlider drags would crash).
        if isNormalizingRatioBand { return }
        isNormalizingRatioBand = true
        defer { isNormalizingRatioBand = false }

        let bounds: ClosedRange<Double> = 0.2...3.0
        var lo = min(max(autoVibrateRatioLower, bounds.lowerBound), bounds.upperBound)
        var hi = min(max(autoVibrateRatioUpper, bounds.lowerBound), bounds.upperBound)
        if hi < lo { swap(&lo, &hi) }
        if hi - lo < 0.01 { hi = min(bounds.upperBound, lo + 0.01) }

        autoVibrateRatioLower = lo
        autoVibrateRatioUpper = hi
    }

    /// Marks vibration events on Analysis charts: * = auto, M = manual test.
    enum VibrationEventKind: String, Equatable {
        case auto
        case manual
    }

    struct VibrationChartMarker: Identifiable {
        let id: UUID
        let kind: VibrationEventKind
        /// 0-based pair index (Pair 1 = 0).
        let pairIndex: Int
        let sampleIndex: Int
        /// For manual tests: 0 = Sleeve A, 1 = Sleeve B within the pair; nil when auto (both sleeves).
        let manualSleeveSide: Int?
        /// RMS ratio D1/D2 at the time of the fire (auto); 0 for manual single-sleeve tests.
        let rmsRatioD1OverD2: Double
        let sumFSRMax: Double
        /// Whether ratio was in the tighter “equal” band at fire time (auto only).
        let isEqualPressure: Bool

        var chartAnnotation: String {
            switch kind {
            case .auto: return "*"
            case .manual: return "M"
            }
        }
    }

    @Published private(set) var vibrationMarkers: [VibrationChartMarker] = []
    private var vibrationMarkersByPair: [Int: [VibrationChartMarker]] = [:]
    private let vibrationMarkersMax = 120
    /// Snapshot at `stopRecording()` for CSV export (all pairs).
    private var vibrationMarkersSnapshotForExport: [VibrationChartMarker] = []

    private var autoVibrateCancellable: AnyCancellable?
    private var lastAutoVibrateFireTimeByPair: [Int: CFTimeInterval] = [:]
    /// Auto‑vibrate poll: 0.04 s (~25 Hz). Rolling per‑device max (see WiFiDeviceConnection) does most of the work for taps.
    private let autoVibrateTickSeconds: TimeInterval = 0.04

    /// Pulse length 60…300 ms from intensity slider (ESP32 clamps to 30…500).
    func vibratorPulseMs() -> UInt16 {
        let t = min(1, max(0, autoVibrateIntensity))
        let ms = 60 + (300 - 60) * t
        return UInt16(ms)
    }

    func sendVibratorTest(atSlot slot: Int) {
        device(atSlot: slot)?.sendVibratorTest(pulseMilliseconds: vibratorPulseMs())
        recordManualVibration(atSlot: slot)
    }

    private func appendVibrationMarker(_ marker: VibrationChartMarker) {
        let pairIndex = marker.pairIndex
        var list = vibrationMarkersByPair[pairIndex] ?? []
        list.append(marker)
        if list.count > vibrationMarkersMax {
            list.removeFirst(list.count - vibrationMarkersMax)
        }
        vibrationMarkersByPair[pairIndex] = list
        if pairIndex == activePairIndex {
            vibrationMarkers = list
        }
    }

    private func recordManualVibration(atSlot slot: Int) {
        guard slot >= 0, slot < pairCount * 2 else { return }
        guard isRecording else { return }
        let pairIndex = slot / 2
        let sleeveSide = slot % 2

        lastKnownSampleIndexLock.lock()
        let sampleIndex = lastKnownSampleIndexByPair[pairIndex] ?? 1
        let snapshot = lastKnownRowSnapshotByPair[pairIndex]
        lastKnownSampleIndexLock.unlock()

        let sumMax = snapshot?.sumFSRMax ?? 0.0
        let ratio = snapshot?.ratio ?? 0.0

        appendVibrationMarker(
            VibrationChartMarker(
                id: UUID(),
                kind: .manual,
                pairIndex: pairIndex,
                sampleIndex: sampleIndex,
                manualSleeveSide: sleeveSide,
                rmsRatioD1OverD2: ratio,
                sumFSRMax: sumMax,
                isEqualPressure: false
            )
        )
    }

    private func vibrateCooldownSeconds() -> TimeInterval {
        let t = min(1, max(0, autoVibrateIntensity))
        // Shorter floor so repeated taps (ball contacts) aren’t swallowed as often as long‑press testing.
        return 0.09 - 0.05 * t
    }

    /// Connection for a sleeve slot (0 = Pair1-A, 1 = Pair1-B, 2 = Pair2-A, …).
    func device(atSlot slot: Int) -> WiFiDeviceConnection? {
        manager.device(at: slot)
    }

    func isPairBothConnected(_ pairIndex: Int) -> Bool {
        guard pairIndex >= 0, pairIndex < pairCount else { return false }
        let a = pairIndex * 2
        guard case .connected = device(atSlot: a)?.state,
              case .connected = device(atSlot: a + 1)?.state else { return false }
        return true
    }

    func anySlotConnected() -> Bool {
        for slot in 0 ..< pairCount * 2 {
            if case .connected = device(atSlot: slot)?.state { return true }
        }
        return false
    }

    private func bindDeviceStateForwarding() {
        deviceStateSubscriptions.removeAll()
        let recordingSlots = Set((0 ..< pairCount * 2))
        for slot in 0 ..< pairCount * 2 {
            guard let dev = manager.device(at: slot) else { continue }
            dev.objectWillChange
                .receive(on: DispatchQueue.main)
                .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] (_: Void) in
                    self?.objectWillChange.send()
                }
                .store(in: &deviceStateSubscriptions)

            guard recordingSlots.contains(slot) else { continue }
            dev.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newState in
                    guard let self else { return }
                    guard self.isRecording else { return }
                    switch newState {
                    case .disconnected, .failed:
                        self.stopRecordingDueToConnectionLoss()
                    default:
                        break
                    }
                }
                .store(in: &deviceStateSubscriptions)
        }
    }

    init() {
        discovery.$devices
            .receive(on: DispatchQueue.main)
            .assign(to: &$discovered)

        discovery.$isBrowsing
            .receive(on: DispatchQueue.main)
            .assign(to: &$isBrowsing)

        loadRecentSessions()
        loadSleevePlayerNames()
        refreshActivePairDevices()

        manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (_: Void) in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Use from UI (Stepper/Picker) instead of writing `pairCount` directly — avoids broken `@Published` updates from `didSet`.
    func setPairCount(_ newValue: Int) {
        if isNormalizingPairCount { return }
        isNormalizingPairCount = true
        defer { isNormalizingPairCount = false }

        let clamped = min(WiFiStreamManager.maxPairs, max(1, newValue))
        pairCount = clamped
        if activePairIndex >= pairCount {
            setActivePairIndex(pairCount - 1)
        } else {
            bindDeviceStateForwarding()
        }
    }

    func setActivePairIndex(_ newValue: Int) {
        if isNormalizingActivePairIndex { return }
        isNormalizingActivePairIndex = true
        defer { isNormalizingActivePairIndex = false }

        var idx = newValue
        if idx < 0 { idx = 0 }
        if idx >= pairCount { idx = max(0, pairCount - 1) }
        guard idx != activePairIndex else { return }
        activePairIndex = idx
        refreshActivePairDevices()
        bindDeviceStateForwarding()
        if isRecording {
            syncActivePairRecordingUI()
        }
    }

    /// Refresh live charts / peaks for the active pair while a multi-pair session is running.
    private func syncActivePairRecordingUI() {
        let pair = activePairIndex
        vibrationMarkers = vibrationMarkersByPair[pair] ?? []
        recordingQueue.async { [weak self] in
            guard let self else { return }
            let rows = self.recordedWideRowsByPair.indices.contains(pair) ? self.recordedWideRowsByPair[pair] : []
            let st = self.receiveRecordingStatesByPair.indices.contains(pair) ? self.receiveRecordingStatesByPair[pair] : nil
            DispatchQueue.main.async {
                self.peakD1 = st?.peak1
                self.peakD2 = st?.peak2
                let limit = self.chartPointCap
                if rows.count > limit {
                    self.chartRows = Array(rows.suffix(limit))
                } else {
                    self.chartRows = rows
                }
            }
        }
    }

    private func wireAllRecordingCallbacks() {
        lastKnownSampleIndexLock.lock()
        lastKnownSampleIndexByPair.removeAll()
        lastKnownRowSnapshotByPair.removeAll()
        lastKnownSampleIndexLock.unlock()

        for pair in 0 ..< pairCount {
            let aSlot = pair * 2
            let bSlot = aSlot + 1
            device(atSlot: aSlot)?.onParsedReading = { [weak self] reading in
                self?.handleIncomingReading(pairIndex: pair, device: 1, reading: reading)
            }
            device(atSlot: bSlot)?.onParsedReading = { [weak self] reading in
                self?.handleIncomingReading(pairIndex: pair, device: 2, reading: reading)
            }
        }
    }

    private func clearAllRecordingCallbacks() {
        for slot in 0 ..< pairCount * 2 {
            device(atSlot: slot)?.onParsedReading = nil
        }
    }

    private func sendRecCommandToAllConnected(_ command: String) {
        for slot in 0 ..< pairCount * 2 {
            guard let d = device(atSlot: slot), case .connected = d.state else { continue }
            d.sendControlCommand(command)
        }
    }

    private func totalRecordedRowCount() -> Int {
        recordedWideRowsByPair.reduce(0) { $0 + $1.count }
    }

    private func pairsWithRecordedData() -> Int {
        recordedWideRowsByPair.filter { !$0.isEmpty }.count
    }

    func setSlotHost(_ host: String, slot: Int) {
        guard slot >= 0, slot < slotHosts.count else { return }
        var copy = slotHosts
        copy[slot] = host
        slotHosts = copy
        if slot == 0 { host1 = host }
        if slot == 1 { host2 = host }
    }

    func setSlotSelectedKey(_ key: String, slot: Int) {
        guard slot >= 0, slot < slotSelectedKeys.count else { return }
        var copy = slotSelectedKeys
        copy[slot] = key
        slotSelectedKeys = copy
        if slot == 0 { selected1Key = key }
        if slot == 1 { selected2Key = key }
    }

    func setSleevePlayerName(_ name: String, slot: Int) {
        guard slot >= 0, slot < sleevePlayerNames.count else { return }
        var copy = sleevePlayerNames
        copy[slot] = name
        sleevePlayerNames = copy
        persistSleevePlayerNames()
    }

    func sleevePlayerName(slot: Int) -> String {
        guard slot >= 0, slot < sleevePlayerNames.count else { return "" }
        return sleevePlayerNames[slot]
    }

    /// Excel worksheet tab title for a pair (from player names, else "Pair N").
    func pairSheetTitle(pairIndex: Int) -> String {
        let a = sleevePlayerName(slot: pairIndex * 2).trimmingCharacters(in: .whitespacesAndNewlines)
        let b = sleevePlayerName(slot: pairIndex * 2 + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if !a.isEmpty, !b.isEmpty { title = "\(a) vs \(b)" }
        else if !a.isEmpty { title = a }
        else if !b.isEmpty { title = b }
        else { title = "Pair \(pairIndex + 1)" }
        return RecordingWorkbookBuilder.sanitizeSheetName(title)
    }

    private func loadSleevePlayerNames() {
        if let saved = UserDefaults.standard.stringArray(forKey: sleevePlayerNamesDefaultsKey),
           saved.count == WiFiStreamManager.maxDevices {
            sleevePlayerNames = saved
        }
    }

    private func persistSleevePlayerNames() {
        UserDefaults.standard.set(sleevePlayerNames, forKey: sleevePlayerNamesDefaultsKey)
    }

    private func refreshActivePairDevices() {
        let base = activePairIndex * 2
        device1 = manager.device(at: base)
        device2 = manager.device(at: base + 1)
        bindDeviceStateForwarding()
    }

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private func loadRecentSessions() {
        guard let data = UserDefaults.standard.data(forKey: recentSessionsDefaultsKey) else { return }
        if let decoded = try? JSONDecoder().decode([RecordingSession].self, from: data) {
            recentSessions = decoded
        }
    }

    private func persistRecentSessions() {
        if let data = try? JSONEncoder().encode(recentSessions) {
            UserDefaults.standard.set(data, forKey: recentSessionsDefaultsKey)
        }
    }

    private func pruneRecentSessionsIfNeeded() {
        guard recentSessions.count > recentSessionsMax else { return }
        let overflow = recentSessions.count - recentSessionsMax
        let toRemove = recentSessions.prefix(overflow)
        for s in toRemove {
            let url = documentsDirectory().appendingPathComponent(s.localCsvFilename)
            try? FileManager.default.removeItem(at: url)
        }
        recentSessions.removeFirst(overflow)
    }

    private func autoSaveSessionWorkbook(rowsByPair: [[WideSampleRow]], startedAt: Date, endedAt: Date) -> RecordingSession? {
        let totalRows = rowsByPair.reduce(0) { $0 + $1.count }
        guard totalRows > 0 else { return nil }
        let data = makeRecordingWorkbookData(rowsByPair, vibrationMarkers: vibrationMarkersSnapshotForExport)
        let ts = Int(endedAt.timeIntervalSince1970)
        let filename = "bdl-recording-\(ts).xls"
        let url = documentsDirectory().appendingPathComponent(filename)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to save session workbook: \(error.localizedDescription)"
            }
            return nil
        }
        return RecordingSession(
            id: UUID(),
            startedAt: startedAt,
            endedAt: endedAt,
            rowCount: totalRows,
            pairsRecorded: rowsByPair.filter { !$0.isEmpty }.count,
            localCsvFilename: filename
        )
    }

    func startDiscovery() {
        discovery.start()
    }

    func stopDiscovery() {
        discovery.stop()
    }

    func connect() {
        errorMessage = nil
        isConnecting = true
        defer { DispatchQueue.main.async { self.isConnecting = false } }

        // Keep legacy fields mirrored into Pair 1 slots so old UI still works.
        slotHosts[0] = host1
        slotHosts[1] = host2
        slotSelectedKeys[0] = selected1Key
        slotSelectedKeys[1] = selected2Key

        let p = UInt16(port) ?? 3333
        guard let nwPort = NWEndpoint.Port(rawValue: p) else {
            errorMessage = "Invalid port"
            return
        }

        func endpointForSlot(_ slot: Int) -> NWEndpoint? {
            let key = slotSelectedKeys[slot].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, let d = discovered.first(where: { $0.key == key }) {
                return d.endpoint
            }
            let host = slotHosts[slot].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return nil }
            return NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }

        func endpointIdentity(_ slot: Int) -> String? {
            let key = slotSelectedKeys[slot].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return "bonjour:\(key)" }
            let host = slotHosts[slot].trimmingCharacters(in: .whitespacesAndNewlines)
            if !host.isEmpty { return "host:\(host.lowercased())" }
            return nil
        }

        var any = false
        var usedIdentities: [String: Int] = [:]
        for pair in 0..<pairCount {
            let aSlot = pair * 2
            let bSlot = aSlot + 1
            for slot in [aSlot, bSlot] {
                guard let e = endpointForSlot(slot) else { continue }
                if let id = endpointIdentity(slot) {
                    if let otherSlot = usedIdentities[id] {
                        errorMessage = "Sleeve slot \(slot + 1) uses the same device as slot \(otherSlot + 1). Each sleeve needs its own board."
                        return
                    }
                    usedIdentities[id] = slot
                }
                manager.connectOne(endpoint: e, slot: slot)
                any = true
            }
        }
        guard any else {
            errorMessage = "Select at least one sleeve to connect (1–\(WiFiStreamManager.maxPairs) pairs)."
            return
        }

        refreshActivePairDevices()
        bindDeviceStateForwarding()
        installAutoVibrateTimer()
        objectWillChange.send()
    }

    // Start TCP port scan on the local subnet to find stream servers on port 3333.
    // This is faster than guessing IPs, and works even when Bonjour is failing.
    func scanLANForServers() {
        lanCandidates = []
        lanScanState = .scanning

        guard let info = lanScanner.currentIPv4Info() else {
            lanScanState = .failed("Could not determine local IPv4 subnet")
            return
        }
        localIPv4 = info.localIP

        lanScanner.scanTCPPort(
            port: UInt16(port) ?? 3333,
            timeout: 0.25,
            concurrency: 28,
            onCandidate: { [weak self] candidate in
                guard let self else { return }
                if !self.lanCandidates.contains(candidate) {
                    self.lanCandidates.append(candidate)
                }
            },
            onComplete: { [weak self] foundCount in
                guard let self else { return }
                switch self.lanScanState {
                case .cancelled:
                    break
                default:
                    self.lanScanState = .done(foundCount)
                }
            }
        )
    }

    func cancelLANScan() {
        lanScanner.cancel()
        lanScanState = .cancelled
    }

    func useCandidate(_ candidate: LanCandidate, asDevice index: Int) {
        let base = activePairIndex * 2
        let slot = index == 1 ? base : base + 1
        setSlotHost(candidate.ip, slot: slot)
        setSlotSelectedKey("", slot: slot)
    }

    func disconnectAll() {
        stopRecordingInternal()
        removeAutoVibrateTimer()
        deviceStateSubscriptions.removeAll()
        vibrationMarkers = []
        vibrationMarkersByPair = [:]
        vibrationMarkersSnapshotForExport = []
        manager.disconnectAll()
        device1 = nil
        device2 = nil
    }

    private func installAutoVibrateTimer() {
        removeAutoVibrateTimer()
        // Use `.common` so hits aren’t missed while scrolling; tick is light (envelope + compare only).
        autoVibrateCancellable = Timer.publish(every: autoVibrateTickSeconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tickAutoVibrateFromMatchedResultant()
            }
    }

    private func removeAutoVibrateTimer() {
        autoVibrateCancellable?.cancel()
        autoVibrateCancellable = nil
    }

    private func tickAutoVibrateFromMatchedResultant() {
        guard autoVibrateOnMatchedResultant else { return }
        for pair in 0 ..< pairCount {
            tickAutoVibrateForPair(pair)
        }
    }

    private func tickAutoVibrateForPair(_ pairIndex: Int) {
        let aSlot = pairIndex * 2
        let bSlot = aSlot + 1
        guard let d1 = device(atSlot: aSlot), let d2 = device(atSlot: bSlot) else { return }
        guard case .connected = d1.state, case .connected = d2.state else { return }
        guard let s1 = d1.latestSampleForRecording(), let s2 = d2.latestSampleForRecording() else { return }

        let peakRaw1 = d1.consumePeakRawResultantSinceLastTick()
        let peakRaw2 = d2.consumePeakRawResultantSinceLastTick()
        let roll1 = d1.maxRawMagnitudeInRollingWindow()
        let roll2 = d2.maxRawMagnitudeInRollingWindow()
        let raw1 = max(s1.resultantMagnitude, peakRaw1, roll1)
        let raw2 = max(s2.resultantMagnitude, peakRaw2, roll2)

        let n1 = Self.normalizedRawResultant01(rawResultant: raw1)
        let n2 = Self.normalizedRawResultant01(rawResultant: raw2)
        let hiN = max(n1, n2)
        let loN = min(n1, n2)
        guard hiN > 0, loN > 0 else { return }

        let minHi = autoVibrateMinResultant01
        let minLo = autoVibrateMinResultant01 * weakPadFactor
        guard hiN >= minHi, loN >= minLo else { return }

        let eps = 1e-6
        let rmsDiv = Double(SensorReading.fsrChannelCount).squareRoot()
        let rms1 = raw1 / rmsDiv
        let rms2 = raw2 / rmsDiv
        guard rms1 > eps, rms2 > eps else { return }
        let ratio = rms1 / rms2
        let ratioBand = autoVibrateRatioLower...autoVibrateRatioUpper
        guard ratioBand.contains(ratio) else { return }
        let equalPressure = equalRatioBand.contains(ratio)

        let now = CFAbsoluteTimeGetCurrent()
        let lastFire = lastAutoVibrateFireTimeByPair[pairIndex] ?? 0
        guard now - lastFire >= vibrateCooldownSeconds() else { return }
        lastAutoVibrateFireTimeByPair[pairIndex] = now
        lastAutoVibrateEventAt = Date()

        let sumMax = max(Self.sumFSR(s1), Self.sumFSR(s2))
        if isRecording {
            let idx = latestPairedSampleIndexForVibrationMarker(pairIndex: pairIndex)
            let marker = VibrationChartMarker(
                id: UUID(),
                kind: .auto,
                pairIndex: pairIndex,
                sampleIndex: idx,
                manualSleeveSide: nil,
                rmsRatioD1OverD2: ratio,
                sumFSRMax: sumMax,
                isEqualPressure: equalPressure
            )
            appendVibrationMarker(marker)
        }
        let pulse = vibratorPulseMs()
        d1.sendVibratorTest(pulseMilliseconds: pulse)
        d2.sendVibratorTest(pulseMilliseconds: pulse)
    }

    func startRecording() {
        stopRecordingInternal()

        let count = pairCount
        let modes = (0 ..< count).map { pair in
            Self.resolveWideRecordMode(
                device1: device(atSlot: pair * 2),
                device2: device(atSlot: pair * 2 + 1)
            )
        }
        recordingQueue.sync {
            recordedWideRowsByPair = Array(repeating: [], count: count)
            wideRecordModesByPair = modes
            receiveRecordingStatesByPair = Array(repeating: ReceiveRecordingState(), count: count)
            isCapturingOnQueue = true
        }

        lastSaveNotice = nil
        vibrationMarkers = []
        vibrationMarkersByPair = [:]
        vibrationMarkersSnapshotForExport = []
        lastAutoVibrateFireTimeByPair = [:]
        chartRows.removeAll(keepingCapacity: true)
        lastCompleteRecording = []
        lastCompleteRecordingByPair = []
        peakD1 = nil
        peakD2 = nil
        recordedCount = 0
        activeSessionStartedAt = Date()

        wireAllRecordingCallbacks()
        isRecording = true
        sendRecCommandToAllConnected("REC START")
    }

    func stopRecording() -> String {
        isRecording = false
        let stoppedAt = Date()
        sendRecCommandToAllConnected("REC STOP")

        let rowsByPair: [[WideSampleRow]] = recordingQueue.sync {
            isCapturingOnQueue = false
            return recordedWideRowsByPair
        }
        stopRecordingInternal()

        lastCompleteRecordingByPair = rowsByPair
        vibrationMarkersSnapshotForExport = vibrationMarkersByPair.values.flatMap { $0 }
        let activeRows = rowsByPair.indices.contains(activePairIndex) ? rowsByPair[activePairIndex] : []
        lastCompleteRecording = activeRows

        let totalRows = rowsByPair.reduce(0) { $0 + $1.count }
        let startedAt = activeSessionStartedAt ?? stoppedAt
        activeSessionStartedAt = nil
        if let session = autoSaveSessionWorkbook(rowsByPair: rowsByPair, startedAt: startedAt, endedAt: stoppedAt) {
            recentSessions.append(session)
            pruneRecentSessionsIfNeeded()
            persistRecentSessions()
            lastSaveNotice = "Captured \(session.rowCount) rows across \(session.pairsRecorded) pair(s). Auto-saved as \(session.localCsvFilename). Tap Save to export another copy."
        } else if totalRows == 0 {
            lastSaveNotice = "No samples were captured. Connect sleeves, confirm live FSR values update, then Record again."
        } else {
            lastSaveNotice = "Captured \(totalRows) rows. Tap Save to export the workbook."
        }
        return ""
    }

    /// Whether a finished capture exists and can be saved (no auto-save on Stop).
    var canExportLastRecording: Bool {
        !lastCompleteRecordingByPair.allSatisfy(\.isEmpty) && !isRecording
    }

    /// Multi-tab Excel workbook (.xls) — one worksheet per pair with all FSR columns.
    func workbookDataForLastRecording() -> Data {
        makeRecordingWorkbookData(lastCompleteRecordingByPair, vibrationMarkers: vibrationMarkersSnapshotForExport)
    }

    func workbookDataForSessionFile(named filename: String) -> Data? {
        let url = documentsDirectory().appendingPathComponent(filename)
        return try? Data(contentsOf: url)
    }

    /// CSV for the active pair (fallback when Excel share is unavailable).
    func csvStringForLastRecording() -> String? {
        guard !lastCompleteRecording.isEmpty else { return nil }
        let markers = vibrationMarkersSnapshotForExport.filter { $0.pairIndex == activePairIndex }
        return makeWideCSV(lastCompleteRecording, vibrationMarkers: markers)
    }

    // MARK: - File export (UIDocumentPicker on `ContentView`)

    @Published var showDocumentExport = false
    private(set) var documentExportURL: URL?

    func finishDocumentExport() {
        ExportStaging.cleanup(documentExportURL)
        documentExportURL = nil
        showDocumentExport = false
    }

    /// Copy an on-device session file into the export picker (does not delete the archived original).
    func queueSessionFileExport(named filename: String) {
        let url = documentsDirectory().appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Session file missing on device: \(filename)"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            queueDataExport(data: data, filename: filename)
        } catch {
            errorMessage = "Could not read session file: \(error.localizedDescription)"
        }
    }

    func queueWorkbookExport(data: Data, filename: String) {
        if !RecordingWorkbookBuilder.containsWorksheets(data) {
            if let csv = csvStringForLastRecording() {
                queueCSVExport(text: csv, filename: filename.replacingOccurrences(of: ".xls", with: ".csv"))
                return
            }
            errorMessage = "No recording rows to export. Record live data, tap Stop, then try again."
            return
        }
        queueDataExport(data: data, filename: filename)
    }

    func queueCSVExport(text: String, filename: String) {
        guard !text.isEmpty else {
            errorMessage = "No data to export."
            return
        }
        do {
            documentExportURL = try ExportStaging.write(text: text, filename: filename)
            showDocumentExport = false
            DispatchQueue.main.async { [weak self] in
                self?.showDocumentExport = true
            }
        } catch {
            errorMessage = "Could not prepare CSV export: \(error.localizedDescription)"
        }
    }

    func queuePngExport(data: Data, filename: String) {
        guard !data.isEmpty else {
            errorMessage = "Could not render chart image."
            return
        }
        queueDataExport(data: data, filename: filename)
    }

    private func queueDataExport(data: Data, filename: String) {
        do {
            documentExportURL = try ExportStaging.write(data: data, filename: filename)
            showDocumentExport = false
            DispatchQueue.main.async { [weak self] in
                self?.showDocumentExport = true
            }
        } catch {
            errorMessage = "Could not prepare export: \(error.localizedDescription)"
        }
    }

    private func stopRecordingInternal() {
        isRecording = false
        recordingTimer?.cancel()
        recordingTimer = nil
        clearAllRecordingCallbacks()

        recordingQueue.sync {
            isCapturingOnQueue = false
            recordedWideRowsByPair = []
            wideRecordModesByPair = []
            receiveRecordingStatesByPair = []
        }
    }

    private func stopRecordingDueToConnectionLoss() {
        // Avoid recursion if multiple devices publish disconnect.
        guard isRecording else { return }
        _ = stopRecording()
    }

    private func handleIncomingReading(pairIndex: Int, device: Int, reading: SensorReading) {
        recordingQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCapturingOnQueue else { return }
            guard pairIndex >= 0, pairIndex < self.receiveRecordingStatesByPair.count,
                  var st = self.receiveRecordingStatesByPair[pairIndex] else { return }
            let mode = self.wideRecordModesByPair.indices.contains(pairIndex)
                ? self.wideRecordModesByPair[pairIndex]
                : .dual

            switch mode {
            case .singleActivePad1:
                guard device == 1 else { return }
                let r1 = reading
                let r2 = Self.zeroComplementPadReading(matching: r1, pairIndex: pairIndex, inactiveIsDevice2: true)
                self.appendPairedRowToState(pairIndex: pairIndex, r1: r1, r2: r2, st: &st)
                self.maybeFlushRecordingUIFromState(pairIndex: pairIndex, st: &st)
                self.receiveRecordingStatesByPair[pairIndex] = st
                return
            case .singleActivePad2:
                guard device == 2 else { return }
                let r2 = reading
                let r1 = Self.zeroComplementPadReading(matching: r2, pairIndex: pairIndex, inactiveIsDevice2: false)
                self.appendPairedRowToState(pairIndex: pairIndex, r1: r1, r2: r2, st: &st)
                self.maybeFlushRecordingUIFromState(pairIndex: pairIndex, st: &st)
                self.receiveRecordingStatesByPair[pairIndex] = st
                return
            case .dual:
                break
            }

            func push(_ q: inout [SensorReading], head: inout Int, r: SensorReading) {
                q.append(r)
                // prevent unbounded backlog if one device stalls
                let liveCount = q.count - head
                if liveCount > self.pairingMaxBacklog {
                    head = q.count - self.pairingMaxBacklog
                }
                // occasionally compact
                if head > 1024 {
                    q.removeFirst(head)
                    head = 0
                }
            }

            if device == 1 {
                push(&st.q1, head: &st.q1Head, r: reading)
            } else {
                push(&st.q2, head: &st.q2Head, r: reading)
            }

            // Establish epoch offset once we have at least one reading from both.
            if st.epochOffsetD2MinusD1 == nil,
               st.q1.count > st.q1Head,
               st.q2.count > st.q2Head {
                let d1e = st.q1[st.q1Head].epochMs
                let d2e = st.q2[st.q2Head].epochMs
                st.epochOffsetD2MinusD1 = d2e - d1e
            }

            let offset = st.epochOffsetD2MinusD1 ?? 0

            // Pair as long as both queues have data.
            while st.q1.count > st.q1Head, st.q2.count > st.q2Head {
                let r1 = st.q1[st.q1Head]
                let r2 = st.q2[st.q2Head]
                let t1 = r1.epochMs
                let t2Adj = r2.epochMs - offset
                let diff = t2Adj - t1

                if abs(diff) <= self.pairingToleranceMs {
                    // Pair these.
                    st.q1Head += 1
                    st.q2Head += 1
                    self.appendPairedRowToState(pairIndex: pairIndex, r1: r1, r2: r2, st: &st)
                } else if diff > self.pairingToleranceMs {
                    st.q1Head += 1
                } else {
                    st.q2Head += 1
                }
            }

            self.maybeFlushRecordingUIFromState(pairIndex: pairIndex, st: &st)
            self.receiveRecordingStatesByPair[pairIndex] = st
        }
    }

    private func appendPairedRowToState(pairIndex: Int, r1: SensorReading, r2: SensorReading, st: inout ReceiveRecordingState) {
        let idx = st.nextSampleIndex
        st.nextSampleIndex += 1
        let row = WideSampleRow(sampleIndex: idx, recordedAt: Date(), d1: r1, d2: r2)
        if recordedWideRowsByPair.indices.contains(pairIndex) {
            recordedWideRowsByPair[pairIndex].append(row)
        }
        st.chartBatch.append(row)

        let sumMax = max(Self.sumFSR(r1), Self.sumFSR(r2))
        var rowRatio = 0.0
        let raw1 = r1.resultantMagnitude
        let raw2 = r2.resultantMagnitude
        let eps = 1e-6
        if raw1 > eps, raw2 > eps {
            let rmsDiv = Double(SensorReading.fsrChannelCount).squareRoot()
            rowRatio = (raw1 / rmsDiv) / (raw2 / rmsDiv)
        }
        lastKnownSampleIndexLock.lock()
        lastKnownSampleIndexByPair[pairIndex] = idx
        lastKnownRowSnapshotByPair[pairIndex] = (sumFSRMax: sumMax, ratio: rowRatio)
        lastKnownSampleIndexLock.unlock()

        if recordedWideRowsByPair.indices.contains(pairIndex),
           recordedWideRowsByPair[pairIndex].count >= maxRowsPerPairHardCap {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRecording else { return }
                self.lastSaveNotice = "Recording auto-stopped: pair \(pairIndex + 1) reached the maximum session length (memory safety limit). Data captured so far has been saved — start a new recording to continue."
                _ = self.stopRecording()
            }
        }

        let res1 = Self.resultant(r1)
        let res2 = Self.resultant(r2)
        if let p = st.peak1 {
            if res1 > p.maxResultant { st.peak1 = PeakMetric(maxResultant: res1, atEpochMs: r1.epochMs, atSampleIndex: idx) }
        } else {
            st.peak1 = PeakMetric(maxResultant: res1, atEpochMs: r1.epochMs, atSampleIndex: idx)
        }
        if let p = st.peak2 {
            if res2 > p.maxResultant { st.peak2 = PeakMetric(maxResultant: res2, atEpochMs: r2.epochMs, atSampleIndex: idx) }
        } else {
            st.peak2 = PeakMetric(maxResultant: res2, atEpochMs: r2.epochMs, atSampleIndex: idx)
        }
    }

    private func maybeFlushRecordingUIFromState(pairIndex: Int, st: inout ReceiveRecordingState) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - st.lastUIWallTime < recordingUIMinInterval { return }
        st.lastUIWallTime = now
        let totalCnt = totalRecordedRowCount()
        let pCopy1 = st.peak1
        let pCopy2 = st.peak2
        let batch = st.chartBatch
        st.chartBatch.removeAll(keepingCapacity: true)
        let isActive = pairIndex == activePairIndex
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recordedCount = totalCnt
            guard isActive else { return }
            self.peakD1 = pCopy1
            self.peakD2 = pCopy2
            if !batch.isEmpty {
                self.chartRows.append(contentsOf: batch)
                let limit = self.chartPointCap
                if self.chartRows.count > limit {
                    self.chartRows.removeFirst(self.chartRows.count - limit)
                }
            }
        }
    }

    private static func isDeviceConnectedForRecording(_ d: WiFiDeviceConnection?) -> Bool {
        guard let d else { return false }
        if case .connected = d.state { return true }
        return false
    }

    private static func resolveWideRecordMode(device1: WiFiDeviceConnection?, device2: WiFiDeviceConnection?) -> WideRecordMode {
        let c1 = isDeviceConnectedForRecording(device1)
        let c2 = isDeviceConnectedForRecording(device2)
        if c1 && c2 { return .dual }
        if c1 && !c2 { return .singleActivePad1 }
        if !c1 && c2 { return .singleActivePad2 }
        return .dual
    }

    /// Zeros the inactive pad’s FSRs so wide CSV and charts stay 5+5; epoch matches the live board.
    private static func zeroComplementPadReading(matching r: SensorReading, pairIndex: Int, inactiveIsDevice2: Bool) -> SensorReading {
        let slot = pairIndex * 2 + (inactiveIsDevice2 ? 1 : 0)
        return SensorReading(
            epochMs: r.epochMs,
            fsr1: 0, fsr2: 0, fsr3: 0, fsr4: 0, fsr5: 0,
            batteryPercent: nil,
            deviceIdentifier: "wifi-slot-\(slot)",
            receivedAt: r.receivedAt
        )
    }

    /// Latest paired wide-row `sample_index` for aligning auto-vibrate markers with exported CSV rows.
    private func latestPairedSampleIndexForVibrationMarker(pairIndex: Int) -> Int {
        lastKnownSampleIndexLock.lock()
        defer { lastKnownSampleIndexLock.unlock() }
        return lastKnownSampleIndexByPair[pairIndex] ?? 1
    }

    private static let pairExportHeader: [String] = [
        "sample_index", "recorded_at_iso", "sleeve_a_player", "sleeve_b_player",
        "d1_epoch_ms", "d1_fsr1", "d1_fsr2", "d1_fsr3", "d1_fsr4", "d1_fsr5", "d1_bat_pct",
        "d2_epoch_ms", "d2_fsr1", "d2_fsr2", "d2_fsr3", "d2_fsr4", "d2_fsr5", "d2_bat_pct",
        "auto_vibrate_events_this_sample", "auto_vibrate_events_cumulative",
        "manual_vibrate_events_this_sample", "manual_vibrate_events_cumulative"
    ]

    private func makeRecordingWorkbookData(
        _ rowsByPair: [[WideSampleRow]],
        vibrationMarkers markers: [VibrationChartMarker]
    ) -> Data {
        var sheets: [RecordingWorkbookBuilder.Sheet] = []
        var usedTabNames = Set<String>()
        sheets.reserveCapacity(rowsByPair.count)
        for (pairIdx, rows) in rowsByPair.enumerated() {
            guard !rows.isEmpty else { continue }
            var tabName = pairSheetTitle(pairIndex: pairIdx)
            if usedTabNames.contains(tabName) {
                tabName = RecordingWorkbookBuilder.sanitizeSheetName("P\(pairIdx + 1) \(tabName)")
            }
            usedTabNames.insert(tabName)
            let table = pairExportTable(pairIndex: pairIdx, rows: rows, vibrationMarkers: markers)
            sheets.append(RecordingWorkbookBuilder.Sheet(name: tabName, rows: table))
        }
        return RecordingWorkbookBuilder.buildSpreadsheetML(sheets: sheets)
    }

    private func pairExportTable(
        pairIndex: Int,
        rows: [WideSampleRow],
        vibrationMarkers markers: [VibrationChartMarker]
    ) -> [[String]] {
        let playerA = sleevePlayerName(slot: pairIndex * 2)
        let playerB = sleevePlayerName(slot: pairIndex * 2 + 1)
        var table: [[String]] = []
        table.reserveCapacity(rows.count + 1)
        table.append(Self.pairExportHeader)

        let pairMarkers = markers.filter { $0.pairIndex == pairIndex }
        let autoMarkers = pairMarkers.filter { $0.kind == .auto }
        let manualMarkers = pairMarkers.filter { $0.kind == .manual }
        var autoAtSample: [Int: Int] = [:]
        var manualAtSample: [Int: Int] = [:]
        for m in autoMarkers { autoAtSample[m.sampleIndex, default: 0] += 1 }
        for m in manualMarkers { manualAtSample[m.sampleIndex, default: 0] += 1 }
        let autoSorted = autoMarkers.map(\.sampleIndex).sorted()
        let manualSorted = manualMarkers.map(\.sampleIndex).sorted()
        var autoEv = 0
        var manualEv = 0
        let iso = ISO8601DateFormatter()

        for r in rows {
            let d1 = r.d1
            let d2 = r.d2
            while autoEv < autoSorted.count, autoSorted[autoEv] <= r.sampleIndex { autoEv += 1 }
            while manualEv < manualSorted.count, manualSorted[manualEv] <= r.sampleIndex { manualEv += 1 }
            table.append([
                String(r.sampleIndex),
                iso.string(from: r.recordedAt),
                playerA,
                playerB,
                String(d1.epochMs),
                String(d1.fsr1), String(d1.fsr2), String(d1.fsr3), String(d1.fsr4), String(d1.fsr5),
                d1.batteryPercent.map(String.init) ?? "",
                String(d2.epochMs),
                String(d2.fsr1), String(d2.fsr2), String(d2.fsr3), String(d2.fsr4), String(d2.fsr5),
                d2.batteryPercent.map(String.init) ?? "",
                String(autoAtSample[r.sampleIndex] ?? 0),
                String(autoEv),
                String(manualAtSample[r.sampleIndex] ?? 0),
                String(manualEv)
            ])
        }
        return table
    }

    /// Single-pair CSV (legacy export shape); prefer `makeMultiPairWideCSV`.
    private func makeWideCSV(_ rows: [WideSampleRow], vibrationMarkers markers: [VibrationChartMarker]) -> String {
        // One row per sample tick; Device 1 + Device 2 data are always side-by-side.
        // sample_index,recorded_at_iso,
        // d1_epoch_ms,d1_fsr1..d1_fsr5,
        // d2_epoch_ms,d2_fsr1..d2_fsr5
        var lines: [String] = []
        lines.reserveCapacity(rows.count + 1)
        lines.append(
            "sample_index,recorded_at_iso,d1_epoch_ms,d1_fsr1,d1_fsr2,d1_fsr3,d1_fsr4,d1_fsr5,d1_bat_pct," +
            "d2_epoch_ms,d2_fsr1,d2_fsr2,d2_fsr3,d2_fsr4,d2_fsr5,d2_bat_pct," +
            "auto_vibrate_events_this_sample,auto_vibrate_events_cumulative," +
            "manual_vibrate_events_this_sample,manual_vibrate_events_cumulative"
        )

        let autoMarkers = markers.filter { $0.kind == .auto }
        let manualMarkers = markers.filter { $0.kind == .manual }
        var autoAtSample: [Int: Int] = [:]
        var manualAtSample: [Int: Int] = [:]
        for m in autoMarkers { autoAtSample[m.sampleIndex, default: 0] += 1 }
        for m in manualMarkers { manualAtSample[m.sampleIndex, default: 0] += 1 }
        let autoSorted = autoMarkers.map(\.sampleIndex).sorted()
        let manualSorted = manualMarkers.map(\.sampleIndex).sorted()
        var autoEv = 0
        var manualEv = 0

        let iso = ISO8601DateFormatter()
        for r in rows {
            let d1 = r.d1
            let d2 = r.d2
            let b1 = d1.batteryPercent.map(String.init) ?? ""
            let b2 = d2.batteryPercent.map(String.init) ?? ""
            while autoEv < autoSorted.count, autoSorted[autoEv] <= r.sampleIndex { autoEv += 1 }
            while manualEv < manualSorted.count, manualSorted[manualEv] <= r.sampleIndex { manualEv += 1 }
            let autoThis = autoAtSample[r.sampleIndex] ?? 0
            let manualThis = manualAtSample[r.sampleIndex] ?? 0
            lines.append(
                "\(r.sampleIndex),\(iso.string(from: r.recordedAt))," +
                "\(d1.epochMs),\(d1.fsr1),\(d1.fsr2),\(d1.fsr3),\(d1.fsr4),\(d1.fsr5),\(b1)," +
                "\(d2.epochMs),\(d2.fsr1),\(d2.fsr2),\(d2.fsr3),\(d2.fsr4),\(d2.fsr5),\(b2)," +
                "\(autoThis),\(autoEv),\(manualThis),\(manualEv)"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func resultant(_ r: SensorReading) -> Double {
        r.resultantMagnitude
    }

    /// User-facing resultant normalized to **0…1** (same plane as Analysis charts).
    /// Assumes ESP32 ADC is 12-bit (0…4095). If your firmware changes ADC range, update `adcMax`.
    static func resultant01(_ r: SensorReading) -> Double {
        let raw = resultant(r)
        let adcMax = 4095.0
        let rawMax = SensorReading.rawResultantMax(adcMax: adcMax)
        let scaled = raw / rawMax
        return min(1.0, max(0.0, scaled))
    }

    /// Normalizes a **raw** resultant magnitude (same √ΣFSR² as `resultant`) to 0…1 for chart markers.
    static func normalizedRawResultant01(rawResultant: Double) -> Double {
        let adcMax = 4095.0
        let rawMax = SensorReading.rawResultantMax(adcMax: adcMax)
        return min(1.0, max(0.0, rawResultant / rawMax))
    }

    static func sumFSR(_ r: SensorReading) -> Double {
        Double(r.fsrValues.reduce(0, +))
    }

    /// Downsample rows for Swift Charts only (avoids memory / renderer crashes on 20k+ × many series).
    static func downsampleChartRows(_ rows: [WideSampleRow], maxPoints: Int = 2500) -> [WideSampleRow] {
        guard rows.count > maxPoints else { return rows }
        let strideBy = max(1, rows.count / maxPoints)
        if strideBy == 1 { return rows }
        var out: [WideSampleRow] = []
        out.reserveCapacity(maxPoints + 1)
        var i = 0
        while i < rows.count {
            out.append(rows[i])
            i += strideBy
        }
        return out
    }
}

