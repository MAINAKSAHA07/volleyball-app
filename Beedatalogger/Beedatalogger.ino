#include <BDL.h>
#include "FS.h"
#include "SD.h"
#include <SPI.h>
#include "RTClib.h"
#include <WiFi.h>
#include "time.h"

BDL bdl;
RTC_DS3231 rtc;

// ===== Wi-Fi + NTP settings =====
const char* ssid     = "Mainak";      // <-- change this
const char* password = "ms080716";  // <-- change this

// Using UTC for logging (epoch time in ms)
const long gmtOffset_sec     = 0;
const int  daylightOffset_sec = 0;

// Timing variables
unsigned long lastBatteryCheck = 0;
#define BATTERY_CHECK_INTERVAL 1000
unsigned long lastLogTimeMicros = 0;
unsigned long logDelayMicros = 2000; 

// Buffering
#define BUFFER_SIZE 500
String logBuffer[BUFFER_SIZE];
int bufferIndex = 0;

// RTC is second-resolution; add elapsed millis since that second tick (not millis()%1000).
static uint32_t g_lastRtcUnix = 0;
static uint32_t g_millisAtRtcSecondStart = 0;
static bool g_epochAnchorReady = false;

// Function prototypes
void checkBattery();
void initSDCard();
void writeFile(fs::FS &fs, const char * path, const char * message);
void appendFile(fs::FS &fs, const char * path, const char * message);
void flushBuffer();
bool syncRTCFromNTP();
void showBootIndicator();

void setup() {
  Serial.begin(115200);
  delay(1000);

  // Initialize BDL (NeoPixel, battery functions, etc.)
  bdl.begin();
  bdl.setPixelBrightness(255 / 3);
  showBootIndicator();

  // Initialize RTC
  if (!rtc.begin()) {
    Serial.println("Couldn't find RTC");
    while (1) delay(10);
  }

  // ---------- Wi-Fi + NTP Time Sync ----------
  WiFi.begin(ssid, password);
  Serial.print("Connecting to WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    Serial.print(".");
    delay(500);
  }
  Serial.println("\nWiFi connected");

  // Configure NTP to get UTC
  configTime(gmtOffset_sec, daylightOffset_sec, "pool.ntp.org", "time.nist.gov");

  if (syncRTCFromNTP()) {
    Serial.println("RTC successfully synced from NTP");
  } else {
    Serial.println("NTP sync failed, falling back to existing RTC time");
    // Optional: as a fallback, you can still reset RTC only if it lost power:
    if (rtc.lostPower()) {
      // Last resort: set to compile time (not as accurate as NTP, but avoids junk)
      rtc.adjust(DateTime(F(__DATE__), F(__TIME__)));
      Serial.println("RTC adjusted to compile time as fallback");
    }
  }

  // Once time is synced, you can disconnect WiFi if not needed anymore
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);
  // -------------------------------------------

  // Initialize SD card
  initSDCard();

  // Check for existing log file or create new
  File file = SD.open("/test.txt");
  if(!file) {
    Serial.println("Creating file...");
    writeFile(SD, "/test.txt", "Epoch_ms,FSR-1,FSR-2,FSR-3,FSR-4,FSR-5\r\n");
  }
  file.close();
}

void loop() {
  unsigned long nowTime = millis();
  unsigned long nowMicros = micros();

  // Battery check every 1s
  if (lastBatteryCheck == 0 || nowTime - lastBatteryCheck > BATTERY_CHECK_INTERVAL) {
    checkBattery();
    lastBatteryCheck = nowTime;
  }

  // Data logging
  if (nowMicros - lastLogTimeMicros >= logDelayMicros) {
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

    int pin1v = analogRead(3);
    int pin2v = analogRead(4);
    int pin3v = analogRead(5);
    int pin4v = analogRead(6);
    int pin5v = analogRead(7);

    String dataMessage = String(epoch_ms) + "," +
                         String(pin1v) + "," + String(pin2v) + "," + String(pin3v) + "," +
                         String(pin4v) + "," + String(pin5v) + "\r\n";

    logBuffer[bufferIndex++] = dataMessage;

    if (bufferIndex >= BUFFER_SIZE) {
      flushBuffer();
      bufferIndex = 0;
    }

    // Set last log time to the tracked micros for true stable 500 Hz
    lastLogTimeMicros += logDelayMicros; 
    
    // Safety check to prevent rapid burst mode if SD card delays loop > 10ms
    if (nowMicros - lastLogTimeMicros > 10000) {
      lastLogTimeMicros = nowMicros;
    }
  }
}

void flushBuffer() {
  String allData = "";
  for (int i = 0; i < BUFFER_SIZE; i++) {
    allData += logBuffer[i];
  }
  appendFile(SD, "/test.txt", allData.c_str());
  Serial.println("Buffered data written to SD");
}

void checkBattery() {
  float battery = bdl.getBatteryVoltage();
  //Serial.println(String("Battery: ") + battery);

  int battery_percentage = map(battery * 100L, 300, 420, 0, 100);
  //Serial.print("Battery Percentage: ");
  //Serial.print(battery_percentage);
  //Serial.println("%");

  if (bdl.getVbusPresent()) {
    if (battery < 2.0) {
      bdl.setPixelColor(off);
    } else if (battery <= 4.0) {
      bdl.setPixelColor(orange);
      for (int i = 0; i < 100; i++) {
        bdl.setPixelBrightness(i);
        delay(10);
      }
    } else {
      bdl.setPixelColor(green);
    }
  } else {
    if (battery < 3.1) {
      // esp_deep_sleep_start();
    } else if (battery < 3.3) {
      bdl.setPixelColor(red);
    } else if (battery < 3.8) {
      bdl.setPixelColor(orange);
    } else {
      bdl.setPixelColor(green);
    }
  }
}

void initSDCard() {
  if (!SD.begin()) {
    Serial.println("Card Mount Failed");
    return;
  }
  uint8_t cardType = SD.cardType();
  if (cardType == CARD_NONE) {
    Serial.println("No SD card attached");
    return;
  }

  Serial.print("SD Card Type: ");
  if (cardType == CARD_MMC) Serial.println("MMC");
  else if (cardType == CARD_SD) Serial.println("SDSC");
  else if (cardType == CARD_SDHC) Serial.println("SDHC");
  else Serial.println("UNKNOWN");

  uint64_t cardSize = SD.cardSize() / (1024 * 1024);
  Serial.printf("SD Card Size: %lluMB\n", cardSize);
}

void writeFile(fs::FS &fs, const char * path, const char * message) {
  Serial.printf("Writing file: %s\n", path);
  File file = fs.open(path, FILE_WRITE);
  if (!file) {
    Serial.println("Failed to open file for writing");
    return;
  }
  file.print(message);
  file.close();
}

void appendFile(fs::FS &fs, const char * path, const char * message) {
  Serial.printf("Appending to file: %s\n", path);
  File file = fs.open(path, FILE_APPEND);
  if (!file) {
    Serial.println("Failed to open file for appending");
    return;
  }
  file.print(message);
  file.close();
}

// ===== Helper: Sync RTC from NTP time =====
bool syncRTCFromNTP() {
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo, 10000)) { // 10s timeout
    Serial.println("Failed to obtain time from NTP");
    return false;
  }

  DateTime dt(
    timeinfo.tm_year + 1900,
    timeinfo.tm_mon + 1,
    timeinfo.tm_mday,
    timeinfo.tm_hour,
    timeinfo.tm_min,
    timeinfo.tm_sec
  );

  rtc.adjust(dt);

  Serial.print("RTC set to (UTC): ");
  Serial.print(dt.year());  Serial.print("/");
  Serial.print(dt.month()); Serial.print("/");
  Serial.print(dt.day());   Serial.print(" ");
  Serial.print(dt.hour());  Serial.print(":");
  Serial.print(dt.minute());Serial.print(":");
  Serial.println(dt.second());

  return true;
}

// Brief LED indicator so it’s obvious the board powered on.
// Uses existing named colors from the BDL library (no custom RGB dependency).
void showBootIndicator() {
  for (int i = 0; i < 3; i++) {
    bdl.setPixelColor(orange);
    delay(120);
    bdl.setPixelColor(off);
    delay(80);
  }
}