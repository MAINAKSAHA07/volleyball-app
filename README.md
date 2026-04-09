# Bee Data Logger – iOS App

Production-ready iPhone app that connects to **2 BLE devices simultaneously** (ESP32 Bee Data Loggers) and displays real-time sensor data. Built with **SwiftUI**, **CoreBluetooth**, and **MVVM**.

---

## Requirements

- **Xcode 15+**
- **iOS 17+** (iPhone 15 Pro and newer)
- Two ESP32-based BDL devices advertising over BLE

---

## Project structure

```
BeeDataLoggerApp/
├── BeeDataLoggerApp.swift          # App entry (@main)
├── ContentView.swift               # Root: TabView (Scan | Dashboard)
├── Info.plist                      # Bluetooth usage descriptions
├── Models/
│   └── SensorReading.swift         # epochMs, fsr1–fsr6, deviceId, receivedAt
├── Services/
│   ├── BLEConstants.swift          # ← Put your BLE UUIDs here
│   ├── BLEManager.swift            # CoreBluetooth: scan, connect, notify
│   └── DeviceConnection.swift     # Per-device state & readings
├── ViewModels/
│   ├── ScanViewModel.swift        # Scan UI state & device selection
│   └── DashboardViewModel.swift   # Dashboard state & reconnect
├── Views/
│   ├── ScanView.swift             # Scan screen
│   ├── DashboardView.swift        # Live dashboard
│   └── Components/
│       └── DeviceCardView.swift   # One device panel (FSR, state, reconnect)
├── Utilities/
│   └── SensorDataParser.swift     # CSV parser (epoch_ms,fsr1..fsr6)
└── Preview/
    └── MockData.swift             # Mock readings for previews
```

---

## Where to put BLE UUIDs

Edit **`BeeDataLoggerApp/Services/BLEConstants.swift`**:

- **`serviceUUID`** – Service UUID advertised by your ESP32 (required).
- **`notifyCharacteristicUUID`** – Characteristic you subscribe to for sensor stream.
- **`writeCharacteristicUUID`** – Optional; set to `nil` if the device has no write characteristic.
- **`preferredDeviceNamePrefix`** – Used to sort devices in the list (e.g. `"BDL"` for BDL-01, BDL-02).

Replace the placeholder UUIDs with your actual ESP32 service/characteristic UUIDs.

---

## How the BLE manager works

1. **Single central** – One `CBCentralManager` on a dedicated queue (`com.beedatalogger.ble`) so BLE never blocks the main thread.
2. **Scan** – `startScanning()` uses `scanForPeripherals(withServices: [serviceUUID])`. Discovered devices are merged into `discoveredPeripherals` (name, id, RSSI).
3. **Connect** – User selects 2 devices; `connect(to:name:rssi:)` creates a `DeviceConnection` for each and calls `centralManager.connect()`. Up to two sessions are stored as `device1` and `device2`.
4. **Discovery** – On connect, the manager discovers the service and the notify (and optional write) characteristic.
5. **Notify** – For each device, `setNotifyValue(true, for: notifyCharacteristic)` is called. Incoming data is delivered in `peripheral(_:didUpdateValueFor:error:)`.
6. **Parsing** – Data is parsed off the main thread via `SensorDataParser.parse(_:deviceIdentifier:)`; the resulting `SensorReading` is applied on the main thread to the corresponding `DeviceConnection` (and thus to the UI).
7. **Disconnect** – If a peripheral disconnects, `didDisconnectPeripheral` updates that device’s state; the session remains so the user can tap Reconnect.
8. **Log** – BLE events are appended to `logEntries` (bounded) for the in-app log console.

---

## Info.plist – Bluetooth permissions

These keys are required for BLE central usage:

| Key | Purpose |
|-----|--------|
| **NSBluetoothAlwaysUsageDescription** | Shown when the app first uses Bluetooth (iOS 13+). |
| **NSBluetoothPeripheralUsageDescription** | Legacy; still recommended for older OS. |
| **UIBackgroundModes** → `bluetooth-central` | Optional; use if you need to maintain connections in background. |

The project includes an **Info.plist** with these. In Xcode, if you use the target’s “Info” tab instead of a file, add the same keys there.

---

## How to run and test on a real iPhone

1. **Create an Xcode project**
   - File → New → Project → **App**.
   - Product Name: **BeeDataLoggerApp** (or match the folder name).
   - Interface: **SwiftUI**, Language: **Swift**, minimum deployment: **iOS 17**.
   - Save into the same parent folder as the `BeeDataLoggerApp` source folder.

2. **Add source files**
   - Drag the entire **BeeDataLoggerApp** folder (with Models, Services, Views, etc.) into the Xcode project under the app target.
   - Ensure “Copy items if needed” and the correct target are selected.

3. **Info.plist**
   - Either add the provided **Info.plist** to the target and set it as the target’s “Info.plist”, or copy the Bluetooth keys into the target’s Info tab.

4. **Deployment**
   - Connect your iPhone (iPhone 15 Pro or newer).
   - Select the device as the run destination.
   - Build and run (⌘R). Grant Bluetooth when prompted.

5. **Testing**
   - Use the **Scan** tab to start a scan, select 2 BDL devices, then Connect.
   - Switch to the **Dashboard** tab to see live FSR values and connection state; use Reconnect if one device drops.

---

## Sample payload and parser

Expected CSV format from the notify characteristic:

```text
epoch_ms,fsr1,fsr2,fsr3,fsr4,fsr5,fsr6
```

Example:

```text
1741738205123,122,130,141,118,125,135
```

Parsing is implemented in **`SensorDataParser`** (`Utilities/SensorDataParser.swift`). To support a different format, replace or extend the `parse(_:deviceIdentifier:)` implementation and keep the same `SensorReading` model (or extend it).

---

## Testing checklist – 2 devices simultaneously

- [ ] **Bluetooth on** – Turn on Bluetooth; app shows “Tap Scan to find devices” (or similar), no “Bluetooth is off”.
- [ ] **Permission** – First scan triggers the system Bluetooth dialog; accept. No “unauthorized” state.
- [ ] **Scan** – Start scan; both BDL devices appear in the list with name, identifier, and RSSI.
- [ ] **Selection** – Select exactly 2 devices (e.g. BDL-01 and BDL-02); “Connect to selected (2/2)” becomes enabled.
- [ ] **Connect** – Tap Connect; both devices show Connecting → Discovering → Connected in the Dashboard.
- [ ] **Data** – Both device cards show updating “Last updated” time, epoch, and FSR1–FSR6 values; “Streaming” indicator appears when data is received.
- [ ] **RSSI** – If your firmware exposes RSSI updates, the card shows “RSSI: … dBm”.
- [ ] **Disconnect one** – Power off or move one device out of range; that card shows Disconnected, the other stays Connected; app does not crash.
- [ ] **Reconnect** – Tap Reconnect on the disconnected card; device reconnects and data resumes.
- [ ] **Log** – BLE Log section shows connect/disconnect/scan events; Clear works.
- [ ] **No duplicate connections** – Only 2 devices can be connected; selecting and connecting a third does not replace the first two incorrectly.

---

## Optional / future

- **Charts** – `DeviceConnection.readingHistory` keeps the last 100 readings per device for adding charts later.
- **Battery** – If the ESP32 exposes a battery service/characteristic, add its UUID in `BLEConstants` and read it in `BLEManager` after discovery; surface it in `DeviceCardView`.
- **Mock mode** – `BLEManager.setMockMode(true)` and `DashboardViewModel.setMockMode(true)` are stubs for feeding mock data in previews or demos; you can wire them to a timer that pushes `MockData.reading(deviceId:offset:)` into the view model.
