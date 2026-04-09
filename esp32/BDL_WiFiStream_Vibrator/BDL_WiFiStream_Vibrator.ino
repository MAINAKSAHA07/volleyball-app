/*
 * BDL — Wi‑Fi TCP stream (500 Hz) + SD + mDNS + vibrator test over same TCP connection.
 *
 * App sends:  VIBRATE\\n  (default pulse) or  VIBRATE <30-500>\\n  (pulse length ms)
 * Board runs vibrator on VIBRATOR_PIN, then replies: OK VIBRATE\\n
 *
 * Status NeoPixel (BDL): ~1 Hz via updateStatusPixel()
 *   • Plugged in (getVbusPresent): orange = charging, green = high while plugged in, off = very low.
 *   • On battery: green = Wi‑Fi connected + strong pack; orange = Wi‑Fi up but medium pack;
 *     red = no Wi‑Fi or critically low battery.
 *
 * NOTE: Many ESP32 dev boards use GPIO 6–11 for flash; GPIO 9 can be unusable. If the board
 * misbehaves, change VIBRATOR_PIN to a free GPIO (e.g. 12, 14) per your wiring.
 */
#include <BDL.h>
#include "FS.h"
#include "SD.h"
#include <SPI.h>
#include "RTClib.h"
#include <WiFi.h>
#include "time.h"
#include <ESPmDNS.h>

BDL bdl;
RTC_DS3231 rtc;

// ===== Wi‑Fi settings =====
const char* ssid     = "Mainak";
const char* password = "ms080716";

// ✅ unique per board
// Board 1: "bdl-01"
// Board 2: "bdl-02"
const char* mdnsHost = "bdl-01";   // <-- CHANGE PER BOARD

// ===== Vibrator (user wiring at “O9” — adjust if your module uses another GPIO) =====
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
constexpr uint32_t SAMPLE_HZ = 500;                       // 500 samples/sec
constexpr uint32_t SAMPLE_PERIOD_US = 1000000UL / SAMPLE_HZ; // 2000us

// ===== SD logging decimation =====
// 500Hz SD logging + 500Hz Wi‑Fi CSV is usually unstable.
// Log to SD at 50Hz by default; change if needed.
constexpr uint32_t SD_LOG_HZ = 50;
constexpr uint32_t SD_EVERY_N = (SD_LOG_HZ == 0) ? 0 : (SAMPLE_HZ / SD_LOG_HZ); // 10 when 500->50

// SD buffer for block writes
constexpr size_t SD_BUF_BYTES = 8192;
char sdBuf[SD_BUF_BYTES];
size_t sdBufLen = 0;

unsigned long lastBatteryCheck = 0;
#define BATTERY_CHECK_INTERVAL 1000

// Vibrator non-blocking end time (0 = off)
static uint32_t vibratorOffAtMs = 0;

// Incoming command buffer (from phone)
static String streamCmdBuf;

// Monotonic wall-ish epoch_ms: RTC gives whole seconds only; we add (millis - millisAtSecondStart)
// so timestamps never jump backward (do NOT use millis()%1000 — that is not “ms within the second”).
static uint32_t g_lastRtcUnix = 0;
static uint32_t g_millisAtRtcSecondStart = 0;
static bool g_epochAnchorReady = false;

// Forward decl
bool syncRTCFromNTP();
void initSDCard();
void writeHeaderIfNeeded();
void flushSdBuf();
void updateStatusPixel();
void pollStreamCommands();
void updateVibrator();
void triggerVibrateFromCommand(uint32_t pulseMs);

/// Same mapping as Beedatalogger.ino: 3.00–4.20 V → 0–100 %.
static int batteryPercentFromVolts(float v) {
  long vc = (long)(v * 100.0f);
  int p = (int)map(vc, 300L, 420L, 0L, 100L);
  if (p < 0) p = 0;
  if (p > 100) p = 100;
  return p;
}

/**
 * Accept a TCP client for CSV streaming.
 * - Always replaces the previous client when a new one arrives (fixes “zombie” sessions where
 *   WiFiClient::connected() stayed true after the phone dropped Wi‑Fi / force-quit the app).
 * - Prunes a dead client when there is no pending connection so the next accept works cleanly.
 */
static void acceptClientIfNeeded() {
  if (WiFi.status() != WL_CONNECTED) return;

  if (streamClient && !streamClient.connected()) {
    Serial.println("TCP: previous client no longer connected — pruning");
    streamClient.stop();
    streamCmdBuf = "";
  }

  WiFiClient c = streamServer.available();
  if (!c) return;

  if (streamClient) {
    Serial.println("TCP: new client — closing previous socket");
    streamClient.stop();
    streamCmdBuf = "";
  }

  streamClient = c;
  streamClient.setNoDelay(true);
  streamClient.setTimeout(50);
  streamCmdBuf = "";
  Serial.println("TCP client connected (CSV stream)");
  streamClient.print("epoch_ms,fsr1,fsr2,fsr3,fsr4,fsr5,fsr6,battery_pct\n");
}

void setup() {
  Serial.begin(115200);
  delay(500);

  pinMode(VIBRATOR_PIN, OUTPUT);
  digitalWrite(VIBRATOR_PIN, LOW);

  bdl.begin();
  bdl.setPixelBrightness(255 / 3);

  if (!rtc.begin()) {
    Serial.println("Couldn't find RTC");
    while (1) delay(10);
  }

  // Wi‑Fi
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(ssid, password);

  Serial.print("Connecting to WiFi");
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED) {
    Serial.print(".");
    delay(300);
    if (millis() - start > 20000) {
      Serial.println("\nWiFi connect timeout");
      break;
    }
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\nWiFi connected");
    Serial.print("IP: ");
    Serial.println(WiFi.localIP());

    // NTP → RTC
    configTime(gmtOffset_sec, daylightOffset_sec, "pool.ntp.org", "time.nist.gov");
    if (syncRTCFromNTP()) Serial.println("RTC synced from NTP");
    else Serial.println("NTP sync failed; using existing RTC");

    // mDNS / Bonjour: _bdl._tcp on port 3333
    if (MDNS.begin(mdnsHost)) {
      MDNS.addService("bdl", "tcp", STREAM_PORT);
      Serial.print("mDNS started: ");
      Serial.print(mdnsHost);
      Serial.println(".local (_bdl._tcp)");
    } else {
      Serial.println("mDNS failed to start");
    }

    // TCP server (extra listen slots help the phone reconnect quickly after app / hotspot blips).
    streamServer.begin(STREAM_PORT, 4);
    streamServer.setNoDelay(true);
    Serial.print("TCP server: ");
    Serial.print(WiFi.localIP());
    Serial.print(":");
    Serial.println(STREAM_PORT);
  } else {
    Serial.println("WiFi NOT connected. Streaming + mDNS will not work.");
  }

  updateStatusPixel();

  // SD
  initSDCard();
  writeHeaderIfNeeded();
}

void loop() {
  acceptClientIfNeeded();
  pollStreamCommands();
  updateVibrator();

  // Battery check (optional)
  unsigned long nowMs = millis();
  if (lastBatteryCheck == 0 || nowMs - lastBatteryCheck > BATTERY_CHECK_INTERVAL) {
    updateStatusPixel();
    lastBatteryCheck = nowMs;
  }

  static uint32_t nextSampleUs = micros();
  static uint32_t sampleCounter = 0;

  uint32_t nowUs = micros();

  // catch up if delayed (avoid drift)
  while ((int32_t)(nowUs - nextSampleUs) >= 0) {
    nextSampleUs += SAMPLE_PERIOD_US;
    sampleCounter++;

    // Keep command latency reasonable while sampling
    if (sampleCounter % 50 == 0) {
      pollStreamCommands();
      updateVibrator();
    }

    // Timestamp (device epoch_ms) — monotonic within each RTC second
    DateTime now = rtc.now();
    uint32_t rtcUnix = now.unixtime();
    uint32_t msTick = millis();

    if (!g_epochAnchorReady || rtcUnix != g_lastRtcUnix) {
      g_lastRtcUnix = rtcUnix;
      g_millisAtRtcSecondStart = msTick;
      g_epochAnchorReady = true;
    }
    uint64_t epoch_ms = (uint64_t)rtcUnix * 1000ULL
                        + (uint64_t)(msTick - g_millisAtRtcSecondStart);

    // Read sensors
    int fsr1 = analogRead(3);
    int fsr2 = analogRead(4);
    int fsr3 = analogRead(5);
    int fsr4 = analogRead(6);
    int fsr5 = analogRead(7);
    int fsr6 = analogRead(8);

    int batPct = batteryPercentFromVolts(bdl.getBatteryVoltage());

    // Format CSV line into fixed buffer
    char line[144];
    int n = snprintf(
      line, sizeof(line),
      "%llu,%d,%d,%d,%d,%d,%d,%d\r\n",
      (unsigned long long)epoch_ms, fsr1, fsr2, fsr3, fsr4, fsr5, fsr6, batPct
    );
    if (n <= 0) continue;

    // Stream over TCP — if write fails or truncates, close so the next app connect can succeed.
    if (streamClient && streamClient.connected()) {
      size_t w = streamClient.write((const uint8_t*)line, (size_t)n);
      if (w != (size_t)n) {
        Serial.printf("TCP write failed (%u of %d bytes) — closing client\n", (unsigned)w, n);
        streamClient.stop();
        streamCmdBuf = "";
      }
    }

    // SD logging (decimated)
    if (SD_EVERY_N > 0 && (sampleCounter % SD_EVERY_N) == 0) {
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

  // Periodic SD flush
  static unsigned long lastFlushMs = 0;
  if (millis() - lastFlushMs > 500) {
    flushSdBuf();
    lastFlushMs = millis();
  }

  delay(0); // yield
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
          Serial.println("VIBRATE command from app");
        } else if (low == "vibrate") {
          triggerVibrateFromCommand(VIBRATE_PULSE_MS);
          Serial.println("VIBRATE command from app");
        } else if (low.startsWith("vibrate ")) {
          uint32_t ms = VIBRATE_PULSE_MS;
          int parsed = low.substring(8).toInt();
          if (parsed >= 30 && parsed <= 500) {
            ms = (uint32_t)parsed;
          }
          triggerVibrateFromCommand(ms);
          Serial.println("VIBRATE command from app");
        }
      }
      streamCmdBuf = "";
    } else {
      if (streamCmdBuf.length() < 96) {
        streamCmdBuf += c;
      } else {
        streamCmdBuf = "";
      }
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

  File f = SD.open("/test.txt", FILE_APPEND);
  if (!f) {
    sdBufLen = 0;
    return;
  }
  f.write((const uint8_t*)sdBuf, sdBufLen);
  f.close();
  sdBufLen = 0;
}

void initSDCard() {
  if (!SD.begin()) {
    Serial.println("Card Mount Failed");
    return;
  }
  if (SD.cardType() == CARD_NONE) {
    Serial.println("No SD card attached");
    return;
  }
}

void writeHeaderIfNeeded() {
  File file = SD.open("/test.txt");
  if (!file) {
    File wf = SD.open("/test.txt", FILE_WRITE);
    if (wf) {
      wf.print("Epoch_ms,FSR-1,FSR-2,FSR-3,FSR-4,FSR-5,FSR-6\r\n");
      wf.close();
    }
    return;
  }
  file.close();
}

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

/**
 * Single NeoPixel status (same pattern as Beedatalogger.ino):
 * - USB/charger present (getVbusPresent): orange = charging toward full, green = high enough while plugged in.
 * - On battery: green = Wi‑Fi associated + decent battery; orange = Wi‑Fi up but medium/low pack; red = no Wi‑Fi or critical Vbat.
 * Charging takes priority over Wi‑Fi when both apply (pixel shows charge state while plugged in).
 */
void updateStatusPixel() {
  float battery = bdl.getBatteryVoltage();
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
  if (battery < 3.3f) {
    bdl.setPixelColor(red);
    return;
  }

  if (wifiUp) {
    if (battery < 3.8f) {
      bdl.setPixelColor(orange);
    } else {
      bdl.setPixelColor(green);
    }
  } else {
    // Wi‑Fi down but pack OK — red so it’s not confused with charging (orange).
    bdl.setPixelColor(red);
  }
}
