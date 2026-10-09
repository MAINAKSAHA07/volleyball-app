/*
 * BDL — Wi‑Fi TCP stream (500 Hz) + SD + mDNS + vibrator test over same TCP connection.
 *
 * App sends:  VIBRATE\n  (default pulse) or  VIBRATE <30-500>\n  (pulse length ms)
 * Board runs vibrator on VIBRATOR_PIN, then replies: OK VIBRATE\n
 *
 * Status NeoPixel (BDL): ~1 Hz via updateStatusPixel()
 *   • Plugged in (getVbusPresent): orange = charging, green = high while plugged in, off = very low.
 *   • On battery: green = Wi‑Fi connected + strong pack; orange = Wi‑Fi up but medium pack;
 *     red = no Wi‑Fi or critically low battery.
 *
 * IMPORTANT — BDL custom PCB (not generic ESP32 devkit):
 *   • ADC / digital pins 3–9 are valid board pins (see BeeDataLogger library).
 *   • Vibrator output is silkscreen O9 = GPIO 9 on the BDL board.
 *   • On battery, Wi‑Fi + 500 Hz streaming can brown out the pack — firmware throttles on battery.
 *
 * Wi‑Fi network (no reflash needed to change):
 *   • First boot uses WIFI_DEFAULT_* below (factory fallback only).
 *   • Saved credentials live in flash (Preferences/NVS) after you run Serial commands.
 *   • USB Serial @ 115200:
 *       WIFI_SET Sakshi therock08   → save + reboot
 *       WIFI_SHOW                   → print current SSID + pass length
 *       WIFI_SCAN                   → scan 2.4 GHz and list networks
 *       WIFI_PAUSE                  → stop auto Wi‑Fi retry loop (Serial stays usable)
 *       WIFI_RESUME                 → re-enable auto retry
 *       WIFI_CLEAR                  → erase saved creds, use defaults, reboot
 */
#include <BDL.h>
#include "FS.h"
#include "SD.h"
#include <SPI.h>
#include "RTClib.h"
#include <WiFi.h>
#include <Preferences.h>
#include "time.h"
#include <ESPmDNS.h>

BDL bdl;
RTC_DS3231 rtc;

// ===== Wi‑Fi — defaults used ONLY until WIFI_SET is run once (saved in flash after that) =====
static const char* WIFI_DEFAULT_SSID = "Mainak";
static const char* WIFI_DEFAULT_PASS = "ms080716";
static const char* WIFI_PREFS_NS     = "bdlwifi";

static String wifiSSID;
static String wifiPASS;

// ✅ unique per board (bdl-01 … bdl-10)
const char* mdnsHost = "bdl-01";   // <-- CHANGE PER BOARD

// ===== Vibrator — BDL board O9 = GPIO 9 (Stemma digital out) =====
constexpr uint8_t VIBRATOR_PIN = 9;
constexpr uint32_t VIBRATE_PULSE_MS = 200;

// ===== TCP stream =====
constexpr uint16_t STREAM_PORT = 3333;
WiFiServer streamServer(STREAM_PORT);
WiFiClient streamClient;

// ===== NTP UTC =====
const long gmtOffset_sec      = 0;
const int  daylightOffset_sec = 0;

// ===== Sampling =====
constexpr uint32_t SAMPLE_HZ = 500;
constexpr uint32_t SAMPLE_HZ_BATTERY = 100;
constexpr uint32_t SAMPLE_PERIOD_US = 1000000UL / SAMPLE_HZ;

// Cap catch-up per loop so Wi‑Fi / watchdog / status LED keep running on battery.
constexpr uint8_t MAX_SAMPLES_PER_LOOP = 12;

// ===== Wi‑Fi stream throttle =====
// Stream over TCP at a fixed, network-friendly rate regardless of the 500 Hz sample loop.
// Sending every 500 Hz sample as tiny noDelay packets saturates a phone-hotspot uplink, the
// TCP send buffer fills, availableForWrite() stays below a full line, and EVERY row gets dropped
// (the board looks connected + vibrate still works, but no FSR data reaches the app).
constexpr uint32_t STREAM_TX_HZ = 50;
constexpr uint32_t STREAM_TX_MIN_INTERVAL_MS = (STREAM_TX_HZ == 0) ? 0 : (1000UL / STREAM_TX_HZ);
static uint32_t lastStreamTxMs = 0;
static uint32_t streamTxOkCount = 0;
static uint32_t streamTxSkipFull = 0;
static uint32_t streamTxFailCount = 0;
static uint32_t lastStreamStatsMs = 0;

// ===== SD logging decimation =====
constexpr uint32_t SD_LOG_HZ = 50;
constexpr uint32_t SD_LOG_INTERVAL_US = (SD_LOG_HZ == 0) ? 0 : (1000000UL / SD_LOG_HZ);
static uint32_t lastSdLogUs = 0;

constexpr size_t SD_BUF_BYTES = 8192;
char sdBuf[SD_BUF_BYTES];
size_t sdBufLen = 0;
static File sdRecFile;
static bool sdRecording = false;
static char sdRecPath[80];

unsigned long lastBatteryCheck = 0;
#define BATTERY_CHECK_INTERVAL 1000

static uint32_t vibratorOffAtMs = 0;
static String streamCmdBuf;
static bool rtcOk = false;
static unsigned long lastWifiRetryMs = 0;
static bool wifiAutoRetryEnabled = true;

static uint32_t g_lastRtcUnix = 0;
static uint32_t g_millisAtRtcSecondStart = 0;
static bool g_epochAnchorReady = false;

bool syncRTCFromNTP();
void initSDCard();
void writeHeaderIfNeeded();
void flushSdBuf();
void updateStatusPixel();
void pollStreamCommands();
void updateVibrator();
void triggerVibrateFromCommand(uint32_t pulseMs);
uint64_t currentEpochMs();
void startSdRecording(uint64_t epochMsStart);
void stopSdRecording();
void showBootIndicator();
bool connectWiFiWithStatus();
static uint32_t samplePeriodUsNow();
static void maintainWiFiOnBattery();
static void loadWifiCredentials();
static void saveWifiCredentials(const String& ssid, const String& pass);
static void pollSerialWifiConfig();
static void printWifiScanAndStatus();
static const char* wifiStatusText(wl_status_t s);
static void prepareWifiRadio();
static int runWifiScan();
static int findTargetRssiInLastScan();

static int batteryPercentFromVolts(float v) {
  long vc = (long)(v * 100.0f);
  int p = (int)map(vc, 300L, 420L, 0L, 100L);
  if (p < 0) p = 0;
  if (p > 100) p = 100;
  return p;
}

// ===== Battery smoothing =====
// The battery percent used to be computed from one raw ADC read on every sample of the 500 Hz loop.
// A single read landing outside the 3.00–4.20 V map clamps to 0 % or 100 % instantly, so the battery
// column in exported sessions flickered dozens of times per session and was unusable.
// Read at 1 Hz instead and map an 8-deep rolling average.
static constexpr uint8_t BAT_AVG_N = 8;
static float batVoltSamples[BAT_AVG_N];
static uint8_t batSampleCount = 0;
static uint8_t batSampleIdx = 0;
static uint32_t lastBatSampleMs = 0;
static bool batPrimed = false;
static float batVoltCached = 0.0f;
static int batPctCached = 0;

static float smoothedBatteryVoltage() {
  const uint32_t now = millis();
  if (!batPrimed || (now - lastBatSampleMs) >= 1000) {
    batPrimed = true;
    lastBatSampleMs = now;

    const float v = bdl.getBatteryVoltage();
    // Drop physically impossible reads so one bad ADC sample cannot drag the average.
    if (v > 2.5f && v < 5.0f) {
      batVoltSamples[batSampleIdx] = v;
      batSampleIdx = (uint8_t)((batSampleIdx + 1) % BAT_AVG_N);
      if (batSampleCount < BAT_AVG_N) batSampleCount++;
    }

    if (batSampleCount > 0) {
      float sum = 0.0f;
      for (uint8_t i = 0; i < batSampleCount; i++) sum += batVoltSamples[i];
      batVoltCached = sum / (float)batSampleCount;
      batPctCached = batteryPercentFromVolts(batVoltCached);
    }
  }
  return batVoltCached;
}

static int smoothedBatteryPercent() {
  smoothedBatteryVoltage();
  return batPctCached;
}

static void acceptClientIfNeeded() {
  if (WiFi.status() != WL_CONNECTED) return;

  if (streamClient && !streamClient.connected()) {
    Serial.println("TCP: previous client no longer connected — pruning");
    stopSdRecording();
    streamClient.stop();
    streamCmdBuf = "";
  }

  WiFiClient c = streamServer.available();
  if (!c) return;

  if (streamClient) {
    Serial.println("TCP: new client — closing previous socket");
    stopSdRecording();
    streamClient.stop();
    streamCmdBuf = "";
  }

  streamClient = c;
  streamClient.setNoDelay(true);
  streamClient.setTimeout(50);
  streamCmdBuf = "";
  lastStreamTxMs = 0;
  streamTxOkCount = 0;
  streamTxSkipFull = 0;
  streamTxFailCount = 0;
  lastStreamStatsMs = millis();
  Serial.println("TCP client connected (CSV stream)");
  streamClient.print("epoch_ms,fsr1,fsr2,fsr3,fsr4,fsr5,battery_pct\n");
}

void setup() {
  Serial.begin(115200);
  delay(300);

  bdl.begin();
  bdl.setPixelBrightness(255 / 3);
  showBootIndicator();

  pinMode(VIBRATOR_PIN, OUTPUT);
  digitalWrite(VIBRATOR_PIN, LOW);

  loadWifiCredentials();
  Serial.print("WiFi target SSID: ");
  Serial.println(wifiSSID);

  rtcOk = rtc.begin();
  if (!rtcOk) {
    Serial.println("RTC not found — continuing without hardware clock (timestamps use millis fallback).");
    bdl.setPixelColor(red);
    delay(400);
  }

  if (connectWiFiWithStatus()) {
    configTime(gmtOffset_sec, daylightOffset_sec, "pool.ntp.org", "time.nist.gov");
    if (rtcOk && syncRTCFromNTP()) Serial.println("RTC synced from NTP");
    else Serial.println("NTP sync skipped or failed; using existing RTC / millis fallback");

    if (MDNS.begin(mdnsHost)) {
      MDNS.addService("bdl", "tcp", STREAM_PORT);
      Serial.print("mDNS started: ");
      Serial.print(mdnsHost);
      Serial.println(".local (_bdl._tcp)");
    } else {
      Serial.println("mDNS failed to start");
    }

    streamServer.begin(STREAM_PORT, 4);
    streamServer.setNoDelay(true);
    Serial.print("TCP server: ");
    Serial.print(WiFi.localIP());
    Serial.print(":");
    Serial.println(STREAM_PORT);
  } else {
    Serial.println("WiFi NOT connected. Streaming + mDNS will not work until Wi‑Fi joins.");
  }

  updateStatusPixel();
  initSDCard();
  writeHeaderIfNeeded();
}

void loop() {
  pollSerialWifiConfig();
  maintainWiFiOnBattery();
  acceptClientIfNeeded();
  pollStreamCommands();
  updateVibrator();

  unsigned long nowMs = millis();
  if (lastBatteryCheck == 0 || nowMs - lastBatteryCheck > BATTERY_CHECK_INTERVAL) {
    updateStatusPixel();
    lastBatteryCheck = nowMs;
  }

  static uint32_t nextSampleUs = micros();
  static uint32_t sampleCounter = 0;
  uint32_t nowUs = micros();
  uint8_t samplesThisLoop = 0;
  const uint32_t periodUs = samplePeriodUsNow();

  while ((int32_t)(nowUs - nextSampleUs) >= 0 && samplesThisLoop < MAX_SAMPLES_PER_LOOP) {
    const uint32_t sampleDueUs = nextSampleUs;
    nextSampleUs += periodUs;
    sampleCounter++;
    samplesThisLoop++;

    if (sampleCounter % 5 == 0) {
      pollStreamCommands();
      updateVibrator();
    }

    uint64_t epoch_ms = currentEpochMs();

    int fsr1 = analogRead(3);
    int fsr2 = analogRead(4);
    int fsr3 = analogRead(5);
    int fsr4 = analogRead(6);
    int fsr5 = analogRead(7);
    int batPct = smoothedBatteryPercent();

    char line[144];
    int n = snprintf(
      line, sizeof(line),
      "%llu,%d,%d,%d,%d,%d,%d\r\n",
      (unsigned long long)epoch_ms, fsr1, fsr2, fsr3, fsr4, fsr5, batPct
    );
    if (n <= 0) continue;

    if (streamClient && streamClient.connected()) {
      const uint32_t nowTxMs = millis();
      // Throttle to STREAM_TX_HZ so the hotspot uplink never saturates.
      // ESP32 WiFiClient::availableForWrite() often returns 0 even when writes succeed — requiring
      // `avail >= need` drops every FSR row while inbound VIBRATE still works.
      if (STREAM_TX_MIN_INTERVAL_MS == 0 || (nowTxMs - lastStreamTxMs) >= STREAM_TX_MIN_INTERVAL_MS) {
        size_t need = (size_t)n;
        int avail = streamClient.availableForWrite();
        const bool knownFull = (avail > 0 && (size_t)avail < need);
        if (knownFull) {
          streamTxSkipFull++;
        } else {
          size_t w = streamClient.write((const uint8_t*)line, need);
          if (w != need) {
            streamTxFailCount++;
            Serial.printf("TCP write failed (%u of %d bytes) — closing client\n", (unsigned)w, n);
            streamClient.stop();
            streamCmdBuf = "";
          } else {
            lastStreamTxMs = nowTxMs;
            streamTxOkCount++;
          }
        }
      }
    }

    const bool sdLogDue = SD_LOG_INTERVAL_US > 0 &&
                          (lastSdLogUs == 0 || (uint32_t)(sampleDueUs - lastSdLogUs) >= SD_LOG_INTERVAL_US);
    if (sdRecording && sdLogDue) {
      lastSdLogUs = sampleDueUs;
      if (sdBufLen + (size_t)n < SD_BUF_BYTES) {
        memcpy(sdBuf + sdBufLen, line, (size_t)n);
        sdBufLen += (size_t)n;
      } else {
        flushSdBuf();
        if ((size_t)n < SD_BUF_BYTES) {
          memcpy(sdBuf, line, (size_t)n);
          sdBufLen = (size_t)n;
        }
      }
    }
  }

  pollStreamCommands();
  updateVibrator();

  static unsigned long lastFlushMs = 0;
  if (millis() - lastFlushMs > 500) {
    flushSdBuf();
    lastFlushMs = millis();
  }

  if (streamClient && streamClient.connected() && millis() - lastStreamStatsMs >= 2000) {
    Serial.printf(
      "TCP TX last 2s: ok=%lu skipFull=%lu fail=%lu (expect ~%u rows/s)\n",
      (unsigned long)streamTxOkCount,
      (unsigned long)streamTxSkipFull,
      (unsigned long)streamTxFailCount,
      (unsigned)STREAM_TX_HZ
    );
    streamTxOkCount = 0;
    streamTxSkipFull = 0;
    streamTxFailCount = 0;
    lastStreamStatsMs = millis();
  }

  yield();
}

static uint32_t samplePeriodUsNow() {
  if (bdl.getVbusPresent()) {
    return SAMPLE_PERIOD_US;
  }
  return 1000000UL / SAMPLE_HZ_BATTERY;
}

static void maintainWiFiOnBattery() {
  if (WiFi.status() == WL_CONNECTED) return;
  if (!wifiAutoRetryEnabled) return;
  const unsigned long now = millis();
  if (now - lastWifiRetryMs < 8000) return;
  lastWifiRetryMs = now;

  if (smoothedBatteryVoltage() < 3.2f && !bdl.getVbusPresent()) {
    bdl.setPixelColor(red);
    return;
  }

  Serial.println("WiFi lost — retrying…");
  if (connectWiFiWithStatus()) {
    if (!MDNS.begin(mdnsHost)) {
      Serial.println("mDNS restart failed");
    } else {
      MDNS.addService("bdl", "tcp", STREAM_PORT);
    }
    streamServer.begin(STREAM_PORT, 4);
    streamServer.setNoDelay(true);
  }
}

bool connectWiFiWithStatus() {
  prepareWifiRadio();

  const bool onBattery = !bdl.getVbusPresent();
  Serial.print("Power: ");
  Serial.print(onBattery ? "battery " : "USB ");
  Serial.print(bdl.getBatteryVoltage(), 2);
  Serial.println(" V");

  if (onBattery) {
    delay(400);
    bdl.setPixelPower(false);
  }

  Serial.print("Looking for \"");
  Serial.print(wifiSSID);
  Serial.print("\" (pass len ");
  Serial.print(wifiPASS.length());
  Serial.println(") on 2.4 GHz…");
  Serial.println("Laptop on same SSID is often 5 GHz — ESP32 cannot use 5 GHz.");

  int targetRssi = findTargetRssiInLastScan();
  if (targetRssi == INT_MIN) {
    Serial.println("Target SSID not visible in scan — skipping 45 s connect wait.");
    Serial.println("Fix: enable router 2.4 GHz, use the 2.4 GHz SSID, move board closer.");
    printWifiScanAndStatus();
    return false;
  }
  Serial.printf("Target visible at %d dBm — connecting…\n", targetRssi);

  WiFi.begin(wifiSSID.c_str(), wifiPASS.c_str());

  unsigned long start = millis();
  unsigned long lastPixelMs = 0;
  wl_status_t lastStatus = WL_IDLE_STATUS;

  while (WiFi.status() != WL_CONNECTED) {
    wl_status_t st = WiFi.status();
    if (st != lastStatus) {
      Serial.printf("\n  status -> %d (%s)\n", (int)st, wifiStatusText(st));
      lastStatus = st;
    }
    Serial.print(".");
    if (millis() - lastPixelMs > 400) {
      bdl.setPixelPower(true);
      bdl.setPixelColor(orange);
      delay(80);
      bdl.setPixelColor(off);
      if (onBattery) bdl.setPixelPower(false);
      lastPixelMs = millis();
    }
    delay(250);
    yield();
    if (millis() - start > 45000) {
      Serial.println("\nWiFi connect timeout (45 s)");
      printWifiScanAndStatus();
      return false;
    }
  }

  Serial.println("\nWiFi connected");
  Serial.print("IP: ");
  Serial.println(WiFi.localIP());
  Serial.print("RSSI: ");
  Serial.println(WiFi.RSSI());
  if (onBattery) {
    WiFi.setTxPower(WIFI_POWER_8_5dBm);
  }
  bdl.setPixelPower(true);
  updateStatusPixel();
  return true;
}

static void prepareWifiRadio() {
  WiFi.disconnect(true, true);
  WiFi.mode(WIFI_STA);
  delay(300);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  WiFi.setMinSecurity(WIFI_AUTH_WPA_WPA2_PSK);
#endif
  WiFi.setTxPower(WIFI_POWER_19_5dBm);
}

static int runWifiScan() {
  prepareWifiRadio();
  for (int attempt = 1; attempt <= 3; attempt++) {
    Serial.printf("  scan attempt %d/3…\n", attempt);
    WiFi.scanDelete();
    int n = WiFi.scanNetworks(false, true, false, 600, 0);
    if (n > 0) return n;
    if (n < 0) {
      Serial.printf("  scan error %d — radio busy, retrying…\n", n);
    }
    delay(600);
  }
  return 0;
}

static int findTargetRssiInLastScan() {
  int n = runWifiScan();
  if (n <= 0) return INT_MIN;

  int best = INT_MIN;
  for (int i = 0; i < n; i++) {
    if (WiFi.SSID(i).equals(wifiSSID)) {
      int rssi = WiFi.RSSI(i);
      if (rssi > best) best = rssi;
    }
  }
  return best;
}

static const char* wifiStatusText(wl_status_t s) {
  switch (s) {
    case WL_IDLE_STATUS: return "idle";
    case WL_NO_SSID_AVAIL: return "SSID not found — check name / 2.4 GHz";
    case WL_SCAN_COMPLETED: return "scan done";
    case WL_CONNECTED: return "connected";
    case WL_CONNECT_FAILED: return "auth failed — wrong password?";
    case WL_CONNECTION_LOST: return "connection lost";
    case WL_DISCONNECTED: return "disconnected";
    default: return "unknown";
  }
}

static void printWifiScanAndStatus() {
  Serial.printf("Last WiFi.status() = %d (%s)\n", (int)WiFi.status(), wifiStatusText(WiFi.status()));
  Serial.println("Scanning 2.4 GHz networks…");
  int n = runWifiScan();
  if (n <= 0) {
    Serial.println("  No networks seen at all.");
    Serial.println("  → Move board next to router, use USB power, enable 2.4 GHz on router.");
    return;
  }
  bool sawTarget = false;
  for (int i = 0; i < n; i++) {
    String name = WiFi.SSID(i);
    bool match = name.equals(wifiSSID);
    if (match) sawTarget = true;
    Serial.printf("  %c %-32s %4d dBm  ch%2d  enc=%d\n",
                  match ? '*' : ' ',
                  name.c_str(), WiFi.RSSI(i), WiFi.channel(i), WiFi.encryptionType(i));
  }
  if (!sawTarget) {
    Serial.printf("  \"*\" = saved target. \"%s\" NOT in list.\n", wifiSSID.c_str());
    Serial.println("  Router may use a different 2.4 GHz name (e.g. Sakshi_2G) or 2.4 GHz is off.");
  } else {
    Serial.println("  Target is visible — if connect fails, password is wrong (status 4).");
  }
  WiFi.scanDelete();
}

static void loadWifiCredentials() {
  Preferences prefs;
  prefs.begin(WIFI_PREFS_NS, true);
  wifiSSID = prefs.getString("ssid", WIFI_DEFAULT_SSID);
  wifiPASS = prefs.getString("pass", WIFI_DEFAULT_PASS);
  prefs.end();
  if (wifiSSID.length() == 0) {
    wifiSSID = WIFI_DEFAULT_SSID;
    wifiPASS = WIFI_DEFAULT_PASS;
  }
}

static void saveWifiCredentials(const String& ssid, const String& pass) {
  Preferences prefs;
  prefs.begin(WIFI_PREFS_NS, false);
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.end();
  wifiSSID = ssid;
  wifiPASS = pass;
}

static void pollSerialWifiConfig() {
  if (!Serial.available()) return;
  String line = Serial.readStringUntil('\n');
  line.trim();
  if (line.length() == 0) return;

  if (line.startsWith("WIFI_SET ")) {
    String rest = line.substring(9);
    rest.trim();
    int sp = rest.indexOf(' ');
    if (sp <= 0) {
      Serial.println("Usage: WIFI_SET <ssid> <password>");
      return;
    }
    String newSsid = rest.substring(0, sp);
    String newPass = rest.substring(sp + 1);
    newPass.trim();
    if (newSsid.length() == 0 || newPass.length() == 0) {
      Serial.println("Usage: WIFI_SET <ssid> <password>");
      return;
    }
    saveWifiCredentials(newSsid, newPass);
    Serial.print("Saved WiFi for \"");
    Serial.print(newSsid);
    Serial.println("\" — rebooting…");
    delay(400);
    ESP.restart();
  } else if (line == "WIFI_SHOW") {
    Serial.print("SSID=");
    Serial.println(wifiSSID);
    Serial.print("pass len=");
    Serial.println(wifiPASS.length());
  } else if (line == "WIFI_SCAN") {
    printWifiScanAndStatus();
  } else if (line == "WIFI_PAUSE") {
    wifiAutoRetryEnabled = false;
    Serial.println("WiFi auto-retry paused. Use WIFI_SCAN / WIFI_SET. WIFI_RESUME to retry.");
  } else if (line == "WIFI_RESUME") {
    wifiAutoRetryEnabled = true;
    lastWifiRetryMs = 0;
    Serial.println("WiFi auto-retry resumed.");
  } else if (line == "WIFI_CLEAR") {
    Preferences prefs;
    prefs.begin(WIFI_PREFS_NS, false);
    prefs.clear();
    prefs.end();
    Serial.println("Cleared saved WiFi — rebooting with sketch defaults…");
    delay(400);
    ESP.restart();
  }
}

void showBootIndicator() {
  for (int i = 0; i < 3; i++) {
    bdl.setPixelColor(orange);
    delay(120);
    bdl.setPixelColor(off);
    delay(80);
    yield();
  }
}

void pollStreamCommands() {
  if (!streamClient || !streamClient.connected()) return;

  while (streamClient.available()) {
    char c = (char)streamClient.read();
    if (c == '\r') continue;
    if (c == '\n') {
      streamCmdBuf.trim();
      if (streamCmdBuf.length() > 0) {
        String low = streamCmdBuf;
        low.toLowerCase();
        low.trim();
        if (low == "vib_test" || low == "vib") {
          triggerVibrateFromCommand(VIBRATE_PULSE_MS);
          Serial.println("VIBRATE command (legacy alias)");
        } else if (low == "vibrate") {
          triggerVibrateFromCommand(VIBRATE_PULSE_MS);
          Serial.println("VIBRATE command");
        } else if (low.startsWith("vibrate ")) {
          uint32_t ms = VIBRATE_PULSE_MS;
          int parsed = low.substring(8).toInt();
          if (parsed >= 30 && parsed <= 500) ms = (uint32_t)parsed;
          triggerVibrateFromCommand(ms);
          Serial.printf("VIBRATE command (%u ms)\n", (unsigned)ms);
        } else if (low == "rec start" || low == "record start") {
          startSdRecording(currentEpochMs());
          if (streamClient && streamClient.connected()) streamClient.print("OK REC START\n");
        } else if (low == "rec stop" || low == "record stop" || low == "rec end") {
          stopSdRecording();
          if (streamClient && streamClient.connected()) streamClient.print("OK REC STOP\n");
        }
      }
      streamCmdBuf = "";
    } else {
      if (streamCmdBuf.length() < 96) streamCmdBuf += c;
      else streamCmdBuf = "";
    }
  }
}

void triggerVibrateFromCommand(uint32_t pulseMs) {
  if (pulseMs < 30) pulseMs = VIBRATE_PULSE_MS;
  if (pulseMs > 500) pulseMs = 500;
  digitalWrite(VIBRATOR_PIN, HIGH);
  vibratorOffAtMs = millis() + pulseMs;
}

void updateVibrator() {
  if (vibratorOffAtMs == 0) return;
  if ((int32_t)(millis() - vibratorOffAtMs) < 0) return;
  digitalWrite(VIBRATOR_PIN, LOW);
  vibratorOffAtMs = 0;
  if (streamClient && streamClient.connected()) {
    streamClient.print("OK VIBRATE\n");
  }
}

void flushSdBuf() {
  if (sdBufLen == 0) return;
  if (!sdRecording || !sdRecFile) {
    sdBufLen = 0;
    return;
  }
  sdRecFile.write((const uint8_t*)sdBuf, sdBufLen);
  sdBufLen = 0;
}

void initSDCard() {
  if (!SD.begin()) {
    Serial.println("Card Mount Failed");
    return;
  }
  if (SD.cardType() == CARD_NONE) {
    Serial.println("No SD card attached");
  }
}

void writeHeaderIfNeeded() {}

bool syncRTCFromNTP() {
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo, 10000)) return false;
  DateTime dt(
    timeinfo.tm_year + 1900,
    timeinfo.tm_mon + 1,
    timeinfo.tm_mday,
    timeinfo.tm_hour,
    timeinfo.tm_min,
    timeinfo.tm_sec
  );
  rtc.adjust(dt);
  return true;
}

uint64_t currentEpochMs() {
  if (!rtcOk) {
    return (uint64_t)millis();
  }
  DateTime now = rtc.now();
  uint32_t rtcUnix = now.unixtime();
  uint32_t msTick = millis();
  if (!g_epochAnchorReady || rtcUnix != g_lastRtcUnix) {
    g_lastRtcUnix = rtcUnix;
    g_millisAtRtcSecondStart = msTick;
    g_epochAnchorReady = true;
  }
  return (uint64_t)rtcUnix * 1000ULL + (uint64_t)(msTick - g_millisAtRtcSecondStart);
}

void startSdRecording(uint64_t epochMsStart) {
  if (!SD.begin()) {
    Serial.println("SD not available — cannot start REC");
    return;
  }
  if (sdRecording) stopSdRecording();
  snprintf(sdRecPath, sizeof(sdRecPath), "/bdl-recording-%llu-%s.csv", (unsigned long long)epochMsStart, mdnsHost);
  sdRecFile = SD.open(sdRecPath, FILE_WRITE);
  if (!sdRecFile) {
    Serial.println("Failed to open SD file for REC");
    return;
  }
  sdRecFile.print("epoch_ms,fsr1,fsr2,fsr3,fsr4,fsr5,battery_pct\r\n");
  sdRecFile.flush();
  sdBufLen = 0;
  lastSdLogUs = 0;
  sdRecording = true;
  Serial.print("REC START -> ");
  Serial.println(sdRecPath);
}

void stopSdRecording() {
  if (!sdRecording) return;
  flushSdBuf();
  if (sdRecFile) {
    sdRecFile.flush();
    sdRecFile.close();
  }
  sdRecording = false;
  sdBufLen = 0;
  Serial.println("REC STOP");
}

void updateStatusPixel() {
  const float battery = smoothedBatteryVoltage();
  const bool vbus = bdl.getVbusPresent();
  const bool wifiUp = (WiFi.status() == WL_CONNECTED);

  if (vbus) {
    if (battery < 2.0f) {
      bdl.setPixelColor(off);
    } else if (battery <= 4.0f) {
      bdl.setPixelColor(orange);
    } else {
      bdl.setPixelColor(green);
    }
    return;
  }

  if (battery < 3.1f) {
    bdl.setPixelColor(red);
    return;
  }

  if (wifiUp) {
    bdl.setPixelColor(battery < 3.8f ? orange : green);
  } else {
    bdl.setPixelColor(red);
  }
}
