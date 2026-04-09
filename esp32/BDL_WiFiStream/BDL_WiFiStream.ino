/*
 * BDL — Wi‑Fi TCP stream (500 Hz) + SD + mDNS (stream-only; no vibrator).
 *
 * epoch_ms uses RTC seconds + elapsed millis within that second (monotonic for plotting).
 * Do NOT use millis()%1000 as “ms within second” — it causes time to jump backward.
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

// RTC is second-resolution; add elapsed millis since that RTC second tick (monotonic).
static uint32_t g_lastRtcUnix = 0;
static uint32_t g_millisAtRtcSecondStart = 0;
static bool g_epochAnchorReady = false;

// Forward decl
bool syncRTCFromNTP();
void initSDCard();
void writeHeaderIfNeeded();
void flushSdBuf();
void checkBattery();

static void acceptClientIfNeeded() {
  if (WiFi.status() != WL_CONNECTED) return;

  if (streamClient && !streamClient.connected()) {
    Serial.println("TCP: previous client no longer connected — pruning");
    streamClient.stop();
  }

  WiFiClient c = streamServer.available();
  if (!c) return;

  if (streamClient) {
    Serial.println("TCP: new client — closing previous socket");
    streamClient.stop();
  }

  streamClient = c;
  streamClient.setNoDelay(true);
  streamClient.setTimeout(50);
  Serial.println("TCP client connected (CSV stream)");
  streamClient.print("epoch_ms,fsr1,fsr2,fsr3,fsr4,fsr5,fsr6\n");
}

void setup() {
  Serial.begin(115200);
  delay(500);

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

    // TCP server (extra listen slots help reconnects after app / hotspot blips).
    streamServer.begin(STREAM_PORT, 4);
    streamServer.setNoDelay(true);
    Serial.print("TCP server: ");
    Serial.print(WiFi.localIP());
    Serial.print(":");
    Serial.println(STREAM_PORT);
  } else {
    Serial.println("WiFi NOT connected. Streaming + mDNS will not work.");
  }

  // SD
  initSDCard();
  writeHeaderIfNeeded();
}

void loop() {
  acceptClientIfNeeded();

  // Battery check (optional)
  unsigned long nowMs = millis();
  if (lastBatteryCheck == 0 || nowMs - lastBatteryCheck > BATTERY_CHECK_INTERVAL) {
    checkBattery();
    lastBatteryCheck = nowMs;
  }

  static uint32_t nextSampleUs = micros();
  static uint32_t sampleCounter = 0;

  uint32_t nowUs = micros();

  // catch up if delayed (avoid drift)
  while ((int32_t)(nowUs - nextSampleUs) >= 0) {
    nextSampleUs += SAMPLE_PERIOD_US;
    sampleCounter++;

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

    // Format CSV line into fixed buffer
    char line[128];
    int n = snprintf(
      line, sizeof(line),
      "%llu,%d,%d,%d,%d,%d,%d\r\n",
      (unsigned long long)epoch_ms, fsr1, fsr2, fsr3, fsr4, fsr5, fsr6
    );
    if (n <= 0) continue;

    // Stream over TCP — close on short write so the next connect isn’t blocked by a zombie session.
    if (streamClient && streamClient.connected()) {
      size_t w = streamClient.write((const uint8_t*)line, (size_t)n);
      if (w != (size_t)n) {
        Serial.printf("TCP write failed (%u of %d bytes) — closing client\n", (unsigned)w, n);
        streamClient.stop();
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

void checkBattery() {
  // Optional: keep your existing battery LED logic here.
  // This is a stub to avoid removing your call site.
  (void)bdl.getBatteryVoltage();
}
