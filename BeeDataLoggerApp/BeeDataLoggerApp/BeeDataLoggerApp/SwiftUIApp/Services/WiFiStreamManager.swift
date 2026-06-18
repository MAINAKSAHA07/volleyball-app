//
//  WiFiStreamManager.swift
//  BeeDataLoggerApp
//
//  Connects to up to 2 devices over Wi‑Fi (TCP) and streams newline-delimited CSV.
//  Uses Network.framework for efficient, non-blocking IO.
//

import Foundation
import Network
import Combine

enum WiFiDeviceState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

final class WiFiDeviceConnection: ObservableObject {
    let id = UUID()
    let endpoint: NWEndpoint
    let deviceIdentifier: String

    @Published private(set) var state: WiFiDeviceState = .disconnected
    @Published private(set) var lastReading: SensorReading?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var parseFailureCount: Int = 0
    @Published private(set) var lastParseFailureLine: String?

    /// Set when the board sends `OK VIBRATE` after a vibrator test command.
    @Published private(set) var lastVibratorAckAt: Date?
    /// Last error from `sendVibratorTest()`, if any.
    @Published private(set) var lastVibratorSendError: String?
    /// Last error from `sendControlCommand()`, if any.
    @Published private(set) var lastControlSendError: String?

    /// True when CSV samples are arriving (TCP can report `.ready` before the first line).
    var isReceivingLiveData: Bool {
        guard let t = lastUpdated else { return false }
        return Date().timeIntervalSince(t) < 3.0
    }

    /// Full-rate latest sample (thread-safe). Used by the recording timer; UI uses throttled `lastReading`.
    private let latestSampleLock = NSLock()
    private var latestSample: SensorReading?

    /// Max raw √(ΣFSR²) since last auto‑vibrate tick (same window as stream parse rate). Catches brief ball impacts missed by 20 Hz polling.
    private let peakAccumLock = NSLock()
    private var maxRawResultantAccum: Double = 0

    /// Last N raw magnitudes (~80 ms at 500 Hz) so a 7‑8 sample tap still overlaps dual‑pad matching even if peaks aren’t on the same tick.
    private let rawRingLock = NSLock()
    private var rawMagnitudeRing: [Double] = []
    private let rawMagnitudeRingMax = 40

    private var connection: NWConnection?
    private var buffer = Data()
    private let bufferLock = NSLock()
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var callbackQueue: DispatchQueue?

    /// Throttle: publish at most ~1 / flushInterval Hz to Main while always moving toward the latest sample.
    private var pendingReadingForUI: SensorReading?
    private var readingCoalesceWork: DispatchWorkItem?
    private var lastReadingFlushTime: CFTimeInterval = 0
    /// ~15 Hz max UI publishes — enough for live digits while cutting SwiftUI wake traffic (~½ vs 30 Hz).
    private let readingFlushInterval: CFTimeInterval = 1.0 / 15.0

    private var pendingFailureDelta: Int = 0
    private var pendingFailureLine: String?
    private var failureCoalesceWork: DispatchWorkItem?

    /// If no complete CSV line is parsed for this long while `.connected`, treat the TCP session as dead.
    private let dataStallTimeout: TimeInterval = 12
    private var dataStallWorkItem: DispatchWorkItem?

    /// Called on the connection’s serial queue for every successfully parsed CSV sensor reading.
    /// Used for receive-driven recording (real-world reliable capture).
    var onParsedReading: ((SensorReading) -> Void)?

    init(endpoint: NWEndpoint, deviceIdentifier: String) {
        self.endpoint = endpoint
        self.deviceIdentifier = deviceIdentifier
    }

    /// Latest parsed reading at stream rate; safe to call from the recording queue.
    func latestSampleForRecording() -> SensorReading? {
        latestSampleLock.lock()
        defer { latestSampleLock.unlock() }
        return latestSample
    }

    /// Returns max raw resultant in the interval since the last call, then resets (one consumer: auto‑vibrate tick).
    func consumePeakRawResultantSinceLastTick() -> Double {
        peakAccumLock.lock()
        let v = maxRawResultantAccum
        maxRawResultantAccum = 0
        peakAccumLock.unlock()
        return v
    }

    private func resetPeakAccumulation() {
        peakAccumLock.lock()
        maxRawResultantAccum = 0
        peakAccumLock.unlock()
    }

    private func resetRollingRawMagnitudes() {
        rawRingLock.lock()
        rawMagnitudeRing.removeAll(keepingCapacity: false)
        rawRingLock.unlock()
    }

    private func pushRawMagnitudeForAutoVibrate(_ mag: Double) {
        rawRingLock.lock()
        rawMagnitudeRing.append(mag)
        if rawMagnitudeRing.count > rawMagnitudeRingMax {
            rawMagnitudeRing.removeFirst(rawMagnitudeRing.count - rawMagnitudeRingMax)
        }
        rawRingLock.unlock()
    }

    /// Max √(ΣFSR²) in the last ~40 samples (full stream rate). Used with auto‑vibrate so taps aren’t lost vs long presses.
    func maxRawMagnitudeInRollingWindow() -> Double {
        rawRingLock.lock()
        let v = rawMagnitudeRing.max() ?? 0
        rawRingLock.unlock()
        return v
    }

    func connect() {
        guard connection == nil else { return }
        setState(.connecting)
        cancelDataStallWatchdog()

        // Personal Hotspot + Bonjour often requires peer-to-peer capable params.
        // Do not set `requiredInterfaceType = .wifi` — it breaks some hotspot / routed paths and causes flaky connects.
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        scheduleConnectTimeout(seconds: 8)

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            switch newState {
            case .ready:
                self.cancelConnectTimeout()
                self.setState(.connected)
                self.clearBuffer()
                self.resetPeakAccumulation()
                self.resetRollingRawMagnitudes()
                self.receiveLoop()
                self.armDataStallWatchdog()
            case .failed(let err):
                self.cancelConnectTimeout()
                self.setState(.failed(err.localizedDescription))
                self.cleanup()
            case .cancelled:
                self.cancelConnectTimeout()
                self.setState(.disconnected)
                self.cleanup()
            default:
                break
            }
        }

        let q = DispatchQueue(label: "com.beedatalogger.wifi.\(deviceIdentifier)", qos: .userInitiated)
        callbackQueue = q
        conn.start(queue: q)
    }

    func disconnect() {
        cancelConnectTimeout()
        cancelDataStallWatchdog()
        readingCoalesceWork?.cancel()
        readingCoalesceWork = nil
        lastReadingFlushTime = 0
        failureCoalesceWork?.cancel()
        failureCoalesceWork = nil
        pendingReadingForUI = nil
        pendingFailureDelta = 0
        pendingFailureLine = nil
        latestSampleLock.lock()
        latestSample = nil
        latestSampleLock.unlock()
        resetPeakAccumulation()
        resetRollingRawMagnitudes()
        DispatchQueue.main.async {
            self.lastReading = nil
            self.lastUpdated = nil
            self.lastVibratorAckAt = nil
            self.lastVibratorSendError = nil
        }

        connection?.cancel()
        connection = nil
        clearBuffer()
        callbackQueue = nil
        setState(.disconnected)
    }

    func reconnect() {
        disconnect()
        // Brief gap lets the ESP32 accept a new client (old TCP half-open sessions otherwise sit in “connected but silent”).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.connect()
        }
    }

    /// Sends `VIBRATE\n` or `VIBRATE <ms>\n` on the TCP connection (firmware pulses GPIO; may reply `OK VIBRATE\n`).
    /// Uses the connection’s serial queue so sends don’t race `receive` on the main thread.
    /// - Parameter pulseMilliseconds: 0 = firmware default pulse; 30…500 = pulse length in ms (firmware-clamped).
    func sendVibratorTest(pulseMilliseconds: UInt16 = 0) {
        guard let q = callbackQueue else {
            DispatchQueue.main.async { self.lastVibratorSendError = "No connection" }
            return
        }
        guard connection != nil else {
            DispatchQueue.main.async { self.lastVibratorSendError = "No connection" }
            return
        }
        guard case .connected = state else {
            DispatchQueue.main.async { self.lastVibratorSendError = "Not connected" }
            return
        }
        let payload: String
        if pulseMilliseconds > 0 {
            payload = "VIBRATE \(pulseMilliseconds)\n"
        } else {
            payload = "VIBRATE\n"
        }
        guard let data = payload.data(using: .utf8) else { return }
        DispatchQueue.main.async { self.lastVibratorSendError = nil }
        q.async { [weak self] in
            guard let self, let conn = self.connection else { return }
            // Must be false: true would send TCP FIN and close the write side, killing the stream after each pulse.
            conn.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { [weak self] error in
                DispatchQueue.main.async {
                    if let error {
                        self?.lastVibratorSendError = error.localizedDescription
                    }
                }
            })
        }
    }

    /// Sends an arbitrary newline-terminated command to firmware over the same TCP stream.
    /// Firmware should ignore unknown commands and reply `OK ...` for ACKs.
    func sendControlCommand(_ commandLine: String) {
        guard let q = callbackQueue else {
            DispatchQueue.main.async { self.lastControlSendError = "No connection" }
            return
        }
        guard connection != nil else {
            DispatchQueue.main.async { self.lastControlSendError = "No connection" }
            return
        }
        guard case .connected = state else {
            DispatchQueue.main.async { self.lastControlSendError = "Not connected" }
            return
        }
        let payload = commandLine.hasSuffix("\n") ? commandLine : (commandLine + "\n")
        guard let data = payload.data(using: .utf8) else { return }
        DispatchQueue.main.async { self.lastControlSendError = nil }
        q.async { [weak self] in
            guard let self, let conn = self.connection else { return }
            conn.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { [weak self] error in
                DispatchQueue.main.async {
                    if let error {
                        self?.lastControlSendError = error.localizedDescription
                    }
                }
            })
        }
    }

    private func receiveLoop() {
        guard connection != nil else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard self.connection != nil else { return }

            if let data, !data.isEmpty {
                self.appendReceivedData(data)
            }

            if let error {
                self.setState(.failed(error.localizedDescription))
                self.cleanup()
                return
            }

            if isComplete {
                self.setState(.disconnected)
                self.cleanup()
                return
            }

            self.receiveLoop()
        }
    }

    private func clearBuffer() {
        bufferLock.lock()
        buffer.removeAll(keepingCapacity: false)
        bufferLock.unlock()
    }

    private func appendReceivedData(_ data: Data) {
        var lines: [Data] = []
        bufferLock.lock()
        buffer.append(data)
        lines = drainLinesLocked()
        bufferLock.unlock()
        processDrainedLines(lines)
    }

    /// Must be called with `bufferLock` held. Returns raw line payloads (without `\n`).
    private func drainLinesLocked() -> [Data] {
        var lines: [Data] = []
        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let lineEnd = newlineRange.lowerBound
            let removeEnd = newlineRange.upperBound
            guard lineEnd <= buffer.endIndex, removeEnd <= buffer.endIndex, removeEnd > buffer.startIndex else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            lines.append(buffer.subdata(in: buffer.startIndex..<lineEnd))
            buffer.removeSubrange(buffer.startIndex..<removeEnd)
        }
        return lines
    }

    private func processDrainedLines(_ lineDatas: [Data]) {
        for lineData in lineDatas {
            guard !lineData.isEmpty else { continue }
            let trimmed = lineData.drop(while: { $0 == 0x0D })
            guard let line = String(data: Data(trimmed), encoding: .utf8) else { continue }
            let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanLine.isEmpty { continue }

            if cleanLine.lowercased().contains("epoch") && cleanLine.lowercased().contains("fsr") { continue }

            let upper = cleanLine.uppercased()
            if upper.hasPrefix("OK") {
                if upper.contains("VIB") {
                    DispatchQueue.main.async {
                        self.lastVibratorAckAt = Date()
                    }
                }
                continue
            }
            if cleanLine.hasPrefix("#") { continue }

            if let reading = SensorDataParser.parse(cleanLine, deviceIdentifier: deviceIdentifier) {
                armDataStallWatchdog()
                let mag = reading.resultantMagnitude
                pushRawMagnitudeForAutoVibrate(mag)
                peakAccumLock.lock()
                maxRawResultantAccum = max(maxRawResultantAccum, mag)
                peakAccumLock.unlock()
                latestSampleLock.lock()
                latestSample = reading
                latestSampleLock.unlock()
                onParsedReading?(reading)
                scheduleCoalescedReadingPublish(reading)
            } else {
                scheduleCoalescedParseFailure(line: cleanLine)
            }
        }
    }

    /// Throttle high-rate CSV lines so Main sees ≤~30 Hz updates with the latest sample (no starvation during continuous 500 Hz).
    private func scheduleCoalescedReadingPublish(_ reading: SensorReading) {
        guard let q = callbackQueue else {
            DispatchQueue.main.async {
                self.lastReading = reading
                self.lastUpdated = reading.receivedAt
                self.parseFailureCount = 0
                self.lastParseFailureLine = nil
            }
            return
        }
        pendingReadingForUI = reading
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastReadingFlushTime
        if elapsed >= readingFlushInterval {
            readingCoalesceWork?.cancel()
            readingCoalesceWork = nil
            lastReadingFlushTime = now
            let latest = reading
            pendingReadingForUI = nil
            DispatchQueue.main.async {
                self.lastReading = latest
                self.lastUpdated = latest.receivedAt
                self.parseFailureCount = 0
                self.lastParseFailureLine = nil
            }
            return
        }
        readingCoalesceWork?.cancel()
        let delay = readingFlushInterval - elapsed
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.readingCoalesceWork = nil
            self.lastReadingFlushTime = CFAbsoluteTimeGetCurrent()
            guard let latest = self.pendingReadingForUI else { return }
            self.pendingReadingForUI = nil
            DispatchQueue.main.async {
                self.lastReading = latest
                self.lastUpdated = latest.receivedAt
                self.parseFailureCount = 0
                self.lastParseFailureLine = nil
            }
        }
        readingCoalesceWork = work
        q.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleCoalescedParseFailure(line: String) {
        guard let q = callbackQueue else {
            DispatchQueue.main.async {
                self.parseFailureCount += 1
                self.lastParseFailureLine = line
            }
            return
        }
        pendingFailureDelta += 1
        pendingFailureLine = line
        failureCoalesceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.failureCoalesceWork = nil
            let delta = self.pendingFailureDelta
            let lastLine = self.pendingFailureLine
            self.pendingFailureDelta = 0
            guard delta > 0 else { return }
            DispatchQueue.main.async {
                self.parseFailureCount += delta
                if let lastLine { self.lastParseFailureLine = lastLine }
            }
        }
        failureCoalesceWork = work
        q.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cleanup() {
        cancelConnectTimeout()
        cancelDataStallWatchdog()
        readingCoalesceWork?.cancel()
        readingCoalesceWork = nil
        failureCoalesceWork?.cancel()
        failureCoalesceWork = nil
        pendingReadingForUI = nil
        pendingFailureDelta = 0
        pendingFailureLine = nil
        lastReadingFlushTime = 0
        latestSampleLock.lock()
        latestSample = nil
        latestSampleLock.unlock()
        resetPeakAccumulation()
        resetRollingRawMagnitudes()
        clearBuffer()
        connection?.cancel()
        connection = nil
        callbackQueue = nil
        DispatchQueue.main.async {
            self.lastReading = nil
            self.lastUpdated = nil
        }
    }

    private func armDataStallWatchdog() {
        cancelDataStallWatchdog()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard case .connected = self.state else { return }
            self.setState(.failed("No sensor data received. Tap Reconnect or restart the ESP32."))
            self.cleanup()
        }
        dataStallWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dataStallTimeout, execute: work)
    }

    private func cancelDataStallWatchdog() {
        dataStallWorkItem?.cancel()
        dataStallWorkItem = nil
    }

    private func setState(_ s: WiFiDeviceState) {
        DispatchQueue.main.async {
            self.state = s
        }
    }

    private func scheduleConnectTimeout(seconds: TimeInterval) {
        cancelConnectTimeout()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Only time out if still not connected
            if case .connecting = self.state {
                self.connection?.cancel()
                self.setState(.failed("Connection timeout. Check ESP32 TCP server (port 3333) and that client-to-client is allowed on hotspot."))
                self.cleanup()
            }
        }
        connectTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelConnectTimeout() {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
    }
}

final class WiFiStreamManager: ObservableObject {
    static let maxPairs = 5
    static let maxDevices = maxPairs * 2

    /// Device slots: 0..<(2*pairCount). Slot 0 = Pair1-A, 1 = Pair1-B, 2 = Pair2-A, ...
    @Published private(set) var devices: [WiFiDeviceConnection?] = Array(repeating: nil, count: maxDevices)

    func device(at slot: Int) -> WiFiDeviceConnection? {
        guard slot >= 0, slot < devices.count else { return nil }
        return devices[slot]
    }

    private func replaceDevice(at slot: Int, with connection: WiFiDeviceConnection?) {
        guard slot >= 0, slot < devices.count else { return }
        var next = devices
        next[slot]?.disconnect()
        next[slot] = connection
        devices = next
    }

    func connectOne(endpoint: NWEndpoint, slot: Int) {
        guard slot >= 0, slot < devices.count else { return }
        let d = WiFiDeviceConnection(endpoint: endpoint, deviceIdentifier: "wifi-slot-\(slot)")
        replaceDevice(at: slot, with: d)
        d.connect()
    }

    func disconnect(slot: Int) {
        replaceDevice(at: slot, with: nil)
    }

    func disconnectAll() {
        for i in 0..<devices.count {
            devices[i]?.disconnect()
        }
        devices = Array(repeating: nil, count: Self.maxDevices)
    }
}

